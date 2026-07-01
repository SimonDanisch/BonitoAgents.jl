@testitem "unit:busy_counters" tags = [:unit] begin

# Stage-1 busy refactor: the spinner's "is real work still live?" question is
# answered by two AUTHORITATIVE counters (`live_fg_tools` / `live_bg_tools`)
# maintained at the tool lifecycle edges, NOT by re-scanning `msgs_store` on a
# periodic poll. These tests drive the real tool lifecycle functions
# (`process_update!`, `finalize_bg_task!`, `sweep_turn_orphans!`,
# `request_tool_stop!`) headlessly — no worker, no live agent, no Electron — and
# assert:
#   • the counters track fg/bg liveness exactly (creation → live → close),
#   • a completed-on-arrival tool never counts,
#   • a background bash moves fg → bg on launch and bg → none on finalize,
#   • `busy_active` goes true while a foreground tool is live even when the wire
#     is quiet (turn open), and goes false when only a background shell remains,
#   • the counters equal the old O(n) scan across every path (the
#     `BUSY_CROSSCHECK` net is forced on here, so any lifecycle miss `@warn`s).

using Test
using Dates
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# A ChatModel with a never-started WorkerAgent: valid for the message-lifecycle
# paths (no ACP connection needed — `send!`/`process_update!`/`close` only touch
# `msgs_store`, `comm`, the counters and `chat_dir`).
function headless_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    return BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
end

# Feed a ToolCall through the real render+update path: send! the bubble, push the
# terminal snap (or none), close the channel, drain via process_update!.
function run_tool!(model, tc; snaps = ())
    m = BT.to_message(model, tc)
    BT.send!(model, m)
    for s in snaps
        put!(tc.updates, s)
    end
    close(tc.updates)
    BT.process_update!(m, tc)
    return m
end

@testset "busy counters (authoritative)" begin
    # Force the stage-1 cross-check on for the whole file: every `update_busy!`
    # here also runs the old scan and `@warn "BUSY-DESYNC"` on any disagreement.
    old_crosscheck = BT.BUSY_CROSSCHECK[]
    BT.BUSY_CROSSCHECK[] = true
    try

    @testset "foreground tool: live → 1, close → 0" begin
        model = headless_model()
        @test model.live_fg_tools[] == 0
        @test model.live_bg_tools[] == 0

        ch = Channel{ACP.ToolCall}(2)
        tc = ACP.GenericTool("t1", "read", "Read x", "in_progress",
                             ACP.ToolContent[], ch, "", Dict{String,Any}())
        m = BT.to_message(model, tc)
        BT.send!(model, m)
        BT.sync_tool_liveness!(model, m)     # what process_update! does at entry
        @test model.live_fg_tools[] == 1     # counted live the instant it renders
        @test model.live_bg_tools[] == 0

        put!(ch, ACP.GenericTool("t1", "read", "Read x", "completed",
                                 ACP.ToolContent[ACP.TextContent("ok")], ch,
                                 "", Dict{String,Any}()))
        close(ch)
        BT.process_update!(m, tc)
        @test model.live_fg_tools[] == 0     # released exactly once at close
        @test model.live_bg_tools[] == 0
        @test isempty(model.tool_live)       # bookkeeping cleaned up
    end

    @testset "completed-on-arrival tool never counts" begin
        model = headless_model()
        ch = Channel{ACP.ToolCall}(1)
        # Arrives already terminal (a fast Read): no live window at all.
        tc = ACP.GenericTool("t2", "read", "Read y", "completed",
                             ACP.ToolContent[ACP.TextContent("done")], ch,
                             "", Dict{String,Any}())
        run_tool!(model, tc)
        @test model.live_fg_tools[] == 0
        @test model.live_bg_tools[] == 0
        @test isempty(model.tool_live)
    end

    @testset "background bash: fg on launch → bg → none on finalize" begin
        model = headless_model()
        ch = Channel{ACP.ToolCall}(2)
        bc = ACP.BashCall("b1", "execute", "sleep 100", "in_progress",
                          ACP.ToolContent[], ch, "sleep 100", true, nothing)
        m = BT.to_message(model, bc)
        BT.send!(model, m)
        # Background launch detected from the RESULT text (the reliable signal).
        put!(ch, ACP.BashCall("b1", "execute", "sleep 100", "completed",
              ACP.ToolContent[ACP.TextContent(
                  "running in background. Output is being written to: /tmp/b1.output")],
              ch, "sleep 100", true, nothing))
        close(ch)
        BT.process_update!(m, bc)
        @test m.bg_running == true
        @test BT.is_live(m) == true
        @test model.live_fg_tools[] == 0     # NOT double-counted as foreground
        @test model.live_bg_tools[] == 1     # counted as the live background shell

        BT.finalize_bg_task!(model, m)       # shell exits
        @test model.live_bg_tools[] == 0
        @test isempty(model.tool_live)
    end

    @testset "busy stays true for a live fg tool on a quiet wire" begin
        model = headless_model()
        ch = Channel{ACP.ToolCall}(1)
        tc = ACP.GenericTool("t3", "execute", "bt_show_app render", "in_progress",
                             ACP.ToolContent[], ch, "", Dict{String,Any}())
        m = BT.to_message(model, tc)
        BT.send!(model, m)
        BT.sync_tool_liveness!(model, m)
        # An open turn with the wire long since quiet — the honest spinner must
        # STAY on because foreground work is live.
        lock(() -> (model.turns_active[] += 1), model.lock)
        model.last_stream_at[] = time() - (BT.BG_IDLE_QUIESCE + 100)
        model.busy_active[] = false
        BT.update_busy!(model)
        @test model.busy_active[] == true

        close(ch)   # tidy the dangling channel; leave the counter as-is
    end

    @testset "busy goes false when only a background shell remains" begin
        model = headless_model()
        ch = Channel{ACP.ToolCall}(2)
        bc = ACP.BashCall("b2", "execute", "monitor loop", "in_progress",
                          ACP.ToolContent[], ch, "monitor loop", true, nothing)
        m = BT.to_message(model, bc)
        BT.send!(model, m)
        put!(ch, ACP.BashCall("b2", "execute", "monitor loop", "completed",
              ACP.ToolContent[ACP.TextContent(
                  "running in background. Output is being written to: /tmp/b2.output")],
              ch, "monitor loop", true, nothing))
        close(ch)
        BT.process_update!(m, bc)
        @test model.live_bg_tools[] == 1
        @test model.live_fg_tools[] == 0

        # Open turn, quiet wire, only a background shell → spinner off (the
        # taskbar shows the shell instead), matching the old scan's decision.
        lock(() -> (model.turns_active[] += 1), model.lock)
        model.last_stream_at[] = time() - (BT.BG_IDLE_QUIESCE + 100)
        model.busy_active[] = true
        BT.update_busy!(model)
        @test model.busy_active[] == false
    end

    @testset "busy true while streaming (fresh wire), regardless of tools" begin
        model = headless_model()
        lock(() -> (model.turns_active[] += 1), model.lock)
        model.last_stream_at[] = time()     # just streamed a frame
        model.busy_active[] = false
        BT.update_busy!(model)
        @test model.busy_active[] == true   # open turn + fresh wire ⇒ busy
    end

    @testset "orphan sweep releases a live tool's slot" begin
        model = headless_model()
        ch = Channel{ACP.ToolCall}(1)
        tc = ACP.GenericTool("t4", "read", "Read z", "in_progress",
                             ACP.ToolContent[], ch, "", Dict{String,Any}())
        m = BT.to_message(model, tc)
        BT.send!(model, m)
        BT.sync_tool_liveness!(model, m)
        @test model.live_fg_tools[] == 1
        # Driving agent vanished mid-tool: the sweep force-finalizes it.
        BT.sweep_turn_orphans!(model)
        @test model.live_fg_tools[] == 0
        @test isempty(model.tool_live)
        close(ch)
    end

    finally
        BT.BUSY_CROSSCHECK[] = old_crosscheck
    end
end

end
