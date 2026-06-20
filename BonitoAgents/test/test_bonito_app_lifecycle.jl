# Regression tests for the BonitoAppMsg lifecycle bugs that surfaced under
# `bt_show_app`:
#
#   * Bug 1: the chat auto-expanded the body on the FIRST ACP "new" event,
#     before the tool result had delivered `shown_app: <id>`. The browser
#     then asked the worker to render with the TOOL ID (m.id) as the app
#     id — which has no worker route — and the worker KeyError'd ("tool
#     body unavailable: KeyError: \"toolu_…\" not found"). Auto-expand
#     must wait until `b.app_id` is captured from a result content block.
#
#   * Bug 3: the old `process_update!(::BonitoAppMsg)` override drained snaps
#     from `m.updates` searching for the result; the snap that contained the
#     result was CONSUMED before the generic loop ran, so the chat never
#     emitted any tool_update for the completed call — the body never opened
#     even after `b.app_id` was set. The result snap must reach the generic
#     loop AND its tool_update must carry expand=true.

using Test
using Bonito
import BonitoAgents
import AgentClientProtocol as Acp
const BT  = BonitoAgents
const ACP = Acp

# A bare ChatModel hooked to a ServerState; transport is a stub. Each test
# captures emits by overriding chat_emit on this chat instance.
function fresh_chat()
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")
    BT.ChatModel(state, mktempdir();
                  transport = BT.MockTransport((o, i) -> nothing))
end

# Drive a fresh MCP-shaped ToolCall through `process_update!` and return the
# stream of tool_update events the chat emitted. The chat's `comm` is an
# Observable that `chat_emit` writes to — we listen there to capture without
# monkey-patching the method table.
function drive_bonito_app(initial_status::String, snaps::Vector{<:ACP.ToolCall};
                          tool_id::String = "toolu_TEST")
    chat   = fresh_chat()
    server = "btworker"
    title  = "bt_show_app"

    ch = Channel{ACP.ToolCall}(length(snaps))
    initial = ACP.MCPCall(tool_id, "other", title, initial_status,
                          ACP.ToolContent[], ch,
                          server, "bt_show_app", Dict{String,Any}())
    msg = BT.bonito_app_msg(initial, server, chat)

    emits = Dict{String,Any}[]
    Bonito.on(chat.comm) do d; push!(emits, copy(d)); end

    for snap in snaps; put!(ch, snap); end
    close(ch)

    BT.process_update!(msg, initial)
    return (msg = msg, emits = emits)
end

# Build a minimal MCPCall snap with given status + content.
mksnap(status::String, content::Vector{<:ACP.ToolContent}; tool_id="toolu_TEST") =
    ACP.MCPCall(tool_id, "other", "bt_show_app", status, content,
                Channel{ACP.ToolCall}(0),
                "btworker", "bt_show_app", Dict{String,Any}())

# ── Bug 1: empty-app_id → no auto-expand ─────────────────────────────────

@testset "Bug 1: BonitoAppMsg with empty app_id must NOT auto-expand" begin
    # Header for a fresh, just-arrived BonitoAppMsg (no result content yet).
    m_no_id  = BT.BonitoAppMsg("toolu_X", "bonito_app", "bt_show_app", "in_progress",
                                "", time(), nothing, "btworker", "", nothing)
    m_with_id = BT.BonitoAppMsg("toolu_Y", "bonito_app", "bt_show_app", "completed",
                                "", time(), nothing, "btworker", "abc12345", nothing)

    # `auto_expand_body` is the dispatch the in-loop expand check uses.
    @test BT.auto_expand_body(m_no_id)   === false
    @test BT.auto_expand_body(m_with_id) === true

    # `augment_header!` decorates the "new" event the chat ships when the
    # message is created. It must NOT set expand=true for a body whose app
    # the worker doesn't know about yet — otherwise the browser fires
    # ToolRenderCommand against a tool_id the worker has no route for.
    d1 = Dict{String,Any}("kind" => "bonito_app", "id" => m_no_id.id)
    BT.augment_header!(d1, m_no_id, "")
    @test !haskey(d1, "expand") || d1["expand"] != true

    d2 = Dict{String,Any}("kind" => "bonito_app", "id" => m_with_id.id)
    BT.augment_header!(d2, m_with_id, "")
    @test d2["expand"] === true
end

# ── Bug 3: result snap reaches the generic loop AND triggers expand ─────

@testset "Bug 3: the result snap emits a tool_update with expand=true" begin
    intermediate = mksnap("in_progress",
        ACP.ToolContent[ACP.TextContent("…running")])
    result       = mksnap("completed",
        ACP.ToolContent[ACP.TextContent("shown_app: cafef00d99")])

    r = drive_bonito_app("in_progress", [intermediate, result])

    @test length(r.emits) == 2   # one tool_update per snap
    # The "running" snap has no app reference yet ⇒ no expand.
    @test r.emits[1]["status"] == "in_progress"
    @test !haskey(r.emits[1], "expand")
    # The result snap captures app_id AND emits expand=true on the SAME update.
    @test r.emits[2]["status"] == "completed"
    @test r.emits[2]["expand"] === true
    @test r.msg.app_id == "cafef00d99"
end

@testset "Bug 3: app_id capture is sticky — later snaps don't overwrite" begin
    first_result = mksnap("completed",
        ACP.ToolContent[ACP.TextContent("shown_app: first-id")])
    accidental   = mksnap("completed",
        ACP.ToolContent[ACP.TextContent("shown_app: second-id")])

    r = drive_bonito_app("in_progress", [first_result, accidental])
    @test r.msg.app_id == "first-id"
end

@testset "Bug 3: app_id captured from initial.content (already-complete tool)" begin
    # The MCP tool's RESULT can land in the initial ToolCall.content if the
    # tool completed before the chat caught the "new" notification — bonito_app_msg
    # picks it up via `find_app_reference`. No update snaps needed.
    chat   = fresh_chat()
    server = "btworker"
    ch     = Channel{ACP.ToolCall}(0); close(ch)
    initial = ACP.MCPCall("toolu_done", "other", "bt_show_app", "completed",
                          ACP.ToolContent[ACP.TextContent("shown_app: ready-id")], ch,
                          server, "bt_show_app", Dict{String,Any}())
    msg = BT.bonito_app_msg(initial, server, chat)
    @test msg.app_id == "ready-id"
    @test BT.auto_expand_body(msg) === true   # now expand IS allowed
end
