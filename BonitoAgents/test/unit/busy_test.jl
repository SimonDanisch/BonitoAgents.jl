@testitem "unit:busy" tags = [:unit] begin

# Busy contract: the chat spinner (`busy_active::Observable{Bool}`) reflects "the
# consumer is inside a turn" — the flag `while_busy` holds. The agent settles
# the turn with `end_turn` at the result (verified in claude-agent-acp) and
# deliberately does NOT hold the turn open waiting on detached background work, so
# there is no mid-turn dimming and no wire-silence / tool-liveness machinery. A
# detached background task lives in the taskbar, not in a held-open turn.
#
# These drive the REAL set/clear. They used to assign `turns_active` and
# `busy_active` by hand and assert what they had just written, which is why they
# stayed green through everything: nothing under test ran. `while_busy` is now
# the only thing that touches either, so a test can enter it and look — no agent,
# no prompt and no session needed, which is why it is still a function of its own
# rather than folded into `begin_turn`.

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

@testset "busy follows the consumer's turn" begin

    @testset "busy true while a turn is open, false after it ends" begin
        model = headless_model()
        @test model.turn_in_flight[] == false
        @test model.busy_active[] == false

        BT.while_busy(model) do
            # The claim edge PUBLISHES — the spinner is not something the caller
            # sets alongside; `busy` is derived and `refresh_activity!` ships it.
            @test model.turn_in_flight[] == true
            @test model.busy_active[] == true
        end
        @test model.turn_in_flight[] == false
        @test model.busy_active[] == false      # ...and the release edge clears it
    end

    @testset "busy clears even when the turn throws" begin
        # The reason the set and the clear live in ONE scope. When they were a
        # pair spanning turn start and turn finish, any path that left between
        # them stranded the flag — and a stranded flag is a chat that reports
        # "working" forever, with no way back short of a restart.
        model = headless_model()
        @test_throws ErrorException BT.while_busy(() -> error("boom"), model)
        @test model.turn_in_flight[] == false
        @test model.busy_active[] == false
    end

    @testset "a turn that cannot start never runs its body" begin
        # `begin_turn` is a do-block so the caller has no span to check for
        # `nothing` and no "remember to finish this" contract. The three bails
        # (chat closed, restart never settled, no client) must therefore skip the
        # body outright — handing it a `nothing` span would move the check back to
        # the caller, which is the shape this replaced. A closed `user_messages`
        # is the "chat is dead" signal, and the first thing checked.
        model = headless_model()
        close(model.user_messages)
        ran = Ref(false)
        BT.begin_turn(model, BT.UserMessage("hi")) do turn
            ran[] = true
        end
        @test ran[] == false
        @test model.turn_in_flight[] == false   # ...and busy came back down anyway
        @test model.busy_active[] == false
    end

    @testset "busy STAYS true while a turn is held open with a live bg bash" begin
        model = headless_model()
        # A live background shell exists...
        m = launch_bg_bash!(model, "bg1")
        @test BT.in_taskbar(m) == true       # in the bar ⇒ a live background shell
        @test BT.is_live(m) == true

        # ...and a turn is open (the agent is blocked on foreground work while the
        # bg shell streams). busy must NOT dim just because the only live tool is
        # a background shell — it tracks the open turn.
        BT.while_busy(model) do
            @test model.busy_active[] == true
            # The bg shell finishing does not touch busy; only the turn ending does.
            BT.finished!(m)                  # bar's loop calls this when the fd closes
            BT.refresh_activity!(model)      # even re-derived, the open turn rules
            @test model.busy_active[] == true
        end
        # Turn ends → spinner clears, even though a taskbar task may linger.
        @test model.busy_active[] == false
    end

    @testset "a detached bg task lives in the taskbar, not a held-open turn" begin
        model = headless_model()
        # Background launch ends the turn immediately (end_turn at the result):
        # no turn is open, busy is off, but the task is still live for the
        # taskbar poller.
        m = launch_bg_bash!(model, "bg2")
        @test model.turn_in_flight[] == false
        @test model.busy_active[] == false
        @test BT.in_taskbar(m) == true       # membership IS liveness
        @test BT.is_taskbar_item(m) == true
    end

end

end
