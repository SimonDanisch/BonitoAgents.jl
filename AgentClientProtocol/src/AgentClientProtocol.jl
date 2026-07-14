module AgentClientProtocol

using JSON
using Base64
using HTTP

include("types.jl")
include("connection.jl")
include("worker_transport.jl")
include("messages.jl")
include("client.jl")

export Client, MCPServer, ImageAttachment, prompt!, cancel!, set_config_option!
export Transport, WorkerTransport
export Handler, DiscardHandler
export ConnectionClosed
export SessionUpdate, AgentMessageChunk, UserMessageChunk, AgentThoughtChunk
export ToolCallNotif, ToolCallUpdateNotif, PlanUpdate, UnknownUpdate
# Subagent visibility: the tagged wire wrapper + the distilled activity events
# a turn's `on_subagent` sink receives (see `prompt!`).
export SubagentUpdate, SubagentActivity, parent_tool_use_id
export TextContent, ImageContent, DiffContent, ToolCallLocation, PlanEntry
export parse_tool_content_item, parse_session_update, parse_location
# Typed tool-call family — downstream consumers dispatch on these instead of
# probing strings on the generic ACP `tool.kind`.
export ToolCall, GenericTool, BashCall, TodoWriteCall, TaskCall, MCPCall

# `send`, `recv`, `on_request` are dispatched verbs that callers overload on
# their concrete Transport / Handler types. Intentionally NOT exported — `send`
# would collide with `Sockets.send`, and `on_request` is package-namespaced to
# avoid clashes with user code. `prompt_updates`/`parse_update!`/`TurnState` are
# internal to `prompt!` and likewise unexported.

end
