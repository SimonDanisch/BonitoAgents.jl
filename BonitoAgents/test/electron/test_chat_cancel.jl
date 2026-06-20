# End-to-end stop / cancel tests against a real `serve()` + Electron.
#
# The stop feature is critical UX — when the agent is streaming a long
# response (or stuck in a tool call) the user MUST be able to interrupt.
# Two trigger paths to cover:
#
#   1. Click on the `.bt-stop-btn` DOM button.
#   2. Press ESC anywhere in the chat (textarea focused or not).
#
# Both ship `{type: 'cancel'}` over the comm Observable, which the Julia
# side picks up in `handle_command!(::CancelCommand)` and turns into an
# ACP `session/cancel` notification (off-lock, directly — NOT through
# `apply!`, so even a long-held `model.lock` mid-finalize can't block
# the cancel from going out).
#
# A real claude-agent-acp run would be too slow + non-deterministic, so
# we drive these against a custom `MockTransport` that:
#
#   - Streams `chunks_per_turn` agent_message_chunk events with a small
#     per-chunk delay (gives the test time to interject mid-stream).
#   - Honors `session/cancel` notifications: sets a flag, the streamer
#     bails on its next iteration, and immediately fires the
#     `session/prompt` response with `stopReason: "cancelled"`.
#
# That mirrors what a well-behaved claude does, AND lets the test verify
# the cancel actually reached the mock (we can inspect the flag).

isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents, Bonito, JSON, Dates
import ElectronCall
import AgentClientProtocol as ACP

# Mutable observer for what the mock saw — the test reads these after
# the cancel to assert the mock actually received the notification.
mutable struct MockState
    cancel_flag      :: Threads.Atomic{Bool}     # set by mock on session/cancel
    cancel_seen_at   :: Threads.Atomic{Int}      # chunk count when cancel arrived (-1 = never)
    chunks_sent      :: Threads.Atomic{Int}      # total chunks the mock streamed for this turn
    stop_reason      :: Ref{String}              # "end_turn" or "cancelled"
end
MockState() = MockState(Threads.Atomic{Bool}(false),
                        Threads.Atomic{Int}(-1),
                        Threads.Atomic{Int}(0),
                        Ref{String}(""))

# Build a transport that streams up to `chunks_per_turn` agent_message_chunks
# at `chunk_interval_ms` apart per session/prompt request, honoring cancel.
function cancellable_streaming_transport(s::MockState;
                                         chunks_per_turn::Int = 200,
                                         chunk_interval_ms::Real = 10)
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                        "result"=>Dict())))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                        "result"=>Dict("sessionId"=>"mock-sess-1"))))
                elseif method == "session/cancel"
                    Threads.atomic_xchg!(s.cancel_flag, true)
                    Threads.atomic_xchg!(s.cancel_seen_at, s.chunks_sent[])
                elseif method == "session/prompt" && id !== nothing
                    @async try
                        cancelled = false
                        for i in 1:chunks_per_turn
                            # Pre-chunk cancel check — break BEFORE
                            # sending the next chunk if cancel arrived.
                            if s.cancel_flag[]
                                cancelled = true
                                break
                            end
                            put!(incoming, JSON.json(Dict(
                                "jsonrpc" => "2.0",
                                "method"  => "session/update",
                                "params"  => Dict(
                                    "sessionId" => "mock-sess-1",
                                    "update" => Dict(
                                        "sessionUpdate" => "agent_message_chunk",
                                        "content" => Dict("type"=>"text",
                                                           "text"=>"[$i] "))))))
                            Threads.atomic_add!(s.chunks_sent, 1)
                            sleep(chunk_interval_ms / 1000)
                        end
                        s.stop_reason[] = cancelled ? "cancelled" : "end_turn"
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                            "result"=>Dict("stopReason"=>s.stop_reason[]))))
                    catch e
                        @warn "mock streamer failed" exception=e
                    end
                elseif id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                        "result"=>nothing)))
                end
            end
        catch e
            e isa InvalidStateException ||
                @warn "mock responder failed" exception=e
        end)
        return nothing
    end
    return BonitoAgents.MockTransport(on_setup)
end

function setup_chat_(project_id::String, mock_state::MockState)
    state = BonitoAgents.serve(;
        host = "127.0.0.1", port = 0,
        worker_secret = "x",
        state_dir = mktempdir(), working_dir = mktempdir())
    state.workers[]["w1"] = BonitoAgents.WorkerInfo("w1", "Tester", "<inbound-ws>",
        "x", nothing, "h", "/h", "", String[], "/p", :online, now(UTC))
    notify(state.workers)
    state.projects[][project_id] = BonitoAgents.ProjectInfo(project_id, project_id, "w1",
        mktempdir(), mktempdir(), now(UTC))
    notify(state.projects)
    mock = cancellable_streaming_transport(mock_state)
    model = BonitoAgents.ChatModel(state, mktempdir();
        project_id = project_id, transport = mock)
    state.chat_models[project_id] = model
    BonitoAgents.start_chat_client!(model)
    return state, model
end

function open_window_(state)
    app = ElectronCall.Application()
    win = ElectronCall.Window(app, ElectronCall.URI(Bonito.online_url(state.srv, ""));
        options = Dict{String,Any}("show"=>false, "focusOnWebView"=>false,
                                    "width"=>1280, "height"=>800))
    sleep(2.5)
    return (; app, win)
end

function wait_for_(win, predicate; timeout = 8.0)
    deadline = time() + timeout
    while time() < deadline
        try
            ElectronCall.run(win, "(() => { return ($predicate); })()") === true && return true
        catch end
        sleep(0.05)
    end
    return false
end

function wait_for_julia(pred::Function; timeout = 8.0)
    deadline = time() + timeout
    while time() < deadline
        pred() && return true
        sleep(0.02)
    end
    return false
end

# Run one cancel scenario. `trigger_cancel(win)` is the JS-side action
# (click button / dispatch keydown). Returns `(model, mock_state, results)`.
function run_cancel_scenario(label::String, trigger_cancel::Function)
    s = MockState()
    state, model = setup_chat_("cancel-test", s)
    w = open_window_(state)
    results = Pair{String,Bool}[]
    record(name, ok) = push!(results, "$label: $name" => ok)

    try
        # Navigate to the chat.
        ElectronCall.run(w.win, """
            (() => {
                const el = document.querySelector('.bt-side-item[data-project-id="cancel-test"]');
                if (el) el.click();
            })()
        """)
        @assert wait_for_(w.win,
            "document.querySelector('.bt-text-input') !== null";
            timeout = 8) "$label: chat didn't mount"
        @assert wait_for_(w.win,
            "document.querySelector('.bt-stop-btn') !== null";
            timeout = 4) "$label: stop button not rendered"
        # Wait until BonitoChat._setupInputs has run (deferred to a
        # microtask). The end-of-setup signal is `_onEscapeKey` (the
        # last listener attached). Click handlers use event delegation
        # on `.bt-app` so they work even if the buttons appear later.
        @assert wait_for_(w.win,
            "typeof document.querySelector('.bt-messages').__bt_chat._onEscapeKey === 'function'";
            timeout = 4) "$label: _setupInputs didn't run"

        # Drive a real user submission via the JS path: type into the
        # textarea then click the send button. That fires
        # `{type: 'send'}` over comm → server handle_command!(::SendCommand)
        # → send_message! → apply!(UserSubmitted) → drive_prompt!.
        ElectronCall.run(w.win, """
            (() => {
                const ta = document.querySelector('.bt-text-input');
                ta.value = 'hi please tell me a long story';
                ta.dispatchEvent(new Event('input', {bubbles: true}));
                document.querySelector('.bt-send-btn').click();
            })()
        """)

        # Wait until the mock has streamed at least 5 chunks AND the
        # browser sees the streaming agent bubble. That puts us
        # genuinely mid-stream, not before the agent even started.
        @assert wait_for_julia(() -> s.chunks_sent[] >= 5; timeout = 6) "$label: mock never started streaming"
        @assert wait_for_(w.win,
            "document.querySelector('.bt-agent-msg') !== null";
            timeout = 4) "$label: streaming bubble didn't appear in DOM"

        # Fire the cancel from JS (button click or ESC keydown).
        trigger_cancel(w.win)

        # The cancel must reach the mock — that's the OOM property.
        record("mock saw session/cancel notification",
               @TH.test_true wait_for_julia(() -> s.cancel_flag[]; timeout = 2))

        # busy_active must clear — cancel makes ACP close the turn's update
        # channel, so `prompt!`'s loop ends, the `run_turn!` for-loop ends, and
        # its `finally` clears busy.
        record("busy_active cleared within 2s",
               @TH.test_true wait_for_julia(() -> !model.busy_active[]; timeout = 2))

        # The cancelled turn's partial agent bubble was sealed into the store
        # (the per-turn parser closes the trailing message at the boundary —
        # no orphan stream left hanging).
        record("partial agent bubble sealed into the store",
               @TH.test_true any(m -> m isa BonitoAgents.AgentMsg, model.msgs_store))

        # Stream actually stopped early — mock saw the cancel BEFORE
        # finishing all 200 chunks (the script length). If we sent
        # more than a handful past the cancel point, the cancel wasn't
        # effective.
        record("mock stopped early (< 200 total chunks)",
               @TH.test_true (s.chunks_sent[] < 200))
        record("mock stopReason = cancelled",
               @TH.test_eq s.stop_reason[] "cancelled")

        # The browser must see a finalized agent bubble — `_final`
        # events rewrite the bubble's innerHTML from "streaming text"
        # to rendered Markdown. After cancel + PromptCompleted, the
        # bubble should NOT have its streaming class anymore.
        record("agent bubble was finalized (HTML rendered)",
               @TH.test_true wait_for_(w.win, """
                   (() => {
                       const b = document.querySelectorAll('.bt-agent-msg');
                       if (b.length === 0) return false;
                       const last = b[b.length - 1];
                       // streaming bubble has a `.bt-stream-text` span;
                       // finalized bubble is replaced by parsed markdown.
                       return last.querySelector('.bt-stream-text') === null;
                   })()
               """; timeout = 2))

        # User can immediately submit a new message after cancel — the
        # ChatModel is in a clean state, and a follow-up `send_message!`
        # should work end-to-end (this is the real UX requirement —
        # "stop, then ask something else").
        Threads.atomic_xchg!(s.cancel_flag, false)
        Threads.atomic_xchg!(s.chunks_sent, 0)
        BonitoAgents.send_message!(model, BonitoAgents.UserMsg("follow up"))
        record("follow-up turn starts streaming after cancel",
               @TH.test_true wait_for_julia(() -> s.chunks_sent[] >= 3; timeout = 4))
    finally
        try close(w.win) catch end
        try close(w.app) catch end
        try close(state.srv) catch end
    end
    return results
end

results = Pair{String,Bool}[]

try
    TH.section("Stop button click cancels mid-stream") do
        click_results = run_cancel_scenario("stop-click", win -> begin
            ElectronCall.run(win, "document.querySelector('.bt-stop-btn').click()")
        end)
        append!(results, click_results)
    end

    TH.section("ESC key cancels mid-stream (no focus required)") do
        esc_results = run_cancel_scenario("esc-key", win -> begin
            # Dispatch ESC on document — must work without anything focused,
            # because that's the "user's in the middle of reading the
            # streaming output, hits ESC" scenario.
            ElectronCall.run(win, """
                document.dispatchEvent(new KeyboardEvent('keydown',
                    {key: 'Escape', bubbles: true}));
            """)
        end)
        append!(results, esc_results)
    end
finally
    TH.report!("Tier — stop button cancel (click + ESC)", results)
end
