# Regression for the edit-tool diff-preview refactor.
#
# What changed: edit tool messages used to ship a separate `preview` HTML
# string (the old "all − then all +" view) above a lazy-mounted body. That
# preview was misleading (showed old/new dumps, not real hunks) and divergent
# from the Monaco DiffEditor in the body. Now the body itself IS the preview:
# a Monaco DiffEditor capped at `EDIT_BODY_COMPACT_PX` via the editor's own
# `max_height`, eager-mounted via an `expand: true` tool_update once the
# first `DiffContent` snap lands.
#
# This test pins:
#   1. `auto_expand_body(GenericToolMsg{kind="edit"}, content)` only fires
#      once content has a DiffContent — not on the bare "new" notification.
#   2. Driving a real edit ToolCall through `process_update!` emits a
#      tool_update with `expand: true` on the snap that carries the diff.
#   3. `render_diff_block` accepts `max_height` and passes it to the
#      DiffEditor's `max_height` Observable (Monaco's own height API), so
#      the Collapsable can swap compact ↔ full without re-mounting Monaco.

using Test, BonitoAgents, Bonito, Dates, Hyperscript
import BonitoAgents.AgentClientProtocol as ACP
const BT = BonitoAgents

@testset "auto_expand_body fires only when an edit tool has a DiffContent" begin
    m = BT.GenericToolMsg("t1", "edit", "Edit", "in_progress", "", time(), nothing, nothing)

    # Bare "new" event — no content yet. Must NOT auto-expand.
    @test BT.auto_expand_body(m, ACP.ToolContent[]) === false
    # Snap with only TextContent (uncommon for edit kind, but still no diff).
    @test BT.auto_expand_body(m, ACP.ToolContent[ACP.TextContent("note")]) === false
    # Snap carrying a real diff — eager-mount fires.
    diff = ACP.DiffContent("/foo.jl", "old", "new")
    @test BT.auto_expand_body(m, ACP.ToolContent[diff]) === true
    # Multi-edit (more than one diff) also qualifies.
    @test BT.auto_expand_body(m,
        ACP.ToolContent[diff, ACP.DiffContent("/bar.jl", "x", "y")]) === true

    # Single-arg back-compat — what the chat code uses outside the snap loop.
    # Without a snap to inspect, defaults to false (= "wait until the snap").
    @test BT.auto_expand_body(m) === false

    # Other tool kinds never auto-expand from the GenericToolMsg path.
    for k in ("execute", "read", "search", "other", "fetch")
        non_edit = BT.GenericToolMsg("t2", k, k, "completed", "",
                                      time(), nothing, nothing)
        @test BT.auto_expand_body(non_edit, ACP.ToolContent[diff]) === false
    end
end

# Drive a synthetic edit ToolCall through process_update!. Same loopback
# pattern as test_bonito_app_lifecycle.jl: capture comm emits to verify the
# tool_update payloads.
function fresh_chat()
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                              worker_secret = "x")
    BT.ChatModel(state, mktempdir();
                  transport = BT.MockTransport((o, i) -> nothing))
end

function drive_edit_tool(snaps::Vector{<:ACP.ToolCall}; tool_id::String = "toolu_EDIT")
    chat = fresh_chat()
    ch = Channel{ACP.ToolCall}(length(snaps) + 1)
    initial = ACP.GenericTool(tool_id, "edit", "Edit", "in_progress",
                              ACP.ToolContent[], ch, "Edit", Dict{String,Any}())
    msg = BT.build_tool_msg(chat, initial)
    emits = Dict{String,Any}[]
    Bonito.on(chat.comm) do d; push!(emits, copy(d)); end
    for snap in snaps; put!(ch, snap); end
    close(ch)
    BT.process_update!(msg, initial)
    return (msg = msg, emits = emits)
end

mksnap(status::AbstractString, content::Vector{<:ACP.ToolContent}; tool_id="toolu_EDIT") =
    ACP.GenericTool(tool_id, "edit", "Edit", status, content,
                    Channel{ACP.ToolCall}(0), "Edit", Dict{String,Any}())

@testset "edit tool's first DiffContent snap fires expand=true (no separate preview)" begin
    in_prog = mksnap("in_progress", ACP.ToolContent[])
    diff    = ACP.DiffContent("/sim/foo.jl", "old text\n", "new text\n")
    result  = mksnap("completed", ACP.ToolContent[diff])
    r = drive_edit_tool([in_prog, result])

    @test length(r.emits) == 2
    # The pre-content snap MUST NOT auto-expand — the body has nothing to show.
    @test r.emits[1]["status"] == "in_progress"
    @test !haskey(r.emits[1], "expand")
    # The diff-bearing snap auto-expands so the compact Monaco preview mounts.
    @test r.emits[2]["status"] == "completed"
    @test r.emits[2]["expand"] === true
    # No `preview` field — the dead HTML-preview wire path is gone.
    @test !haskey(r.emits[1], "preview")
    @test !haskey(r.emits[2], "preview")
end

@testset "render_diff_block respects max_height" begin
    diff = ACP.DiffContent("/x.jl", "a\nb\n", "a\nB\n")
    compact = BT.render_diff_block(diff; max_height = BT.EDIT_BODY_COMPACT_PX)
    full    = BT.render_diff_block(diff; max_height = BT.EDIT_BODY_EXPANDED_PX)
    # The DiffEditor lives as the second child (after the path header).
    de_compact = Bonito.children(compact)[2]
    de_full    = Bonito.children(full)[2]
    @test de_compact isa BonitoAgents.BonitoBook.DiffEditor
    @test de_compact.max_height[] == BT.EDIT_BODY_COMPACT_PX
    @test de_full.max_height[]    == BT.EDIT_BODY_EXPANDED_PX
end

@testset "render_tool_body for an edit tool uses compact max_height" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                              worker_secret = "x")
    chat = BT.ChatModel(state, mktempdir();
                         transport = BT.MockTransport((o, i) -> nothing))
    m = BT.GenericToolMsg("t-edit", "edit", "Edit", "completed", "",
                           time(), nothing, chat)
    diff = ACP.DiffContent("/p.jl", "x\n", "y\n")
    BT.cache_tool_content!(chat, m.id, ACP.ToolContent[diff])

    body = BT.render_tool_body(state, m, chat.cwd, chat.chat_dir; project_id = chat.project_id)
    # Body's outer div has the marker class so the JS Collapsable can
    # discover it's an edit tool without sniffing the inner Monaco DOM.
    attrs = Hyperscript.attrs(body)
    @test occursin("bt-edit-tool-body", get(attrs, "class", ""))
    # The wrapped DiffEditor uses the compact cap.
    diff_block = first(Hyperscript.children(body))
    diff_editor = Hyperscript.children(diff_block)[2]
    @test diff_editor isa BonitoAgents.BonitoBook.DiffEditor
    @test diff_editor.max_height[] == BT.EDIT_BODY_COMPACT_PX
end
