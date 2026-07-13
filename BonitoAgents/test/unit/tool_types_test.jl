@testitem "unit:tool_types" tags = [:unit] begin

# The tool-message TYPE TREE: every Claude tool family dispatches on its own
# concrete type, never a `kind ==` / `tool_name in (...)` string test. This pins
# (1) the ONE wire→type routing point per family (`builtin_msg_type` /
# `mcp_msg_type`), (2) that same-rendering tools share a type but keep a distinct
# filter identity (Grep/Glob → SearchToolMsg, told apart by `name`/`tool_key`),
# (3) the per-type header summaries, and (4) the per-type affordances
# (eval code/⊗, the control tools' `executed_preview`).

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

txt(s)          = ACP.TextContent(s)
dif(p, o, n)    = ACP.DiffContent(p, o, n)
const CV        = Union{ACP.DiffContent, ACP.ImageContent, ACP.TextContent}
# A replayed GenericTool wire message (chat=nothing, same `builtin_msg_type`
# routing as the live `build_tool_msg`).
gt(kind, name, title; content = CV[]) =
    BT.replayed_tool_msg(ACP.GenericTool("id_$name", kind, title, "completed",
        collect(CV, content), Channel{ACP.ToolCall}(0), name, Dict{String,Any}()))
# An MCP tool message of the type `tool_name` routes to.
mcp(tool_name; raw = Dict{String,Any}()) =
    BT.mcp_msg_type(tool_name)("id", "other", tool_name, "completed", "",
        time(), nothing, "btworker", tool_name, raw, nothing)

@testset "builtin_msg_type: one wire→type routing point" begin
    @test BT.builtin_msg_type("edit")    === BT.EditToolMsg
    @test BT.builtin_msg_type("read")    === BT.ReadToolMsg
    @test BT.builtin_msg_type("search")  === BT.SearchToolMsg
    @test BT.builtin_msg_type("move")    === BT.MoveToolMsg
    @test BT.builtin_msg_type("fetch")   === BT.FetchToolMsg
    # No special rendering → the generic fallback (never an error).
    @test BT.builtin_msg_type("execute") === BT.GenericToolMsg   # Bash comes via BashCall
    @test BT.builtin_msg_type("think")   === BT.GenericToolMsg
    @test BT.builtin_msg_type("other")   === BT.GenericToolMsg
    @test BT.builtin_msg_type("brand_new_tool_kind") === BT.GenericToolMsg
    # All are one family.
    for T in (BT.EditToolMsg, BT.ReadToolMsg, BT.SearchToolMsg, BT.MoveToolMsg,
              BT.FetchToolMsg, BT.GenericToolMsg)
        @test T <: BT.BuiltinToolMsg <: BT.ToolMsg
    end
end

@testset "build routes each kind to its type; name stays the filter identity" begin
    @test gt("edit", "Edit", "edit a.jl")   isa BT.EditToolMsg
    @test gt("read", "Read", "Read a.jl")   isa BT.ReadToolMsg
    @test gt("fetch", "WebFetch", "f")      isa BT.FetchToolMsg
    @test gt("move", "Bash", "mv")          isa BT.MoveToolMsg
    @test gt("other", "ToolSearch", "t")    isa BT.GenericToolMsg
    # Grep and Glob RENDER identically → the SAME type, but remain SEPARATE
    # filter identities (the toolbar groups by `tool_key`, i.e. the name).
    grep = gt("search", "Grep", "rg foo")
    glob = gt("search", "Glob", "**/*.jl")
    @test grep isa BT.SearchToolMsg && glob isa BT.SearchToolMsg
    @test BT.tool_key(grep) == "Grep"
    @test BT.tool_key(glob) == "Glob"
    @test BT.tool_key(gt("read", "Read", "x")) == "Read"
    # The generic `/tool` clause AND the specific name both match a built-in.
    @test BT.msg_lens_keys(grep) == ["tool", "tools", "Grep"]
end

@testset "content_summary dispatches on the message type" begin
    @test BT.content_summary(BT.EditToolMsg,   [dif("src/a.jl", "x\ny", "x\ny\nz")]) == "a.jl · +1 line"
    @test BT.content_summary(BT.EditToolMsg,   [dif("a", "1", "1\n2"), dif("b", "1", "")]) == "2 files · +1 line"
    @test BT.content_summary(BT.SearchToolMsg, [txt("src/a.jl:1:hit\nsrc/b.jl:2:hit")]) == "2 matches"
    @test BT.content_summary(BT.MoveToolMsg,   [txt("renamed src/old.jl -> src/new.jl")]) == "old.jl → new.jl"
    @test BT.content_summary(BT.FetchToolMsg,  [txt("Fetched https://example.com/docs ok")]) == "example.com"
    # Fall back to the shared default when the type-specific shape isn't present.
    @test BT.content_summary(BT.SearchToolMsg, [txt("no hits, just prose")]) == "19 bytes"
    @test BT.content_summary(BT.ReadToolMsg,   [txt("l1\nl2\nl3")]) == "3 lines · 8 bytes"
    @test BT.content_summary(BT.GenericToolMsg, CV[]) == ""
    # The ```julia first-line summary lives in the default → MCP eval gets it.
    @test BT.content_summary(BT.JuliaEvalToolMsg, [txt("```julia\nx = 1 + 2\n```\n3")]) == "x = 1 + 2"
end

@testset "MCP type tree: one routing point, per-tool affordances" begin
    @test BT.mcp_msg_type("bt_julia_eval")          === BT.JuliaEvalToolMsg
    @test BT.mcp_msg_type("bt_julia_continue")      === BT.JuliaContinueToolMsg
    @test BT.mcp_msg_type("bt_julia_interrupt")     === BT.JuliaInterruptToolMsg
    @test BT.mcp_msg_type("bt_julia_restart")       === BT.JuliaRestartToolMsg
    @test BT.mcp_msg_type("bt_julia_list_sessions") === BT.JuliaListSessionsToolMsg
    @test BT.mcp_msg_type("bt_show")                === BT.ShowToolMsg
    @test BT.mcp_msg_type("some_third_party")       === BT.GenericMCPToolMsg
    @test BT.JuliaEvalToolMsg <: BT.JuliaEvalCall <: BT.MCPToolMsg
    @test BT.JuliaContinueToolMsg <: BT.JuliaEvalCall

    # eval/continue RUN code → pin at once, ship code + timeout + ⊗ stoppable.
    ev = mcp("bt_julia_eval"; raw = Dict{String,Any}("code" => "1+1", "timeout" => 60,
                                                       "env_path" => "/p"))
    @test BT.pin_immediately(ev) === true
    d = Dict{String,Any}(); BT.mcp_input_extras!(d, ev)
    @test d["code"] == "1+1" && d["stoppable"] === true && d["timeout_s"] == "60s"
    @test BT.executed_preview(ev) === nothing        # code preview is the eval-specific path

    # Control tools produce no output that reveals their action → executed_preview
    # ships an always-visible command preview.
    @test BT.executed_preview(mcp("bt_julia_interrupt"; raw = Dict{String,Any}("env_path" => "/p"))) == "interrupt (SIGINT) /p"
    @test BT.executed_preview(mcp("bt_julia_restart"; raw = Dict{String,Any}("env_path" => "/p"))) == "restart (fresh process) /p"
    @test BT.executed_preview(mcp("bt_julia_list_sessions")) == "list active Julia sessions"
    # env_path streams late → a readable fallback until it arrives.
    @test BT.executed_preview(mcp("bt_julia_interrupt")) == "interrupt (SIGINT) the active session"
    di = Dict{String,Any}(); BT.mcp_input_extras!(di, mcp("bt_julia_interrupt"; raw = Dict{String,Any}("env_path" => "/p")))
    @test di["command"] == "interrupt (SIGINT) /p" && !haskey(di, "stoppable")
end

@testset "the real interrupt is JuliaEvalCall-only; others no-op" begin
    cm = BT.ChatModel
    evalcall(m)  = which(BT.request_tool_stop!, Tuple{cm, typeof(m)}).sig.parameters[3]
    @test evalcall(mcp("bt_julia_eval"))          === BT.JuliaEvalCall
    @test evalcall(mcp("bt_julia_continue"))      === BT.JuliaEvalCall
    @test evalcall(mcp("bt_julia_interrupt"))     === BT.ToolMsg   # falls to the no-op
    @test evalcall(mcp("bt_show"))                === BT.ToolMsg
    @test evalcall(gt("read", "Read", "x"))       === BT.ToolMsg
end

end
