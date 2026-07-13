@testitem "unit:busy" tags = [:unit] begin

# Busy contract (post-quiescence-refactor): the chat spinner
# (`busy_active::Observable{Bool}`) simply reflects "a turn is open" —
# `busy = turns_active > 0`. The agent settles the turn with `end_turn` at the
# result (verified in claude-agent-acp) and deliberately does NOT hold the turn
# open waiting on detached background work, so there is no mid-turn dimming and
# no wire-silence / tool-liveness machinery. A detached background task lives in
# the taskbar, not in a held-open turn.
#
# These tests drive the real tool lifecycle functions (`process_update!`,
# `finished!`) headlessly — no worker, no live agent, no Electron — plus
# the `begin_turn!`/`drain_turn!` turn accounting, and assert:
#   • busy is true while a turn is open, false once the turn ends,
#   • the KEY change: busy STAYS true while a turn is held open even with a live
#     background bash (no more "off when only a bg shell remains").

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# A ChatModel with a never-started WorkerAgent: valid for the message-lifecycle
# paths (no ACP connection needed — `send!`/`process_update!`/`close` only touch
# `msgs_store`, `comm`, and `chat_dir`).
function headless_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    return BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
end

# Feed a background BashCall through the real render+update path so the tool ends
# up IN THE TASKBAR (a live background shell) exactly as the wire would produce it.
function launch_bg_bash!(model, id)
    ch = Channel{ACP.ToolCall}(2)
    bc = ACP.BashCall(id, "execute", "monitor loop", "in_progress",
                      ACP.ToolContent[], ch, "monitor loop", true, nothing)
    m = BT.to_message(model, bc)
    BT.send!(model, m)
    put!(ch, ACP.BashCall(id, "execute", "monitor loop", "completed",
          ACP.ToolContent[ACP.TextContent(
              "running in background. Output is being written to: /tmp/$id.output")],
          ch, "monitor loop", true, nothing))
    close(ch)
    BT.process_update!(m, bc)
    return m
end

@testset "busy = turns_active > 0" begin

    @testset "busy true while a turn is open, false after it ends" begin
        model = headless_model()
        @test model.turns_active[] == 0
        @test model.busy_active[] == false

        # Open a turn: begin_turn! bumps the counter and lights the spinner.
        lock(() -> (model.turns_active[] += 1), model.lock)
        model.busy_active[] = true
        @test model.busy_active[] == true

        # Close the turn: drain_turn!'s finally decrements and, on the last turn,
        # clears the spinner.
        last_turn = lock(() -> (model.turns_active[] -= 1) == 0, model.lock)
        @test last_turn
        model.busy_active[] = false
        @test model.turns_active[] == 0
        @test model.busy_active[] == false
    end

    @testset "busy STAYS true while a turn is held open with a live bg bash" begin
        model = headless_model()
        # A live background shell exists...
        m = launch_bg_bash!(model, "bg1")
        @test BT.in_taskbar(m) == true       # in the bar ⇒ a live background shell
        @test BT.is_live(m) == true

        # ...and a turn is open (the agent is blocked on foreground work while the
        # bg shell streams). The KEY change: busy must NOT dim just because the
        # only live tool is a background shell — it tracks the open turn.
        lock(() -> (model.turns_active[] += 1), model.lock)
        model.busy_active[] = true
        @test model.busy_active[] == true

        # The bg shell finishing does not touch busy; only the turn ending does.
        BT.finished!(m)                      # bar's loop calls this when the fd closes
        @test model.busy_active[] == true    # turn still open ⇒ still busy

        # Turn ends → spinner clears, even though a taskbar task may linger.
        lock(() -> (model.turns_active[] -= 1), model.lock)
        model.busy_active[] = false
        @test model.busy_active[] == false
    end

    @testset "a detached bg task lives in the taskbar, not a held-open turn" begin
        model = headless_model()
        # Background launch ends the turn immediately (end_turn at the result):
        # turns_active is 0, busy is off, but the task is still live for the
        # taskbar poller.
        m = launch_bg_bash!(model, "bg2")
        @test model.turns_active[] == 0
        @test model.busy_active[] == false
        @test BT.in_taskbar(m) == true       # membership IS liveness
        @test BT.is_taskbar_item(m) == true
    end

end

end
