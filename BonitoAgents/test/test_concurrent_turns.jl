# Prompt queueing + the background-shell hold/handoff, plus the pure
# `update_busy!` state machine.
#
# The agent-driven half is migrated onto the TestKit harness (real dev_server,
# real worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked via the `agent=` callback). The pure-function half
# (`update_busy!` over directly-constructed state) stays a plain unit test — no
# chat, no agent, no transport.
#
# Background (handoff): a held turn (a background shell) is released by the NEXT
# prompt — `promptQueueing`. So a second prompt sent while the first is still
# running must NOT serialize forever behind it: it goes in-flight, the first
# resolves, both land in order, and end-of-turn cleanup belongs to the LAST
# turn only (busy clears, no orphan queued badge left behind).

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, delay, end_turn

# ── DOM e2e: two prompts, first held open, second released-then-ordered ──────

@testset "prompt queueing: a second send while busy lands + both turns resolve in order" begin
    # Turn 1 streams a chunk, then HOLDS open (a long delay) so a second prompt
    # arrives mid-flight. Turn 2 streams its own chunk. Tags make ordering and
    # no-bleed observable in the DOM. The first turn's hold (~3.5s) is long
    # enough that the second `send_message` genuinely overlaps it.
    turn = Ref(0)
    s = TK.dev_server(; agent = msg -> begin
        turn[] += 1
        t = turn[]
        if t == 1
            [text("TURN1-START "), delay(3500), text("TURN1-END "), end_turn()]
        else
            [text("TURN2-ONLY "), end_turn()]
        end
    end)
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # Send the first prompt; wait until it is genuinely in-flight (busy + its
        # opening chunk rendered) before sending the second.
        TK.send_message(s, "first")
        @test TK.wait_for(s, "turn 1 streaming",
            "(document.querySelector('.bt-agent-msg')||{}).textContent ? document.body.textContent.indexOf('TURN1-START') !== -1 : false";
            timeout = 30) == true
        @assert timedwait(() -> model.busy_active[], 10.0) === :ok "turn 1 never went busy"

        # Second prompt WHILE the first is still held open. It must reach the wire
        # (a serializing consumer would queue it forever behind the held turn) —
        # so its user bubble lands and, eventually, its response streams.
        users_before = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        TK.send_message(s, "second")
        @test TK.wait_for(s, "second user bubble lands",
            "document.querySelectorAll('.bt-user-msg').length >= $(users_before + 1)"; timeout = 10) == true
        # Two turns are active at the overlap (the first is still held).
        @test timedwait(() -> model.turns_active[] >= 2, 8.0) === :ok

        # Both turns resolve: both responses are visible, in order (TURN1 before
        # TURN2 in the document), and cleanup (gated on the LAST turn) clears busy.
        @test TK.wait_for(s, "both turns' content rendered",
            "document.body.textContent.indexOf('TURN1-END') !== -1 && document.body.textContent.indexOf('TURN2-ONLY') !== -1";
            timeout = 20) == true
        ordered = TK.eval_js(s, """(() => {
            const t = document.body.textContent;
            return t.indexOf('TURN1-START') < t.indexOf('TURN2-ONLY'); })()""")
        @test ordered == true

        @assert timedwait(() -> model.turns_active[] == 0, 15.0) === :ok "turns never drained to 0"
        @test timedwait(() -> !model.busy_active[], 8.0) === :ok
        @test model.busy_active[] == false
        # No queued badge left anywhere — neither in the store nor in the DOM.
        @test !any(m -> m isa BT.UserMsg && m.queued,
                   lock(() -> copy(model.msgs_store), model.lock))
        @test TK.eval_js(s, "document.querySelectorAll('.bt-user-msg.bt-queued').length") == 0

        TK.screenshot(s, joinpath(tempdir(), "bt-concurrent-turns-final.png"))
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end

# ── DOM e2e: a queued bubble's badge appears then clears on promote ──────────

@testset "queued user bubble: bt-queued badge appears, promote clears it" begin
    # The visible queued window only exists when a UserMsg is injected directly
    # (the fast idle-consumer pop closes it before a test could see it). Drive it
    # server-side exactly as the committed session_changes test does, and assert
    # the badge in the REAL DOM.
    s = TK.dev_server(; agent = msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        queued = BT.UserMsg(chat, "queued question")
        queued.queued = true
        BT.send!(chat, queued)
        @test TK.wait_for(s, "queued bubble gains bt-queued", """
            (() => { const us = document.querySelectorAll('.bt-user-msg');
                     const last = us[us.length - 1];
                     return last && last.classList.contains('bt-queued'); })()
        """; timeout = 8) == true

        BT.promote_queued_user_bubble!(chat)
        @test TK.wait_for(s, "queued class cleared after promote",
            "document.querySelectorAll('.bt-user-msg.bt-queued').length === 0"; timeout = 8) == true

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end

# ── Pure unit tests: update_busy! over directly-constructed state ────────────

@testset "update_busy!: quiet wire + bg shell only → busy off; live fg tool → busy on" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir())
    s = BT.shared(model)

    bg = BT.BashToolMsg("bg1", "execute", "Terminal", "completed", "",
                         time(), nothing, "sleep 600", "Monitor", true,
                         "/tmp/x.out", 0, true, "", model)
    push!(s.msgs_store, bg)

    # Open turn + quiet wire + only a bg shell live → not busy.
    s.turns_active[]  = 1
    s.last_stream_at[] = time() - 60
    s.busy_active[]   = true
    BT.update_busy!(model)
    @test !s.busy_active[]

    # Same, but wire active again → busy.
    s.last_stream_at[] = time()
    BT.update_busy!(model)
    @test s.busy_active[]

    # Quiet + bg shell + a LIVE FOREGROUND tool → stays busy (fg tools
    # stream nothing while they run; quiet is not idle).
    s.last_stream_at[] = time() - 60
    fg = BT.GenericToolMsg("fg1", "read", "Read", "Read x", "in_progress",
                            "", time(), nothing, model, Dict{String,Any}())
    push!(s.msgs_store, fg)
    BT.update_busy!(model)
    @test s.busy_active[]

    # No open turn → never busy.
    s.turns_active[] = 0
    BT.update_busy!(model)
    @test !s.busy_active[]
    close(model)
end

@testset "update_busy!: a live bt_show_app render keeps the spinner on" begin
    # Regression: a long bt_show_app (or eval between checkpoints) is foreground
    # work whose pill is status-live; the spinner must NOT drop while it renders,
    # even though the wire is momentarily quiet.
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir())
    s = BT.shared(model)

    app = BT.BonitoAppMsg("app1", "bonito_app", "Dashboard", "in_progress",
                          "", time(), nothing, "btworker", "", model)
    push!(s.msgs_store, app)
    s.turns_active[]   = 1
    s.last_stream_at[] = time() - 60      # wire quiet
    s.busy_active[]    = true
    BT.update_busy!(model)
    @test s.busy_active[]                 # live app render ⇒ still busy
    close(model)
end
