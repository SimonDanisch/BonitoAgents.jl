# bonitoagents.js is now an ES6 module — see `ChatLib` further down. It's
# loaded lazily by the `Bonito.ES6Module(...).then(...)` interpolation
# inside ChatModel's jsrender, NOT injected as a classic <script> tag.
# Loading it as a classic script would syntax-error on the `export`
# statements.

# Message types. `ChatModel` is defined FIRST so each message can hold a `chat`
# back-ref — its emit/persist sink, used by `send!`/`append!`/`close` (the
# message IS the streaming target). History-loaded messages carry `chat ===
# nothing` and are never appended to. Mirrors the existing `ChatModel.parent`
# back-ref pattern, so it's idiomatic here.
abstract type ChatMsg end

# A user's submission, pushed onto `ChatModel.user_messages` by the browser send
# handler and consumed by the `run_chat!` loop. Distinct from `ACP.UserMessage`
# (the replay-echo message kind) — this is purely the chat-side request item.
struct UserMessage
    text::String
    images::Vector{AgentClientProtocol.ImageAttachment}
end
UserMessage(text::AbstractString) = UserMessage(String(text), AgentClientProtocol.ImageAttachment[])

# ── ChatModel ──────────────────────────────────────────────────────────────
# Shared per project, lifetime = project's lifetime. One instance lives in
# `state.chat_models[project_id]`; every browser tab viewing the project gets
# a per-session view via `Base.copy(::ChatModel)`. The shared bits — message
# store, ACP client, persistent chat session, the user-message queue — are
# shared across sessions; the Observable fields are per-session connected
# children so their JS bridges GC cleanly when the tab closes.
mutable struct ChatModel
    # Convention: lock first. Now only a guard around `msgs_store` for the
    # read-only comm handlers (msgs.request / tool.render) that read it
    # concurrently with the single `run_chat!` consumer — NOT a mutation
    # funnel. All chat-state mutation happens on the one `run_chat!` task.
    lock::ReentrantLock
    state::ServerState
    cwd::String
    project_id::String

    # Where chat.md + tools/<id>.json live (resolved via `chat_storage_dir`).
    chat_dir::String

    # Persistent state (loaded from disk on construction)
    chat_session::Any                    # ChatSession from persistence.jl
    msgs_store::Vector{ChatMsg}

    # The agent IS the session: how to spawn/dial + the live ACP client once
    # started (see agents.jl). Read the live client via `client(model.agent)`.
    agent::AgentProvider
    mcp_servers::Vector{AgentClientProtocol.MCPServer}

    # The user's turns. The browser send handler `put!`s a `UserMessage`; the
    # `run_chat!` task is the SOLE consumer (one turn at a time). Shared across
    # per-session views so every tab feeds the same queue.
    user_messages::Channel{UserMessage}

    # One-shot history prelude prepended to the next prompt after a session
    # change that lost claude's jsonl (see `arm_history_replay!`). Empty = none.
    pending_history_replay::Ref{String}

    # Single bidirectional channel between Julia and the browser BonitoChat.
    # Tagged-dict wire format; see chat_emit / chat_dispatch! below.
    comm::Observable{Dict{String,Any}}

    # Status surface for the chat header (banner + reconnect state).
    session_alive::Observable{Bool}
    last_error::Observable{String}

    # True while a turn is in flight (set/cleared around the `run_chat!` turn).
    # The single source of truth for the busy spinner — the header binds its
    # class to this, so no separate busy_start/busy_end comm events are needed.
    busy_active::Observable{Bool}

    # Session metadata for the chat header: a heterogeneous list of TYPED
    # items rendered by `header_pill` dispatch. Today: the agent's
    # `ACP.ConfigOption`s (model / permission mode / effort) parsed from the
    # session-setup result; future agents add their own item types + a
    # `header_pill` method — the header skeleton never changes. Reset on every
    # bring-up (`start_chat_client!`); ephemeral, never persisted.
    session_meta::Observable{Vector{Any}}

    # The single `run_chat!` consumer task. Started once (guarded) by
    # `start_chat_client!`; survives `restart_chat_session!` (which only swaps
    # the ACP client, not the consumer). Shared across per-session views.
    consumer_task::Ref{Union{Task,Nothing}}

    # The per-chat background-output poller task (the taskbar's server-side
    # bookkeeping loop — walks this chat's live bg items every second). A FIELD,
    # not a global registry: its lifetime is the chat's, so a closed/dropped chat
    # takes it with it. There is no global IdDict to leak (the old design pinned
    # every chat alive and had to be hand-drained on each teardown path).
    poller_task::Ref{Union{Task,Nothing}}

    # Restart coordination, per shared chat. Fields, not `IdDict{ChatModel}`
    # globals: `restart_gen` (the old global was bumped per restart and NEVER
    # deleted → it pinned every restarted chat's model forever) and
    # `restart_inflight` (one bring-up worker at a time) live and die with the
    # chat. `restart_lock` guards the brief read-test-set (held only there, never
    # across the seconds-long bring-up). See `restart_chat_session!`.
    restart_inflight::Base.RefValue{Bool}
    restart_gen::Base.RefValue{Int}
    restart_lock::ReentrantLock

    # Backreference for per-session copies. `nothing` for the shared parent;
    # points back to it for any `copy(model, session)` view so writes to the
    # broadcast observables reach every tab via the parent→child bridges.
    parent::Union{ChatModel,Nothing}

    # Tool content cache: tool_id => raw content (JSON-parsed or text).
    # Populated on demand from persistence (tools/<id>.json) by
    # `cache_tool_content!`. Per-chat (NOT shared) — each session view has
    # its own cache so concurrent renders don't race.
    tool_content_cache::Dict{String,Vector}

    # PlotPane handle (window-scoped; set per session view, not shared).
    plotpane::Any

    # Live todo list for the taskbar (shared via parent).
    live_todo::Ref{Any}

    # TaskBar items for the pin-board (shared observable across session views).
    taskbar_items::Observable{Vector{TaskbarItem}}

    # Turn sequence counter — bumped at the start of each prompt turn; used to
    # detect stale stream events from a previous turn (see `drain_turn!`).
    turn_seq::Ref{Int}

    # Count of active `prompt!` turns (normally 0 or 1). Two turns are only
    # possible when a restart races an in-flight prompt — bounded by the CAS
    # guard in `restart_chat_session!`.
    turns_active::Ref{Int}

    # `time()` of the last inbound stream activity (shared). With a live
    # background shell the SDK holds the prompt open even after the agent
    # goes idle (validated against the real agent: no idle event, no
    # response, indefinitely) — so the busy spinner keys off THIS, not off
    # prompt resolution. See `update_busy!`.
    last_stream_at::Base.RefValue{Float64}

    # The taskbar's elapsed-time clock (shared). A Julia `Timer`
    # (`ensure_taskbar_clock!`) sets this to `time()` once a second while
    # items are live; the TaskBar's elapsed labels are `map(clock)` text
    # bindings. This is the ONLY taskbar ticking mechanism — there is no JS
    # poller. `taskbar_clock_on` guards the single timer.
    taskbar_clock::Observable{Float64}
    taskbar_clock_on::Base.RefValue{Bool}

    # Current provider for this chat — the singleton descriptor the worker spawns
    # (a `BinAgent`, e.g. the `ClaudeCodeAgent` singleton). Observable so the UI
    # provider-switcher can react.
    provider::Observable{Any}

    # Pending permission / question asks for THIS chat: request key → (reply
    # channel, default value to send on teardown). A FIELD, not a module Dict
    # keyed by request id — the old `PENDING_PERMISSIONS` / `PENDING_QUESTIONS`
    # globals stored the ChatModel itself, pinning every chat that ever prompted
    # past its close. This lives and dies with the chat; `sweep_pending_asks!`
    # drains it on teardown. Guarded by the shared `lock` (held only for the
    # brief dict op, never across the wait).
    pending_asks::Dict{String, Tuple{Channel, Any}}
    # Write-recency order for `tool_content_cache` (most-recent LAST). Drives LRU
    # eviction in `cache_tool_content!` so a very long chat's cache stays bounded
    # (old tool bodies fall back to disk) without ever dropping the live / recent
    # ones. Shared with the cache — same lifetime, same `lock`.
    tool_cache_order::Vector{String}
end

# The provider tracked by the `provider` observable: the singleton descriptor the
# worker spawns for this chat.
agent_kind(a::WorkerAgent) = a.provider

function ChatModel(state::ServerState, cwd::AbstractString;
    project_id::AbstractString="",
    mcp_servers=AgentClientProtocol.MCPServer[],
    agent::Union{AgentProvider,Nothing}=nothing)
    chat_dir = chat_storage_dir(state, project_id, cwd)
    chat_session = load_session(chat_dir, cwd)
    msgs_store = load_history(chat_session)
    # Every chat runs on a worker: the dashboard hands a `WorkerAgent`. There is
    # no local/in-process agent fallback anymore — a chat cannot exist without a
    # worker, so a missing agent is a programming error, not a silent default.
    agent === nothing &&
        error("ChatModel requires an agent (a WorkerAgent); none was provided")
    actual_agent = agent
    busy_active = Observable(false)
    # Wire busy_active → sidebar status LED: a prompt going in-flight (or
    # finishing) flips chat_status, which the sidebar wants to know about
    # immediately, not on the next chat_signal edge. The listener is
    # anchored to `busy_active` itself (lives as long as the ChatModel
    # does, GCed with it), so there's no leak.
    on(busy_active) do _; notify_chats!(state); end
    return ChatModel(
        ReentrantLock(),
        state, String(cwd), String(project_id),
        chat_dir,
        chat_session, msgs_store,
        actual_agent,
        collect(AgentClientProtocol.MCPServer, mcp_servers),
        Channel{UserMessage}(64),
        Ref(""),                    # pending_history_replay
        Observable(Dict{String,Any}()),
        Observable(true),
        Observable(""),
        busy_active,
        Observable(Any[]),          # session_meta
        Ref{Union{Task,Nothing}}(nothing),   # consumer_task
        Ref{Union{Task,Nothing}}(nothing),   # poller_task
        Ref(false),                 # restart_inflight
        Ref(0),                     # restart_gen
        ReentrantLock(),            # restart_lock
        nothing,                    # parent: this is the shared instance itself
        Dict{String,Vector}(),      # tool_content_cache
        nothing,                    # plotpane: window-scoped, set per session view
        Ref{Any}(nothing),          # live_todo
        Observable(TaskbarItem[]),  # taskbar_items (pin-board state)
        Ref(0),                     # turn_seq
        Ref(0),                     # turns_active
        Ref(0.0),                   # last_stream_at
        Observable(time()),         # taskbar_clock (ticked by a Julia Timer)
        Ref(false),                 # taskbar_clock_on
        # Provider observable tracks the AGENT (the source of truth): the kind
        # the worker spawns for a WorkerAgent, the agent's own type locally.
        Observable{Any}(agent_kind(actual_agent)),
        Dict{String, Tuple{Channel, Any}}(),   # pending_asks
        String[],                              # tool_cache_order (LRU for the cache)
    )
end

# Per-tab bridge for a POLYMORPHIC observable. A plain `map(identity, session,
# obs)` types the child to the INITIAL value's concrete type (Observables builds
# the result observable from the runtime value), so a later update carrying a
# DIFFERENT concrete type throws a `convert` MethodError inside the notify. For
# `provider` that update IS a backend switch (`MockAgent` → `OpenCodeAgent`, …):
# the throw propagated out of `s.provider[] = new_provider`, aborting
# `switch_provider!` before `restart_chat_session!` ever ran, which the header
# surfaced as "switch failed". Keeping the child `Observable{Any}` lets the held
# value change type across a switch. (Session-scoped `on` auto-GCs on close, same
# lifetime guarantee as the `map(session, …)` bridges.)
function any_bridge(session::Bonito.Session, src::Observable)
    dest = Observable{Any}(src[])
    on(session, src) do v
        dest[] = v
    end
    return dest
end

# Per-session view. SHARES the lock, client, msgs_store, chat_session, the
# user-message queue, etc. with the parent. Observable fields are bridged via
# `map(identity, session, obs)` so each tab gets its own connected child
# (auto-GC'd on session close).
function Base.copy(m::ChatModel, session::Bonito.Session)
    lock(m.lock) do
        ChatModel(
            m.lock,
            m.state, m.cwd, m.project_id,
            m.chat_dir,
            m.chat_session, m.msgs_store,
            m.agent, m.mcp_servers,
            m.user_messages,           # shared queue → all sessions feed one consumer
            m.pending_history_replay,
            map(identity, session, m.comm),
            map(identity, session, m.session_alive),
            map(identity, session, m.last_error),
            map(identity, session, m.busy_active),
            map(identity, session, m.session_meta),
            m.consumer_task,           # shared → only the parent runs the loop
            m.poller_task,             # shared → one poller per chat
            m.restart_inflight,        # shared → one restart coordinator per chat
            m.restart_gen,
            m.restart_lock,
            m,    # parent → the shared instance we copied from
            m.tool_content_cache,      # shared Dict; per-tab views see same RAM cache
            nothing,                   # plotpane: per WINDOW — ChatPaneRef sets it
            m.live_todo,               # shared Ref — one live list per chat
            map(identity, session, m.taskbar_items),   # per-tab TaskBar bridge
            m.turn_seq,                # shared counter
            m.turns_active,            # shared counter
            m.last_stream_at,          # shared timestamp
            map(identity, session, m.taskbar_clock),   # per-tab clock bridge
            m.taskbar_clock_on,        # shared guard
            any_bridge(session, m.provider),  # per-tab provider bridge (Any-typed: provider type varies across a switch)
            m.pending_asks,            # shared → asks resolve against the parent
            m.tool_cache_order,        # shared with tool_content_cache (one LRU per chat)
        )
    end
end

# Resolve to the shared parent so writes to broadcast observables reach every
# connected tab via the parent→child bridges.
shared(m::ChatModel) = m.parent === nothing ? m : m.parent

# `chat_emit` writes the SHARED comm so every connected tab sees the event via
# its own per-session bridge. Callers may pass either the shared parent or a
# per-session view — `shared(model)` resolves the right target.
chat_emit(model::ChatModel, event::AbstractDict) =
    (shared(model).comm[] = Dict{String,Any}(event); nothing)

# ── Concrete message types (carry the `chat` back-ref) ──────────────────────
mutable struct UserMsg <: ChatMsg
    text::String
    # `true` when this bubble was submitted while an earlier turn was still in
    # flight — the consumer hasn't picked it up yet, so we show it dimmed with
    # a "queued" badge. Cleared via the `user_unqueue` wire event when
    # `run_turn!` finally pops it off `user_messages`.
    queued::Bool
    chat::Union{ChatModel,Nothing}
end
UserMsg(text::AbstractString) = UserMsg(String(text), false, nothing)
UserMsg(chat::ChatModel, text::AbstractString) = UserMsg(String(text), false, chat)

# A `/compact` session summary, rendered as a centered separator block — NOT a
# user message. Claude Code persists it in its jsonl as a synthetic user record
# with `isCompactSummary: true`, but claude-agent-acp doesn't surface that flag
# over ACP — only the body text. We route on the stable prefix instead (see
# `SUMMARY_PREFIX` / `is_summary_text`). `html` caches the rendered markdown the
# same way `AgentMsg` does.
mutable struct SummaryMsg <: ChatMsg
    # Wire identity for the JS node cache: `summary_final` targets the bubble
    # by id (a DOM-only lookup missed virtually-scrolled-out summaries).
    # Reload-constructed summaries get a fresh uuid — finals only happen live.
    id::String
    text::String
    html::String
    chat::Union{ChatModel,Nothing}
end
SummaryMsg(text::AbstractString) = SummaryMsg(string(uuid4()), String(text), "", nothing)
SummaryMsg(chat::ChatModel, text::AbstractString) = SummaryMsg(string(uuid4()), String(text), "", chat)
# Under MARKDOWN_LOCK (reentrant — markdown_html locks it again): the
# read-render-write must be atomic against `append!`'s text-grow+cache-clear,
# see the lock's doc near its definition.
ensure_html!(m::SummaryMsg) = lock(MARKDOWN_LOCK) do
    isempty(m.html) ? (m.html = markdown_html(m.text)) : m.html
end

# The exact opening Claude Code writes on `/compact` resume. Verbatim Claude
# Code text — extremely unlikely as a real user message, and the only signal we
# get from ACP (claude-agent-acp drops `isCompactSummary` on the wire).
const SUMMARY_PREFIX = "This session is being continued from a previous conversation that ran out of context."
is_summary_text(text::AbstractString) = startswith(lstrip(text), SUMMARY_PREFIX)

mutable struct AgentMsg <: ChatMsg
    id::String
    text::String
    # Cached rendered HTML so scrolling never has to re-run `Markdown.parse`.
    # Empty = not yet built; `ensure_html!` populates it lazily. Set eagerly
    # by the 2-arg constructor (history-load / replay-adopt: text is final),
    # and at `close(::AgentMsg)` for streaming (text becomes final there).
    # `append!` clears it (defensive; streaming bubbles aren't asked for via
    # `msgs.request`, but a stale cache would silently lose the trailing chunks).
    html::String
    chat::Union{ChatModel,Nothing}
    # True between `send!` (streaming start) and `close` (turn-end finalize).
    # The orphan sweep keys on this so an ACP session that drops mid-stream
    # — and never runs the normal `close` — gets the bubble finalized + the
    # `agent_final` wire event emitted from `sweep_turn_orphans!`. Also makes
    # `close` idempotent: re-close on an already-final bubble is a no-op
    # instead of double-appending to chat.md.
    in_flight::Bool
end
# Cache starts empty in BOTH paths (history-load/replay-adopt AND streaming):
# `ensure_html!` populates on first request, then every subsequent fetch is free.
# Eagerly pre-building here would push the per-message parse onto chat-open;
# lazy distributes it across the scroll events that actually need it (~3 ms
# per 30-msg visible window) while keeping repeat fetches allocation-free.
# History-load / replay-adopt: `in_flight = false` (text is already final).
# Streaming construction: `in_flight = true`, flipped in `close(::AgentMsg)`.
AgentMsg(id::AbstractString, text::AbstractString) =
    AgentMsg(String(id), String(text), "", nothing, false)
AgentMsg(chat::ChatModel, text::AbstractString) =
    AgentMsg(string(uuid4()), String(text), "", chat, true)

# Lazy cache populate. Used by `msg_to_dict` / `wire_final`. Atomic under
# MARKDOWN_LOCK against `append!` (see the lock's doc near its definition).
ensure_html!(m::AgentMsg) = lock(MARKDOWN_LOCK) do
    isempty(m.html) ? (m.html = markdown_html(m.text)) : m.html
end

# ── Tool messages — abstract + typed variants ──────────────────────────────
# Replaces the previous "one ToolMsg struct with a `kind::String` discriminator"
# pattern: every Claude tool family with distinct UX (Bash background, MCP,
# subagent Task, generic) gets its own concrete subtype so renderers,
# persistence and the taskbar dispatch on the type instead of probing strings.
# The five header fields (id/kind/title/status/summary) plus the
# elapsed-time tracking (started_at/finished_at) are duplicated across the
# variants — small cost, big dispatch clarity. `kind` here is still the ACP
# abstraction ("read"/"execute"/…); the *actual* tool name lives in
# subtype-specific fields (e.g. `MCPToolMsg.tool_name`).
"""
    ToolMsg <: ChatMsg

Abstract supertype for one tool-call bubble in the chat. Concrete subtypes:

  • `GenericToolMsg` — fallback (Read, Edit, Grep, … plus any future tool)
  • `BashToolMsg`    — Claude's Bash tool; carries `is_background`
  • `TaskToolMsg`    — subagent `Task` / `Agent` tool; carries `task_name`
  • `MCPToolMsg`     — `mcp__<server>__<tool>` calls (our `bt_*` tools, others)
  • `BonitoAppMsg`   — a live worker Bonito app (`bt_show_app` / `show_remote_app!`)

All variants share `id` / `kind` / `title` / `status` / `summary`, plus
`started_at` / `finished_at` epoch seconds used by the tool-pill timer.
"""
abstract type ToolMsg <: ChatMsg end

mutable struct GenericToolMsg <: ToolMsg
    id::String
    kind::String
    name::String                          # ACP tool name ("Read", "ToolSearch", …); "" if the agent sent no meta
    title::String
    status::String
    summary::String                       # cached header summary; full content on disk
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    chat::Union{ChatModel,Nothing}
    # The call's arguments. Claude's native tools (Read/Edit/Write/…) carry
    # the REAL file path here (`file_path`) — their titles are display
    # strings like "Read CONVENTIONS.md", NOT paths. Arrives late (streamed
    # input, see update_from_snap!), so it starts empty on real agents.
    raw_input::Dict{String,Any}
end

# Back-compat forms: 8-arg (pre-`name`) and 9-arg (pre-`raw_input`) — used
# by test fixtures and history reload, which has no raw_input on disk.
GenericToolMsg(id, kind, title, status, summary, started_at, finished_at, chat) =
    GenericToolMsg(id, kind, "", title, status, summary, started_at, finished_at, chat)
GenericToolMsg(id, kind, name, title, status, summary, started_at, finished_at, chat) =
    GenericToolMsg(id, kind, name, title, status, summary, started_at, finished_at, chat,
                   Dict{String,Any}())

mutable struct BashToolMsg <: ToolMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    command::String
    # Claude's human-readable summary of WHAT the command does ("Monitor
    # system load for 30 min"). Arrives late (streamed input); when present
    # it replaces the raw script as the pill/taskbar title — a multiline
    # one-liner monitor loop tells the user nothing.
    description::Union{String,Nothing}
    is_background::Bool
    # Background-task streaming (`run_in_background`): the agent's tool_call
    # "completes" the moment the command is LAUNCHED, but the shell keeps running.
    # The poller tails the agent's output file (`bg_output_path`, from byte
    # `bg_offset`), accumulates into `bg_text`, and flips `bg_running` off when
    # the file's fd closes (shell exited). `is_live` keys off `bg_running` so a
    # launched-but-running task stays live instead of "finishing immediately".
    bg_output_path::String
    bg_offset::Int
    bg_running::Bool
    bg_text::String
    chat::Union{ChatModel,Nothing}
end

# Back-compat 14-arg form (pre-`description`): test fixtures.
BashToolMsg(id, kind, title, status, summary, started_at, finished_at,
            command, is_background, bg_output_path, bg_offset, bg_running,
            bg_text, chat) =
    BashToolMsg(id, kind, title, status, summary, started_at, finished_at,
                command, nothing, is_background, bg_output_path, bg_offset,
                bg_running, bg_text, chat)

# What the pill/taskbar shows for a bash: the human-readable description
# when claude sent one, else the ACP title (usually the raw command).
bash_display_title(b::BashToolMsg) =
    b.description === nothing || isempty(b.description) ? b.title : b.description

mutable struct TaskToolMsg <: ToolMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    description::String
    is_background::Bool
    task_name::Union{String,Nothing}      # SDK `name` — for SendMessage addressing
    chat::Union{ChatModel,Nothing}
end

mutable struct MCPToolMsg <: ToolMsg
    id::String
    kind::String
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    server::String                        # "bonitoagents" / "playwright" / …
    tool_name::String                     # bare name (without `mcp__<server>__`)
    # The call's raw arguments straight off the wire. For the eval family
    # this carries `code` / `timeout` / `env_path` — what the live code
    # preview, the timeout badge, and the per-tool interrupt need BEFORE the
    # tool produces any result content.
    raw_input::Dict{String,Any}
    chat::Union{ChatModel,Nothing}
end

# Back-compat 10-arg form (pre-`raw_input`): used by test fixtures and any
# caller without raw arguments to hand over.
MCPToolMsg(id, kind, title, status, summary, started_at, finished_at,
           server, tool_name, chat) =
    MCPToolMsg(id, kind, title, status, summary, started_at, finished_at,
               server, tool_name, Dict{String,Any}(), chat)

# A live worker Bonito app (its own type, NOT a generic/MCP tool — it renders an
# interactive embed and offers Detach, see render_tool_body / augment_header!
# below). Recognised at BUILD time from the tool NAME (`bt_show_app`) or KIND
# (`bonito_app`, the programmatic `show_remote_app!` path) — never by sniffing
# the persisted result content, which isn't on disk yet for a just-completed
# live tool (that race is why the detach button vanished on fresh apps). The
# registered app id is resolved lazily at render time (it lives in the result
# content for `bt_show_app`, or is the tool id itself for `show_remote_app!`).
mutable struct BonitoAppMsg <: ToolMsg
    id::String
    kind::String                          # always "bonito_app"
    title::String
    status::String
    summary::String
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    server::String                        # MCP server badge ("" for programmatic)
    # The id the worker registered the app under. `show_remote_app!` registers
    # under the message id (so it's known immediately); `bt_show_app` returns it
    # in its result, captured ONCE on completion. Empty ⇒ fall back to `id` at
    # render. Render/header read this field — NEVER the content.
    app_id::String
    chat::Union{ChatModel,Nothing}
end

mutable struct ThoughtMsg <: ChatMsg
    id::String
    text::String
    chat::Union{ChatModel,Nothing}
    # Same semantics as `AgentMsg.in_flight` — orphan-sweep target + makes
    # `close` idempotent (so a session-died sweep can't double-persist).
    in_flight::Bool
end
ThoughtMsg(id::AbstractString, text::AbstractString) = ThoughtMsg(String(id), String(text), nothing, false)
ThoughtMsg(chat::ChatModel, text::AbstractString)    = ThoughtMsg(string(uuid4()), String(text), chat, true)

# TodoWrite stays a top-level ChatMsg (NOT under ToolMsg) because it arrives
# as its own `Plan` wire variant — distinct from the `tool_call` channel —
# and is the canonical LiveTracking message (each new PlanUpdate ABSORBS into
# the previous bubble; see `absorb!` further down).
mutable struct TodoListMsg <: ChatMsg
    id::String                            # synthetic UUID, used by JS for DOM keying
    entries::Vector{PlanEntry}
    started_at::Float64
    finished_at::Union{Float64,Nothing}
    chat::Union{ChatModel,Nothing}
end
TodoListMsg(entries::Vector{PlanEntry}) =
    TodoListMsg(string(uuid4()), entries, time(), nothing, nothing)
TodoListMsg(chat::ChatModel, entries) =
    TodoListMsg(string(uuid4()), collect(PlanEntry, entries), time(), nothing, chat)

# ── Trait helpers ──────────────────────────────────────────────────────────
# A live tool message is one whose `status` hasn't yet hit a terminal state.
# The tool pill's pulsing glow + the taskbar slot both subscribe to this.
is_live(m::ToolMsg) =
    m.finished_at === nothing && !(m.status in ("completed", "failed"))
# A background bash's tool_call "completes" at LAUNCH but the shell runs on. Once
# we know its output file, liveness is the poller's `bg_running` (the output
# file's fd still open), NOT the tool_call status — so the bubble keeps pulsing
# (and its taskbar slot + timer stay) until the shell actually exits.
function is_live(m::BashToolMsg)
    (m.is_background && !isempty(m.bg_output_path)) && return m.bg_running
    return m.finished_at === nothing && !(m.status in ("completed", "failed"))
end
# `finished_at` flips to non-nothing inside `try_absorb_todo!` once the
# absorbed entries become all-done — `is_live` checking that field is what
# lets the next TodoWrite start a fresh bubble instead of absorbing into
# the just-finished list. While entries are still in flight we trust
# claude's per-item status to drive the live decision.
is_live(t::TodoListMsg) =
    t.finished_at === nothing &&
    any(e -> e.status in ("pending", "in_progress"), t.entries)
is_live(::ChatMsg) = false

# "This tool started but never reached terminal status" — used by the
# `run_turn!` end-of-turn sweep as a defense-in-depth backstop. Keyed on
# `status` (NOT `is_live`) so it does NOT match a backgrounded bash whose
# tool_call already reported `"completed"` at launch (those have a separate
# lifecycle owned by the bg poller). A live worker app (`BonitoAppMsg`) also
# stays terminal-status here for the same reason — its app lifetime is owned
# by the EvalBridge, not the chat-message close.
is_turn_orphan(m::ToolMsg)    = !(m.status in ("completed", "failed"))
# Streaming AgentMsg / ThoughtMsg whose `close` never ran (session died
# mid-stream so `process_update!` / `process!` exited via exception before
# their close-in-finally). The sweep's `close(m)` ships the missing wire
# final and persists to chat.md — without this they'd remain forever as
# half-rendered streaming bubbles in JS and missing from disk.
is_turn_orphan(m::AgentMsg)   = m.in_flight
is_turn_orphan(m::ThoughtMsg) = m.in_flight
# Live plan (any pending/in_progress entry) whose driving agent disappeared:
# `close(::TodoListMsg)` stamps `finished_at` so the JS taskbar removes
# the slot and the next agent's first `TodoWrite` starts a fresh plan
# instead of absorbing into the abandoned one. A plan whose entries are
# all-done already has `finished_at` set; `is_live` is false; we skip.
is_turn_orphan(m::TodoListMsg) = is_live(m)
# NOTE: background `BashToolMsg` (status="completed" + bg_running=true) is
# DELIBERATELY NOT an orphan. The shell IS a child of the ACP subprocess
# we just killed — it may or may not have died with its parent depending
# on process-group / nohup setup. What's stable is the OUTPUT FILE
# already on disk (and the tail RPC over the WS to the worker), so the
# poller's existing "fd closed / no growth" detection finalises the
# bubble naturally if the shell did die, or keeps streaming if it
# didn't. Force-failing in the sweep would discard accumulated output
# and skip the natural completion event — worse UX than letting the
# poller settle it.
is_turn_orphan(::ChatMsg)     = false

# A background-or-streamy task that deserves a taskbar slot. Default false;
# Bash with `run_in_background`, Task/Agent with `run_in_background`, and
# TodoListMsg opt in.
is_taskbar_item(t::BashToolMsg) = t.is_background
is_taskbar_item(t::TaskToolMsg) = t.is_background
is_taskbar_item(::TodoListMsg)  = true
is_taskbar_item(::ChatMsg)      = false

# ── Pin-board maintenance (see taskbar.jl) ──────────────────────────────────
# All mutations go through these two: read-modify-write under the chat lock,
# the Observable assignment OUTSIDE it (listeners — JS bridges — must never
# run while we hold the lock).
function pin_task!(chat::ChatModel, item::TaskbarItem)
    s = shared(chat)
    items = lock(s.lock) do
        v = copy(s.taskbar_items[])
        idx = findfirst(t -> t.id == item.id, v)
        idx === nothing ? push!(v, item) : (v[idx] = item)
        v
    end
    s.taskbar_items[] = items
    ensure_taskbar_clock!(s)
    return nothing
end

# The taskbar's elapsed-time ticker — IN JULIA, not a browser setInterval.
# ONE `Timer` per chat ticks `taskbar_clock` once a second while items are
# live, and stops itself when the bar empties (or the chat closes). The
# TaskBar's labels are `map(clock)` text bindings, so a tick updates exactly
# those text nodes. `taskbar_clock_on` guards against spawning a second timer.
function ensure_taskbar_clock!(chat::ChatModel)
    s = shared(chat)
    start = lock(s.lock) do
        (s.taskbar_clock_on[] || isempty(s.taskbar_items[])) ? false :
            (s.taskbar_clock_on[] = true)
    end
    start || return nothing
    Timer(1.0; interval = 1.0) do timer
        stop = lock(s.lock) do
            done = !isopen(s.user_messages) || isempty(s.taskbar_items[])
            done && (s.taskbar_clock_on[] = false)
            done
        end
        if stop
            close(timer)
        else
            s.taskbar_clock[] = time()
        end
    end
    return nothing
end

function unpin_task!(chat::ChatModel, id::AbstractString)
    s = shared(chat)
    items = lock(s.lock) do
        v = s.taskbar_items[]
        any(t -> t.id == id, v) ? filter(t -> t.id != id, v) : nothing
    end
    items === nothing || (s.taskbar_items[] = items)
    return nothing
end

is_pinned(chat::ChatModel, id::AbstractString) =
    any(t -> t.id == id, shared(chat).taskbar_items[])

# Pin policy. Bash / Task / the eval family pin the moment they start
# (they're what the bar is FOR); every other tool joins only if it's still
# running after 3s — a sub-second Read never flickers in. The timer
# re-checks liveness so a tool that finished (or was force-failed) in the
# meantime can't leave a zombie slot; `unpin_task!` in the update loop's
# finally is the authoritative removal.
pin_immediately(::ToolMsg)      = false
pin_immediately(::BashToolMsg)  = true
pin_immediately(::TaskToolMsg)  = true
pin_immediately(b::MCPToolMsg)  = b.tool_name in EVAL_TOOL_FAMILY

taskbar_label(b::ToolMsg)     = first(pretty_tool_title(b.title))
taskbar_label(b::BashToolMsg) = first(pretty_tool_title(bash_display_title(b)))

function tool_taskbar_item(chat::ChatModel, b::ToolMsg)
    s = shared(chat)
    # 0-based store index → deterministic click-to-scroll anchor. Stable:
    # the store is append-only.
    idx = lock(s.lock) do
        i = findfirst(m -> m === b, s.msgs_store)
        i === nothing ? -1 : i - 1
    end
    TaskbarItem(b.id, :tool, tool_icon(b.kind), taskbar_label(b);
                started = b.started_at, stoppable = true, msg_index = idx)
end

function pin_tool!(chat::ChatModel, b::ToolMsg)
    if pin_immediately(b)
        pin_task!(chat, tool_taskbar_item(chat, b))
    else
        Timer(3) do _
            is_live(b) && pin_task!(chat, tool_taskbar_item(chat, b))
        end
    end
    return nothing
end

# Refresh a pinned slot's label (a bash's human description arrives late).
refresh_pin!(chat::ChatModel, b::ToolMsg) =
    (is_pinned(chat, b.id) && pin_task!(chat, tool_taskbar_item(chat, b)); nothing)

# Tool kind → icon
const TOOL_ICONS = Dict(
    "read" => "📄",
    "edit" => "✏️",
    "delete" => "🗑️",
    "move" => "📦",
    "search" => "🔍",
    "execute" => "▶",
    "think" => "💭",
    "fetch" => "🌐",
    "other" => "⚙",
)

tool_icon(kind) = get(TOOL_ICONS, kind, "⚙")

# claude-agent-acp labels MCP tool calls with their raw wire name,
# `mcp__<server>__<tool>` (e.g. `mcp__bonitoagents__bt_julia_eval`). That's
# noise in the chat header — strip the `mcp__<server>__` prefix so the
# header reads `bt_julia_eval`. Returns `(pretty_title, server)`; `server`
# is "" for non-MCP tools. The non-greedy server capture stops at the
# first `__`, so tool names keeping single underscores survive intact.
function pretty_tool_title(title::AbstractString)
    m = match(r"^mcp__(.+?)__(.+)$", title)
    m === nothing && return (String(title), "")
    return (String(m.captures[2]), String(m.captures[1]))
end

# Short summary shown on the collapsed tool header (before expand).
# Per-kind summaries are tuned for at-a-glance comprehension:
#   edit:   one file → "name · ±N lines";  many → "K files · ±N lines"
#   search: count of result rows that look like grep hits
#   move:   "src → dst" extracted from the content text
#   fetch:  domain of the URL extracted from the content
#   else:   line / byte count of the first text block
function content_summary(kind::AbstractString, content::AbstractVector)
    isempty(content) && return ""

    if kind == "edit"
        diffs = [c for c in content if c isa DiffContent]
        if !isempty(diffs)
            total_delta = 0
            for d in diffs
                total_delta += length(split(d.new_text, '\n')) -
                               length(split(something(d.old_text, ""), '\n'))
            end
            sign_str = total_delta > 0 ? "+$total_delta" : string(total_delta)
            line_word = abs(total_delta) == 1 ? "line" : "lines"
            return length(diffs) == 1 ?
                   "$(basename(diffs[1].path)) · $sign_str $line_word" :
                   "$(length(diffs)) files · $sign_str $line_word"
        end
    end

    if kind == "search"
        text = join((c.text for c in content if c isa TextContent), "\n")
        if !isempty(text)
            hits = count(line -> match(r"^[^\s:]+:\d+[:\-]", line) !== nothing,
                split(text, '\n'))
            if hits > 0
                return "$hits $(hits == 1 ? "match" : "matches")"
            end
        end
    end

    if kind == "move"
        text = join((c.text for c in content if c isa TextContent), "\n")
        m = match(r"([\S]+)\s*(?:->|→|to)\s*([\S]+)", text)
        if m !== nothing
            return "$(basename(m.captures[1])) → $(basename(m.captures[2]))"
        end
    end

    if kind == "fetch"
        text = join((c.text for c in content if c isa TextContent), "\n")
        m = match(r"https?://([^/\s]+)", text)
        if m !== nothing
            return String(m.captures[1])
        end
    end

    # MCP tools (kind=="other") whose first text block is a fenced ```julia
    # code block — show the first code line as the summary so calls like
    # bt_julia_eval show "x = 1 + 2" instead of "5 lines · 124 bytes".
    if !isempty(content) && content[1] isa TextContent
        m = match(r"^\s*```julia\r?\n(.*?)\r?\n```"s, content[1].text)
        if m !== nothing
            first_line = strip(split(String(m.captures[1]), '\n')[1])
            if !isempty(first_line)
                return length(first_line) > 50 ?
                       SubString(first_line, 1, prevind(first_line, 50)) * "…" :
                       first_line
            end
        end
    end

    for c in content
        if c isa TextContent
            n = count('\n', c.text) + 1
            b = sizeof(c.text)
            return n <= 1 ? "$(b) bytes" : "$(n) lines · $(b) bytes"
        elseif c isa DiffContent
            return basename(c.path)
        end
    end
    return ""
end

# Header info shipped to JS at message-create time. Full content is NOT
# included — JS asks via requestToolRender(id), Julia loads the persisted
# ACP params from disk and ships the rendered DOM via Bonito.dom_in_js.
#
# Exception: edit tools embed a small "preview" HTML snippet in the header
# itself so the user can skim what changed without expanding the body.
# `chat_dir` is needed so we can read the persisted DiffContent from disk;
# pass "" when no on-disk content is available (preview is then omitted).
#
# Dispatches on the abstract `ToolMsg` — the four header fields plus
# `started_at` / `finished_at` are shared across every concrete variant.
# Subtype-specific augmentations (e.g. the `server` badge for `MCPToolMsg`)
# patch the dict in their own dispatch arm below.
# Stable per-tool filter key, the identity the message-type filter toolbar
# groups by. The ACP tool NAME, not the title (a Bash title is the literal
# command line). Reloads land as `GenericToolMsg` with the persisted key in
# `name` (see `append_tool`); pre-name chats fall back to the ACP kind.
tool_key(m::GenericToolMsg) = isempty(m.name) ? m.kind : m.name
tool_key(::BashToolMsg)     = "Bash"
tool_key(::TaskToolMsg)     = "Task"
tool_key(m::MCPToolMsg)     = m.tool_name          # bare name: "bt_show", "bt_julia_eval"
tool_key(::BonitoAppMsg)    = "bt_show_app"

function tool_header_dict(m::ToolMsg, chat_dir::AbstractString="")
    pretty_title, server = pretty_tool_title(m.title)
    d = Dict{String,Any}(
        "type" => "tool",
        "id" => m.id,
        "kind" => m.kind,
        # Filter identity for the per-tool show/hide toolbar (see filterKey
        # in bonitoagents.js).
        "tool" => tool_key(m),
        "icon" => tool_icon(m.kind),
        "title" => pretty_title,
        # "" for non-MCP tools; the MCP server name otherwise so the JS
        # header can show it as a dim prefix badge.
        "server" => server,
        "status" => m.status,
        "summary" => m.summary,
        "started_at" => m.started_at,
        # Only background-y tools deserve a taskbar slot. A regular Read in
        # `in_progress` pulses briefly but doesn't crowd the taskbar.
        "taskbar" => is_taskbar_item(m),
    )
    m.finished_at === nothing || (d["finished_at"] = m.finished_at)
    augment_header!(d, m, chat_dir)
    return d
end

# Per-variant tweaks. The typed variants opt in to their extras here.
function augment_header!(d::Dict, m::GenericToolMsg, chat_dir::AbstractString)
    # The real file path for claude's native tools (Read/Edit/Write title
    # display strings; the path is in raw_input.file_path) — feeds the ✎
    # editable derivation in augment_generic_header!.
    hint = tool_path_hint(m)
    hint === nothing || (d["path_hint"] = hint)
    augment_generic_header!(d, chat_dir)
end
function augment_header!(d::Dict, m::BashToolMsg, chat_dir::AbstractString)
    m.is_background && (d["background"] = true)
    # Live bash always shows a stop (CSS hides it once the pill finishes).
    d["stoppable"] = true
    # History reload drops the in-RAM description — recover it from the
    # persisted rawInput so old bash pills keep their readable title.
    if (m.description === nothing || isempty(m.description)) && !isempty(chat_dir)
        ri = stored_raw_input(chat_dir, m.id)
        if ri isa AbstractDict
            v = get(ri, "description", nothing)
            v isa AbstractString && !isempty(v) && (m.description = String(v))
        end
    end
    if m.description !== nothing && !isempty(m.description)
        d["title"] = m.description
        # The raw command stays inspectable without expanding: ship it for
        # the header tooltip.
        isempty(m.command) || (d["command"] = m.command)
    end
    augment_generic_header!(d, chat_dir)
end
function augment_header!(d::Dict, m::TaskToolMsg, chat_dir::AbstractString)
    m.is_background && (d["background"] = true)
    d["stoppable"] = true
    m.task_name === nothing || (d["task_name"] = m.task_name)
    augment_generic_header!(d, chat_dir)
end
# The BonitoMCP eval family. These get the live-code preview, the timeout
# badge, and (for the in-flight ones) the per-tool interrupt affordance.
const EVAL_TOOL_FAMILY     = ("bt_julia_eval", "bt_julia_continue", "bt_julia_interrupt")
const EVAL_STOPPABLE_TOOLS = ("bt_julia_eval", "bt_julia_continue")
# Mirrors BonitoMCP's DEFAULT_TIMEOUT / Pkg auto-disable (session.jl) so the
# badge shows what the server will actually do when no explicit timeout rides
# on the call.
function eval_timeout_label(raw::AbstractDict)
    t = get(raw, "timeout", nothing)
    t isa Real && return t > 0 ? "$(round(Int, t))s" : "no timeout"
    code = get(raw, "code", "")
    return occursin(r"\bPkg\.", String(code)) ? "no timeout" : "30s"
end

# The eval-family extras (code preview, timeout badge, ⊗ stop) keyed on the
# call's raw_input. Factored out of `augment_header!` because claude-agent-acp
# STREAMS tool input: the initial `tool_call` usually has an EMPTY rawInput
# and the real arguments ride a later `tool_call_update` — so these extras
# must also be derivable per-snap in `process_update!`, not only at header
# build time.
function eval_header_extras!(d::Dict, m::MCPToolMsg)
    if m.tool_name in EVAL_TOOL_FAMILY && !isempty(m.raw_input)
        # Ship the code being executed so the client can paint a compact
        # preview while the eval is still running (the post-completion body
        # renders the same code through the Monaco Code section instead).
        code = get(m.raw_input, "code", nothing)
        code isa AbstractString && !isempty(code) && (d["code"] = code)
        d["timeout_s"] = eval_timeout_label(m.raw_input)
        # The ⊗ interrupt affordance — only the calls that hold an eval in
        # flight; `bt_julia_interrupt` itself is not stoppable.
        m.tool_name in EVAL_STOPPABLE_TOOLS && (d["stoppable"] = true)
    end
    return d
end

function augment_header!(d::Dict, m::MCPToolMsg, chat_dir::AbstractString)
    # Server already lives in `d` from `pretty_tool_title`, but the raw bare
    # tool name (without `mcp__server__`) is more authoritative — prefer it.
    isempty(m.server)    || (d["server"] = m.server)
    isempty(m.tool_name) || (d["title"]  = m.tool_name)
    eval_header_extras!(d, m)
    # A path argument on the call (bt_show's `path`, …) feeds the ✎
    # editable derivation in augment_generic_header! below.
    hint = mcp_path_hint(m.raw_input)
    hint === nothing || (d["path_hint"] = hint)
    augment_generic_header!(d, chat_dir)
end
# A live worker app. Its `kind` is already "bonito_app" (the JS gates the ⤢
# detach button on that). The body auto-opens — but ONLY once we know the
# worker-registered app id; expanding on the initial "new" event (before
# `bt_show_app` has returned its `shown_app: <id>` content and we've
# populated `b.app_id`) would trigger a body render with `m.id` as the
# app id, which the worker has no route for — a `KeyError "toolu_…"`
# painted into the chat. The follow-up `process_update!` emits a fresh
# `tool_update` with `expand=true` once `b.app_id` is captured.
function augment_header!(d::Dict, m::BonitoAppMsg, chat_dir::AbstractString)
    isempty(m.server) || (d["server"] = m.server)
    isempty(m.app_id) || (d["expand"] = true)
    return d
end

# `bt_show` auto-expand is shared across the generic tool variants and depends
# on persisted on-disk content, so it lives here once. Edit-tool previews used
# to be HTML strings emitted here too, but that "all `-` then all `+`" view
# was misleading and divergent from the body's Monaco diff. Edit tools now
# auto-mount a single compact Monaco DiffEditor as their body (see
# `auto_expand_body` for the eager-mount, and `render_diff_block` for the
# capped height); no separate HTML preview.
function augment_generic_header!(d::Dict, chat_dir::AbstractString)
    if !isempty(chat_dir)
        content = load_tool_content(chat_dir, d["id"])
        # bt_show references auto-expand the pill; inline image content
        # (Read on a PNG, …) only ships its mime — the client's Native
        # Images mode decides the depiction.
        has_show_reference(content) && (d["expand"] = true)
        mime = tool_media_mime(content)
        mime === nothing || (d["show_mime"] = mime)
        # Path-link affordance: a file the plotpane Monaco editor can open
        # (the tool title renders as a clickable link). The in-RAM path
        # hint (live ToolMsg raw_input) takes precedence; the persisted one
        # covers headers rebuilt after a history reload.
        if !haskey(d, "path_hint")
            hint = stored_path_hint(chat_dir, String(d["id"]))
            hint === nothing || (d["path_hint"] = hint)
        end
        ep = editable_path_from(d, content)
        if ep !== nothing
            d["editable"]  = true
            d["edit_path"] = ep
        end
    end
    return d
end

# Extensions the ✎ editor refuses outright: media that has dedicated viewers
# (images/video render inline) and binary formats Monaco would just garble.
# Everything else — including extensionless files like Makefile/LICENSE and
# unknown extensions — is offered for editing; a content-level binary sniff
# in `FileEditor`'s jsrender catches what the extension check can't.
const EDITOR_BINARY_EXTS = (".pdf", ".zip", ".tar", ".gz", ".tgz", ".bz2",
    ".xz", ".7z", ".exe", ".dll", ".so", ".dylib", ".bin", ".wasm", ".o",
    ".a", ".class", ".jar", ".ico", ".ttf", ".otf", ".woff", ".woff2",
    ".eot", ".jld2", ".arrow", ".parquet", ".sqlite", ".db", ".h5",
    ".hdf5", ".npy", ".npz", ".pkl", ".gguf", ".onnx", ".pt", ".safetensors")

function editor_openable(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    return !(ext in SHOW_IMAGE_EXTS || haskey(SHOW_VIDEO_MIME, ext) ||
             ext in EDITOR_BINARY_EXTS)
end

# Does a tool title look like a file path (vs a label like "bash", a
# sentence, or a URL)? Tools that operate on a file conventionally title
# themselves with that path.
function path_like_title(t::AbstractString)
    isempty(t) && return false
    occursin(r"^[a-z][a-z0-9+.-]*://"i, t) && return false   # URLs → fetch, not files
    occursin(' ', t) && return false                          # human sentences
    occursin('/', t) && return true
    return !isempty(splitext(t)[2])                           # bare "foo.jl"
end

# A path argument riding on an MCP tool call (bt_show's `path`, custom
# tools' `file`/`file_path`/…).
function mcp_path_hint(raw::AbstractDict)
    for k in ("path", "file_path", "file", "filename", "notebook_path")
        v = get(raw, k, nothing)
        v isa AbstractString && !isempty(v) && return String(v)
    end
    return nothing
end

tool_path_hint(::ToolMsg)         = nothing
tool_path_hint(m::MCPToolMsg)     = mcp_path_hint(m.raw_input)
tool_path_hint(m::GenericToolMsg) = mcp_path_hint(m.raw_input)

# The worker-side file path a tool's ✎ "open in editor" button should edit.
# Sources, in priority order: a `bt_show` reference in the output, an edit
# tool's diff target, a path argument from the call's rawInput
# (`d["path_hint"]` — claude's Read/Edit/Write carry `file_path` there),
# or a title that IS a path. The title check is strict (`path_like_title`)
# because real agents title display strings — claude's Read is titled
# "Read CONVENTIONS.md", which is NOT a path; its real path arrives via
# rawInput. `nothing` ⇒ no button (no path found, or a media/binary file
# the editor can't usefully open).
function editable_path_from(d::AbstractDict, content)
    ref = find_show_reference(content)
    p = ref === nothing ? nothing : parse_show_path(ref)
    if p === nothing && content isa AbstractVector
        for c in content
            if c isa AgentClientProtocol.DiffContent && !isempty(c.path)
                p = c.path
                break
            end
        end
    end
    if p === nothing
        hint = String(get(d, "path_hint", ""))
        isempty(hint) || (p = hint)
    end
    if p === nothing
        t = String(get(d, "title", ""))
        path_like_title(t) && (p = t)
    end
    p === nothing && return nothing
    editor_openable(p) || return nothing
    return String(p)
end

# Same shape used by msg_to_dict so the JS virtual-scroll renderer treats
# all messages uniformly. The `cwd` argument is only consulted for ToolMsg
# (to render the edit preview); other variants ignore it.
msg_to_dict(m::UserMsg, _chat_dir::AbstractString="") =
    Dict{String,Any}("type" => "user", "text" => m.text, "queued" => m.queued)

function msg_to_dict(m::AgentMsg, _chat_dir::AbstractString="")
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => ensure_html!(m))
end

function msg_to_dict(m::SummaryMsg, _chat_dir::AbstractString="")
    Dict{String,Any}("type" => "summary", "id" => m.id, "html" => ensure_html!(m))
end

msg_to_dict(m::ToolMsg, chat_dir::AbstractString="") = tool_header_dict(m, chat_dir)

# Thoughts are lazy-loaded: header carries only id + a size hint. JS asks for
# the body via requestThoughtRender(id) when the user expands the <details>.
# Avoids shipping potentially huge thinking transcripts on every range fetch.
function msg_to_dict(m::ThoughtMsg, _chat_dir::AbstractString="")
    n = count('\n', m.text) + 1
    Dict{String,Any}("type" => "thought", "id" => m.id,
        "summary" => "$n $(n == 1 ? "line" : "lines")")
end

function msg_to_dict(m::TodoListMsg, _chat_dir::AbstractString="")
    rows = join(["""<div class="bt-plan-entry">
        <span class="bt-plan-status">$(e.status == "completed" ? "✓" : e.status == "in_progress" ? "▶" : "○")</span>
        <span>$(e.content)</span></div>""" for e in m.entries])
    d = Dict{String,Any}("type" => "plan", "id" => m.id, "html" => rows,
        "started_at" => m.started_at, "live" => is_live(m),
        # Cheap label for the taskbar slot — "3/5 done" reads at a glance.
        "summary" => todolist_summary(m.entries))
    m.finished_at === nothing || (d["finished_at"] = m.finished_at)
    return d
end

function todolist_summary(entries)
    isempty(entries) && return "todos"
    done = count(e -> e.status == "completed", entries)
    return "$done/$(length(entries)) done"
end

# ── Edit-tool body sizing ────────────────────────────────────────────────────
# Edit-tool bodies render as a Monaco `DiffEditor` (see `render_diff_block`).
# To keep multi-edit tool calls from flooding the chat with full-height
# editors, the body is initially rendered with `max_height = EDIT_BODY_COMPACT_PX`.
# The expand toggle re-renders with `max_height = EDIT_BODY_EXPANDED_PX` (or
# in the future, swaps the value through the editor's `max_height`
# Observable so the same Monaco instance resizes without re-mounting). This
# replaces the prior HTML-string "all − then all +" preview that lived above
# the body — that view was wrong (it dumped old then new instead of
# interleaving real hunks) and divergent from the body's Monaco render.
const EDIT_BODY_COMPACT_PX  = 240
const EDIT_BODY_EXPANDED_PX = 2000

# Tool-body rendering (Bonito DOM tree, includes BonitoBook MonacoEditor /
# DiffEditor instances). Called only when the user clicks expand; output is
# shipped to JS via Bonito.dom_in_js, which mounts the sub-DOM (Monaco etc.)
# inside the placeholder. Collapse on the JS side just empties the placeholder
# and lets the browser GC the editor instances.

function detect_language(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext == ".jl" && return "julia"
    ext in (".py", ".pyw") && return "python"
    ext in (".js", ".mjs", ".cjs") && return "javascript"
    ext in (".ts", ".tsx") && return "typescript"
    ext in (".md", ".markdown") && return "markdown"
    ext in (".html", ".htm") && return "html"
    ext == ".css" && return "css"
    ext == ".json" && return "json"
    ext in (".yml", ".yaml") && return "yaml"
    ext == ".toml" && return "toml"
    ext in (".sh", ".bash", ".zsh") && return "shell"
    ext in (".rs",) && return "rust"
    ext in (".go",) && return "go"
    return "plaintext"
end

# Read-only Monaco that sizes itself to content height exactly once.
# automaticLayout=false stops the polling loop that fights ResizeObserver.
# The js_init_func runs after the editor Promise resolves and sets an explicit
# pixel height so Monaco never gets a 0-height container.
const MONACO_RESIZE_INIT = js"""(monacoEditor) => {
    monacoEditor.editor.then(editor => {
        const div = monacoEditor.editor_div;
        const h = editor.getContentHeight();
        div.style.height = h + 'px';
        editor.layout({ width: div.offsetWidth || 600, height: h });
    });
}"""

function monaco_readonly(text::AbstractString, lang::AbstractString)
    BonitoBook.MonacoEditor(
        text;
        language=lang,
        readOnly=true,
        automaticLayout=false,
        scrollBeyondLastLine=false,
        lineNumbers="off",
        minimap=Dict(:enabled => false),
        # Force light Monaco. BonitoBook's "default" theme follows the host OS
        # `prefers-color-scheme` (dark here), which clashed with the light app.
        theme=Observable("vs"),
        js_init_func=MONACO_RESIZE_INIT,
    )
end

# Console output (captured stdout / stderr / error backtraces) → a
# `Bonito.RichText` terminal block: ANSI escape codes become styled spans
# instead of literal `\e[31m` garbage, and the `terminal-output` class gives
# monospace `pre-wrap`. Wrapped in `.bt-console` so the chat can size it.
console_block(body::AbstractString) = DOM.div(Bonito.RichText(body); class="bt-console")

# Render a single tool-content text block. Recognised shapes:
#  1. Fenced code (```lang\n...\n```)   → Monaco read-only with that language
#  2. Eval section (label:\n<body>)      → labeled card; `result` is a Julia
#     value repr → Monaco julia, the rest is console output → RichText.
#     Emitted by BonitoMCP's bt_julia_eval, which prefixes blocks with
#     "stdout" / "result" / "error".
#  3. ANSI-bearing prose                 → RichText (terminal block).
#  4. Mixed prose                        → Markdown.parse fallback.
const EVAL_SECTION_LABELS = ("stdout", "stderr", "result", "error")

function render_text_block(text::AbstractString)
    m = match(r"^\s*```(\w*)\r?\n(.*?)\r?\n```\s*$"s, text)
    if m !== nothing
        lang = isempty(m.captures[1]) ? "plaintext" : String(m.captures[1])
        return monaco_readonly(String(m.captures[2]), lang)
    end
    m = match(Regex("^(" * join(EVAL_SECTION_LABELS, "|") * "):\n(.*)\$", "s"), text)
    if m !== nothing
        label = String(m.captures[1])
        body = String(m.captures[2])
        # `result` is a Julia value's repr → julia syntax highlighting.
        # stdout / stderr / error are unstructured console output (captured
        # prints, stack traces) → RichText so ANSI colors survive and the
        # block stays a lightweight monospace pane, not a full editor.
        rendered = label == "result" ?
                   monaco_readonly(body, "julia") : console_block(body)
        return DOM.div(
            DOM.div(uppercase(label); class="bt-section-label"),
            rendered;
            class="bt-eval-section")
    end
    # Raw console dump that didn't match a section label but still carries
    # ANSI — render as a terminal block rather than letting Markdown.parse
    # mangle the escape codes.
    Bonito.has_ansi_codes(text) && return console_block(text)
    return DOM.div(Markdown.parse(text), class="bt-tool-md")
end

# A reusable collapsible section — the server-side (eager) counterpart of the
# JS `Collapsable` in bonitoagents.js. Renders a native <details>: the `body` is
# present from the start (no lazy fetch), used for eval Code/Output sub-sections
# inside an already-expanded tool card. `label` is the always-visible heading;
# `preview` (optional) is dim text next to it; `open` shows it expanded.
struct Collapsable
    label::String
    body::Any
    preview::String
    open::Bool
end
Collapsable(label::AbstractString, body; preview::AbstractString="", open::Bool=true) =
    Collapsable(String(label), body, String(preview), open)

function Bonito.jsrender(session::Session, c::Collapsable)
    summary_kids = Any[DOM.span(c.label; class="bt-subsection-label")]
    isempty(c.preview) || push!(summary_kids,
        DOM.span(c.preview; class="bt-subsection-preview"))
    Bonito.jsrender(session, DOM.details(
        DOM.summary(summary_kids...; class="bt-subsection-summary"),
        DOM.div(c.body; class="bt-subsection-body");
        class="bt-subsection",
        open=c.open ? true : nothing))
end

# Open by default — an already-expanded tool card should show everything without
# extra clicks; the collapsible just lets the user fold away a long code block
# or a noisy output to focus on the other.
tool_subsection(label::AbstractString, body; preview::AbstractString="", open::Bool=true) =
    Collapsable(label, body; preview, open)

# bt_julia_eval tool bodies: a ```julia code echo followed by stdout / result
# / error sections. Render as two collapsibles — "Code" (Monaco julia, same
# read-only editor the `read` file tool uses) and "Output" (the eval-section
# stack). Returns `nothing` if `content` isn't eval-shaped so the caller
# falls through to the generic renderer.
function render_eval_body(content)
    isempty(content) && return nothing
    code = nothing
    rest = []
    for c in content
        if c isa TextContent && code === nothing
            m = match(r"^\s*```julia\r?\n(.*?)\r?\n```\s*$"s, c.text)
            if m !== nothing
                code = String(m.captures[1])
                continue
            end
        end
        if c isa TextContent
            push!(rest, render_text_block(c.text))
        elseif c isa DiffContent
            push!(rest, render_diff_block(c))
        elseif c isa ImageContent
            push!(rest, DOM.img(src="data:$(c.mime_type);base64,$(c.data)",
                style=Styles("max-width" => "100%")))
        end
    end
    code === nothing && return nothing   # not eval-shaped — let caller handle it
    # `split` always yields ≥1 element (even for ""), so `first` is safe.
    first_line = strip(first(split(code, '\n')))
    code_preview = length(first_line) > 60 ?
                   SubString(first_line, 1, prevind(first_line, 60)) * "…" : first_line
    code_section = tool_subsection("Code", monaco_readonly(code, "julia");
        preview=code_preview)
    output_section = isempty(rest) ?
                     tool_subsection("Output", DOM.div("(no output)"; class="bt-tool-empty")) :
                     tool_subsection("Output", DOM.div(rest...))
    return DOM.div(code_section, output_section; class="bt-eval-body")
end

# Load the persisted ACP params for `tool_id` and parse the content array back
# into TextContent / DiffContent / ImageContent. Returns an empty vector if
# there's no saved snapshot (e.g. history loaded from chat.md but the tools/
# directory was never created on this server).
function load_tool_content(chat_dir::AbstractString, tool_id::AbstractString)
    params = load_tool_file(String(chat_dir), String(tool_id))
    params === nothing && return Any[]
    raw = get(params, "content", nothing)
    raw === nothing && return Any[]
    return Any[parse_tool_content_item(c) for c in raw if c isa AbstractDict]
end

# Two-tier content lookup for `render_tool_body`. RAM first: the chat's
# `tool_content_cache` carries the most recent snap content for every live
# tool, populated by `process_update!` for each snap (including empty initial
# ones). Disk fallback covers history reload after a server restart, where
# the cache is empty but `tools/<id>.json` still has the persisted state.
#
# The cache is authoritative for live tools — if a tool is in the cache with
# empty content, that genuinely means "the agent has not yet delivered any
# content for this tool", NOT "look on disk for a stale copy". The disk read
# only fires when the tool was never seen live by this server process
# (history reload from chat.md). Critically: this removes the
# "(no body — tool details not persisted)" race where an early expand hit
# disk before `persist_tool_content!` finished writing the first snap.
function tool_content_for_render(m::ToolMsg, chat_dir::AbstractString)
    # `tool_content_cache` is a plain Dict shared across per-session views and
    # written by the consumer task; a concurrent read during a rehash is a data
    # race (T8). Guard the lookup under the chat's lock; the disk fallback runs
    # off-lock (it's I/O and the key was absent under the lock).
    if m.chat !== nothing
        hit = lock(m.chat.lock) do
            haskey(m.chat.tool_content_cache, m.id) ?
                m.chat.tool_content_cache[m.id] : nothing
        end
        hit === nothing || return hit
    end
    return load_tool_content(chat_dir, m.id)
end

# Cap on how many tool bodies the in-RAM cache keeps. Every entry is also on
# disk (`persist_tool_content!` runs paired with each cache write), so once a
# chat blows past this the OLDEST non-empty bodies are evicted and re-read from
# disk on demand — bounding RAM on a marathon session without dropping the live
# or recently-touched tools. Generous so a normal chat never trips it.
const TOOL_CONTENT_CACHE_CAP = 256

# Record the latest snap's content into the in-RAM cache. Empty content is
# stored verbatim so the cache reflects the live snap state. Write under the
# chat's lock so readers (`tool_content_for_render`) never see a half-rehashed
# Dict (T8).
function cache_tool_content!(chat::Union{ChatModel,Nothing}, tool_id::AbstractString,
                              content::AbstractVector)
    chat === nothing && return nothing
    key = String(tool_id)
    lock(chat.lock) do
        cache = chat.tool_content_cache
        order = chat.tool_cache_order
        cache[key] = Vector{Any}(content)
        # Move `key` to most-recent in the LRU order.
        i = findlast(==(key), order)
        i === nothing || deleteat!(order, i)
        push!(order, key)
        # Evict oldest NON-EMPTY bodies until back under the cap. Skip empties:
        # an empty cache entry is the authoritative "no content yet" marker for a
        # live tool (see tool_content_for_render) — dropping it would let a render
        # fall through to a stale/absent disk copy. Skip the just-written key too.
        n = 1
        while length(cache) > TOOL_CONTENT_CACHE_CAP && n <= length(order)
            k = order[n]
            v = get(cache, k, nothing)
            if v === nothing
                deleteat!(order, n)            # stale order entry — prune, no shift
            elseif k == key || isempty(v)
                n += 1                          # keep; advance
            else
                delete!(cache, k)
                deleteat!(order, n)
            end
        end
    end
    return nothing
end

# A single DiffContent rendered as path-header + inline Monaco DiffEditor.
# `max_height` caps Monaco's content-based auto-sizing — pass a small value
# (`EDIT_BODY_COMPACT_PX`) for the collapsed body, a large one
# (`EDIT_BODY_EXPANDED_PX`) for the expanded body. The JS `MonacoDiffEditor`
# also exposes `setMaxHeight` on the container so the Collapsable can flip
# between the two without re-mounting Monaco (kept here as a fallback for
# the rare path where the body IS remounted, e.g. tool-update churn).
function render_diff_block(d::DiffContent; max_height::Int = EDIT_BODY_EXPANDED_PX)
    DOM.div(
        # The per-file header doubles as a path link (the chat's delegated
        # click listener opens it in the plotpane editor).
        DOM.div(d.path; class="bt-diff-header bt-path-link", dataPath=d.path),
        BonitoBook.DiffEditor(something(d.old_text, ""), d.new_text;
            language=detect_language(d.path),
            renderSideBySide=false,
            theme=Observable("vs"),   # light, matching the app (see monaco_readonly)
            max_height=max_height);
        class="bt-diff-block")
end

# Render search-tool output as one row per match. Recognises both `path:line:`
# (grep / rg default) and `path-line-` (grep -A/-B context). Lines that don't
# match either format are rendered as muted raw lines so we don't lose them.
function render_search_results(text::AbstractString)
    rows = []
    for line in split(text, '\n')
        isempty(strip(line)) && continue
        m = match(r"^([^:]+):(\d+):(.*)$", line)
        if m === nothing
            m = match(r"^([^-]+)-(\d+)-(.*)$", line)
        end
        if m !== nothing
            path = String(m.captures[1])
            push!(rows, DOM.div(
                # The hit's path is a clickable link (delegated chat listener
                # → plotpane editor); media/binary hits stay plain text.
                editor_openable(path) ?
                    DOM.span(path; class="bt-search-path bt-path-link",
                             dataPath=path) :
                    DOM.span(path; class="bt-search-path"),
                DOM.span(":" * String(m.captures[2]); class="bt-search-line"),
                DOM.code(strip(String(m.captures[3])); class="bt-search-snippet");
                class="bt-search-row"))
        else
            push!(rows, DOM.div(line; class="bt-search-raw"))
        end
    end
    DOM.div(rows...; class="bt-search-results")
end

function find_show_reference(content)
    for c in content
        c isa TextContent || continue
        startswith(c.text, "shown: ") && return c.text
    end
    return nothing
end

has_show_reference(content) = find_show_reference(content) !== nothing

# ── bt_show: render a worker file inline (ShowTool) ─────────────────────────
# A `shown: <path> …` text block (emitted by the `bt_show` MCP tool) becomes a
# `ShowTool`. Its `jsrender` fetches the file to the server (blocking the
# per-render task — the Collapsable's "loading…" placeholder shows meanwhile)
# and renders the right element. Video plays because Bonito's asset server
# honours HTTP Range requests, and we point `<video src>` at a served
# `Bonito.Asset` URL (not a multi-MB `data:` blob). No bytes pass through
# claude; the path is the only thing on the wire.

# Pull the path out of a `shown: <path>` header (tolerates a trailing
# ` (<mime>, <size>)` from older tool output). `nothing` if not a show ref.
function parse_show_path(text::AbstractString)
    nl = findfirst('\n', text)
    header = nl === nothing ? text : text[1:prevind(text, nl)]
    m = match(r"^shown:\s+(.+?)(?:\s+\([^)]*\))?\s*$", header)
    m === nothing ? nothing : String(m.captures[1])
end

# Pull the mime out of the `shown: <path> (<mime>, <size>)` reference. The
# wire ships it as `show_mime` so the client can decide how to depict the
# show (e.g. the "Native Images" toggle keys on image/*). `nothing` for
# refs without the parenthesized tail or a mime-shaped token.
function parse_show_mime(text::AbstractString)
    nl = findfirst('\n', text)
    header = nl === nothing ? text : text[1:prevind(text, nl)]
    m = match(r"\(([a-z0-9.+-]+/[a-z0-9.+-]+)\s*,", header)
    m === nothing ? nothing : String(m.captures[1])
end

# The displayable-media mime of a tool's content, if any: a bt_show
# reference's mime, or the mime of inline image content (e.g. the Read tool
# on a PNG ships an ACP ImageContent block). This is what the wire's
# `show_mime` field carries — the client's "Native Images" mode keys on it.
function tool_media_mime(content)
    ref = find_show_reference(content)
    ref === nothing || return parse_show_mime(ref)
    for c in content
        c isa ImageContent && return c.mime_type
    end
    return nothing
end

# A bt_show reference, rendered inline. Pure data — the fetch starts at render
# time (when the tool body is expanded), not at construction.
struct ShowTool
    state::ServerState
    project_id::String
    cwd::String
    path::String        # path as the WORKER sees it (absolute, or relative to its cwd)
end

# Always render synchronously: the fetch (minutes for a multi-GB video)
# blocks only the per-render @async task in `handle_command!(::ToolRender-
# Command)`, and the finished element ships through that handler's
# `dom_in_js` → `ChatLib.toolSlot` mount, which finds nodes the virtual
# scroll holds DETACHED. The earlier `@async` + `jsrender(::Task)` spinner path
# swapped the result in via Bonito's Observable machinery, whose
# document-scoped uuid lookup polls for 30s and then gives up — a video
# whose fetch outlived that window (or whose node was off-window at swap
# time) kept its spinner forever; only a manual re-render, by then on the
# isfile fast path, showed it.
# A file that can't be fetched/rendered (missing on the worker, transfer
# failed, unreadable) must degrade to a visible, self-contained error node —
# NOT throw out of `jsrender`, where Bonito's generic `handle_render_error`
# would swap in its own opaque placeholder (and the bt_show body would never
# carry the `.bt-tool-error` the UI/tests key on).
function Bonito.jsrender(session::Bonito.Session, st::ShowTool)
    body = try
        render_show_file(st)
    catch e
        @warn "bt_show: could not render file" path = st.path exception = (e, catch_backtrace())
        DOM.div("could not show $(basename(st.path)): $(sprint(showerror, e))";
            class = "bt-tool-error")
    end
    return Bonito.jsrender(session, body)
end

# The server-side path a ShowTool's file resolves to — no IO. Files under the
# project tree map straight onto the server mirror (cwd ⟷ worker_path); an
# absolute path outside the project lands in a server-side cache.
function show_server_path(st::ShowTool)
    proj = get(st.state.projects[], st.project_id, nothing)
    if !isabspath(st.path)
        return joinpath(st.cwd, st.path)
    elseif proj !== nothing && startswith(st.path, proj.worker_path)
        return joinpath(st.cwd, relpath(st.path, proj.worker_path))
    else
        return joinpath(st.cwd, ".bt-show-cache", basename(st.path))
    end
end

# Single-flight per destination: concurrent `tool.render` calls for the same
# file (native-toggle spam, several tabs) would otherwise both stream into the
# same `<dst>.partial` and corrupt it. The loser blocks until the winner's
# fetch lands, re-checks isfile, and returns without a second transfer.
# The per-destination lock registry lives on the SERVER (`state.show_fetch_inflight`,
# server_dst => lock), not a module global — server-scoped, dies with the server.
# It's pruned on SUCCESS (below): once the file is on disk every future caller
# short-circuits on the top `isfile` check and never needs the lock, so keeping
# it would just accumulate one ReentrantLock per distinct file ever shown. A
# FAILED fetch keeps its lock so a retry still serializes against a concurrent
# attempt (the two-writers-into-`<dst>.partial` race the lock exists to prevent).

# Resolve `st.path` to a file on the SERVER's disk, fetching it from the worker
# if we don't already have it. Blocks for the transfer (multi-GB videos take
# a while — receive_file streams into `<dst>.partial` and renames, so isfile
# never sees a torso). Throws if it can't be obtained.
function fetch_show_file(st::ShowTool)
    server_dst = show_server_path(st)
    isfile(server_dst) && return server_dst        # already mirrored or cached
    dst_lock = lock(st.state.lock) do
        get!(ReentrantLock, st.state.show_fetch_inflight, server_dst)
    end
    try
        return lock(dst_lock) do
            isfile(server_dst) && return server_dst    # the racer fetched it
            proj = get(st.state.projects[], st.project_id, nothing)
            proj === nothing && error("bt_show: file not on server and no worker to fetch from: $(st.path)")
            worker_src = isabspath(st.path) ? st.path : joinpath(proj.worker_path, st.path)
            mkpath(dirname(server_dst))
            fetch_file_from_worker(st.state, proj.worker_id, worker_src, server_dst; handoff_timeout=60.0)
            return server_dst
        end
    finally
        # Prune the lock once the file is on disk. Waiters already captured
        # `dst_lock`, so deleting the dict entry can't strand them; new callers
        # short-circuit on `isfile` before ever reaching the registry.
        if isfile(server_dst)
            lock(st.state.lock) do
                delete!(st.state.show_fetch_inflight, server_dst)
            end
        end
    end
end

# MIME inferred from extension → the right element. Media point `src` at a
# served `Bonito.Asset` (range-capable); text goes through Monaco; anything
# else gets a caption. `<video>`/`<img>` get explicit `type`/element so we
# cover webp/bmp/mov and emit correct MIME types.
const SHOW_VIDEO_MIME = Dict(".mp4" => "video/mp4", ".webm" => "video/webm",
    ".ogg" => "video/ogg", ".mov" => "video/quicktime")
const SHOW_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg")

# Click-to-enlarge. Clones the media into a fullscreen overlay (Esc or backdrop
# click closes). Self-contained so there's no global-JS dependency or load-order
# coupling; shared by bt_show previews and inline Read-tool images.
const LIGHTBOX_OPEN_JS = js"""
event => {
    event.stopPropagation();
    const wrap = event.currentTarget.closest('.bt-media-wrap');
    const media = wrap && wrap.querySelector('.bt-media');
    if (!media) return;
    const overlay = document.createElement('div');
    overlay.className = 'bt-lightbox-overlay';
    const big = media.cloneNode(true);
    big.classList.add('bt-lightbox-media');
    if (big.tagName === 'VIDEO') { big.controls = true; big.autoplay = true; }
    overlay.appendChild(big);
    const close = () => { overlay.remove(); document.removeEventListener('keydown', onkey); };
    const onkey = e => { if (e.key === 'Escape') close(); };
    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
    document.addEventListener('keydown', onkey);
    document.body.appendChild(overlay);
}
"""

# A media element (image / video) with click-to-enlarge. `src` can be a streamed
# proxied-asset url (string), a `Bonito.Asset`, or a data url — anything valid as
# an <img>/<video> src. `mime` only matters for the <video><source> type. Images
# enlarge on click; videos keep native controls for clicks and enlarge via the ⤢
# button (so a frame click still plays/pauses).
function media_element(src, mime::AbstractString, is_video::Bool)
    inner = is_video ?
        DOM.video(DOM.source(; src, type = mime); controls = true, class = "bt-media",
            style = Styles("max-width" => "100%", "display" => "block")) :
        DOM.img(; src, class = "bt-media", onclick = LIGHTBOX_OPEN_JS,
            style = Styles("max-width" => "100%", "display" => "block", "cursor" => "zoom-in"))
    return DOM.div(inner,
        DOM.button("⤢"; class = "bt-media-enlarge", type = "button",
            title = "Enlarge", onclick = LIGHTBOX_OPEN_JS);
        class = "bt-media-wrap")
end

# Source for a worker media file: a streamed proxied-asset url when the worker
# bridge is live (range reads on demand, no whole-file copy), else the
# copy-then-serve local Asset fallback (e.g. a reloaded chat with no live worker).
function show_media_src(st::ShowTool)
    eb = eval_bridge_for(st.state, st.project_id)
    if eb !== nothing
        proj = get(st.state.projects[], st.project_id, nothing)
        worker_src = (isabspath(st.path) || proj === nothing) ? st.path :
            joinpath(proj.worker_path, st.path)
        try
            return worker_asset_url(eb, worker_src)
        catch e
            @warn "bt_show: stream via bridge failed; copying instead" exception = (e, catch_backtrace()) path = st.path
        end
    end
    return Bonito.Asset(fetch_show_file(st))
end

# Not every ToolMsg subtype carries `raw_input` (Bash/Task/BonitoApp don't).
tool_raw_input(m) = hasproperty(m, :raw_input) ? m.raw_input : Dict{String,Any}()

# Inline image from a tool result (e.g. Read on a PNG ships an ACP ImageContent).
# Stream it from the worker when we can resolve a file path + live bridge (so big
# images don't ride as base64 through chat history); else fall back to the ACP
# base64 the agent sent. Either way it gets the lightbox via `media_element`.
function read_image_element(state::ServerState, project_id::AbstractString,
                            m::ToolMsg, c::ImageContent)
    fp = get(tool_raw_input(m), "file_path", nothing)
    eb = isempty(project_id) ? nothing : eval_bridge_for(state, project_id)
    if fp !== nothing && eb !== nothing
        try
            return media_element(worker_asset_url(eb, String(fp)), c.mime_type, false)
        catch e
            @warn "read image: stream via bridge failed; inlining base64" exception = (e, catch_backtrace())
        end
    end
    return media_element("data:$(c.mime_type);base64,$(c.data)", c.mime_type, false)
end

function render_show_file(st::ShowTool)
    ext = lowercase(splitext(st.path)[2])
    if ext in SHOW_IMAGE_EXTS
        return media_element(show_media_src(st), "", false)
    elseif haskey(SHOW_VIDEO_MIME, ext)
        return media_element(show_media_src(st), SHOW_VIDEO_MIME[ext], true)
    end
    # Non-media: the bytes have to be on the server (Monaco / caption read them).
    path = fetch_show_file(st)
    # Any non-binary file Monaco can show — known text extensions,
    # extensionless (Makefile, LICENSE), unknown extensions. Size-capped
    # like the editor, and NUL-sniffed so a mislabeled binary degrades to
    # the caption fallback instead of garbage.
    if editor_openable(path) && filesize(path) <= FILE_EDITOR_MAX_BYTES
        bytes = read(path)
        if !(0x00 in view(bytes, 1:min(length(bytes), 8192)))
            return monaco_readonly(String(bytes), detect_language(path))
        end
    end
    return DOM.div("$(basename(path)) · $(filesize(path)) bytes"; class="bt-tool-empty")
end

# ── File editor (plotpane Monaco) ───────────────────────────────────────────
# `✎` on a Read / bt_show tool opens the file in an EDITABLE Monaco editor
# docked in the plotpane. The edit targets the server-side mirror of the file
# (fetched from the worker on demand, exactly like ShowTool); Save writes the
# mirror AND pushes the file back to the worker so the agent sees the change.

# Refuse to open monsters — Monaco on a multi-MB file freezes the tab.
const FILE_EDITOR_MAX_BYTES = 2 * 1024 * 1024

struct FileEditor
    state::ServerState
    project_id::String
    server_path::String    # absolute file path on the server (mirror/cache)
    worker_path::String    # absolute file path on the worker; "" ⇒ no push
end

function Bonito.jsrender(session::Session, fe::FileEditor)
    isfile(fe.server_path) ||
        return Bonito.jsrender(session, DOM.div("file not found: $(fe.server_path)";
            class = "bt-tool-error"))
    filesize(fe.server_path) <= FILE_EDITOR_MAX_BYTES ||
        return Bonito.jsrender(session, DOM.div(
            "file too large for the editor ($(filesize(fe.server_path)) bytes)";
            class = "bt-tool-error"))
    bytes = read(fe.server_path)
    # The extension check (`editor_openable`) is a heuristic — verify on
    # content: a NUL byte in the first 8KB means binary, and Monaco + Save
    # would silently corrupt it.
    if 0x00 in view(bytes, 1:min(length(bytes), 8192))
        return Bonito.jsrender(session, DOM.div(
            "binary file — not opening in the editor: $(basename(fe.server_path))";
            class = "bt-tool-error"))
    end
    text = String(bytes)
    save_content = Observable{Union{Nothing,String}}(nothing)   # JS → Julia on save
    status = Observable("")                                      # Julia → JS status line
    editor = BonitoBook.MonacoEditor(
        text;
        language = detect_language(fe.server_path),
        readOnly = false,
        lineNumbers = "on",
        minimap = Dict(:enabled => false),
        scrollbar = Dict(:vertical => "auto", :horizontal => "auto"),
        mouseWheelScrollSensitivity = 1,
        fastScrollSensitivity = 5,
        wordWrap = "off",
        theme = Observable("vs"),   # light, matching the app
        # Expose the live editor instance for the Save button + Ctrl-S.
        js_init_func = js"""(me) => {
            me.editor.then(ed => { me.editor_div.__btEditor = ed; });
        }""")
    save_btn = DOM.button("Save";
        class = "bt-btn bt-btn-sm bt-file-editor-save",
        title = "Save to the server mirror and push to the worker (Ctrl+S)",
        onclick = js"""event => {
            const root = event.target.closest('.bt-file-editor');
            const div  = root && root.querySelector('.monaco-editor-div');
            const ed   = div && div.__btEditor;
            if (ed) $(save_content).notify(ed.getValue());
        }""")
    on(session, save_content) do content
        content === nothing && return
        try
            write(fe.server_path, content)
            pushed = push_editor_save_to_worker(fe)
            safe_set!(status, "saved $(Dates.format(now(), "HH:MM:SS"))" *
                              (pushed ? " · pushed to worker" : ""))
        catch e
            @warn "file editor save failed" path = fe.server_path exception = e
            safe_set!(status, "save failed: $(sprint(showerror, e))")
        end
    end
    header = DOM.div(
        DOM.span(fe.server_path; class = "bt-file-editor-path", title = fe.server_path),
        DOM.span(status; class = "bt-file-editor-status"),
        save_btn;
        class = "bt-file-editor-header")
    node = DOM.div(header,
        DOM.div(editor; class = "bt-file-editor-body");
        class = "bt-file-editor")
    # Ctrl+S inside the editor saves (capture phase beats Monaco's default).
    Bonito.onload(session, node, js"""(root) => {
        root.addEventListener('keydown', (e) => {
            if ((e.ctrlKey || e.metaKey) && e.key === 's') {
                e.preventDefault();
                e.stopPropagation();
                root.querySelector('.bt-file-editor-save')?.click();
            }
        }, true);
    }""")
    return Bonito.jsrender(session, node)
end

# Best-effort push of the saved file to the project's worker. Returns whether
# the push happened; failure to push is reported via the thrown error (the
# save handler surfaces it), a missing worker just means "mirror-only save".
function push_editor_save_to_worker(fe::FileEditor)
    isempty(fe.worker_path) && return false
    proj = get(fe.state.projects[], fe.project_id, nothing)
    proj === nothing && return false
    haskey(fe.state.worker_control_ws, proj.worker_id) || return false
    send_file_to_worker!(fe.state, proj.worker_id, fe.server_path, fe.worker_path;
        handoff_timeout = 15.0)
    return true
end

# A live worker app embeds against the per-tab Session via the placeholder's
# jsrender (not loaded from disk). The registered app id lives on the message
# (`app_id`, captured once on completion); empty ⇒ the app was registered under
# the message id (`show_remote_app!`). No content is read here.
render_tool_body(state::ServerState, m::BonitoAppMsg, cwd::AbstractString,
    chat_dir::AbstractString=cwd; project_id::AbstractString="") =
    wrap_for_detach(m.id, remote_app_placeholder(state, m.id, project_id,
                                                 isempty(m.app_id) ? m.id : m.app_id))

function render_tool_body(state::ServerState, m::ToolMsg, cwd::AbstractString,
    chat_dir::AbstractString=cwd;
    project_id::AbstractString="")
    content = tool_content_for_render(m, chat_dir)
    # Live tool whose content hasn't arrived yet (user expanded mid-stream
    # before any snap with content reached us). Render a quiet placeholder
    # instead of the alarming "details not persisted" message — the next
    # tool_update will trigger a fresh render with real content.
    isempty(content) &&
        return DOM.div("(loading…)"; class = "bt-tool-empty bt-tool-loading")

    # bt_show output: ANY text block starts with "shown: " (the bt_julia_eval
    # wrapper prepends a `\`\`\`julia` code-echo block before the formatter's
    # output, so we have to scan, not just look at the first block). The
    # rendered file lives on the worker; the chat fetches it lazily and
    # renders a collapsible preview without putting the bytes through claude.
    show_text = find_show_reference(content)
    if show_text !== nothing
        path = parse_show_path(show_text)
        path === nothing || return ShowTool(state, project_id, String(cwd), path)
    end

    # bt_julia_eval: `\`\`\`julia` code echo + stdout/result/error sections →
    # two collapsibles (Code / Output). Checked before the kind dispatch so
    # it works regardless of what `kind` claude-agent-acp tagged the MCP
    # tool with — the content shape is the reliable signal.
    eval_body = render_eval_body(content)
    eval_body === nothing || return eval_body

    if m.kind == "edit"
        # Render every diff (multi-edit calls used to silently drop all but
        # the first). Stack with file-path headers between each. Each
        # Monaco editor caps at `EDIT_BODY_COMPACT_PX` initially; the JS
        # Collapsable's edit-mode swaps to `EDIT_BODY_EXPANDED_PX` in
        # place by calling `setMaxHeight` on the editor's container,
        # without re-mounting. The body is also auto-expanded on the
        # first snap that carries a `DiffContent` (see `auto_expand_body`)
        # so the user sees the compact diff under the header without a
        # click.
        diffs = [c for c in content if c isa DiffContent]
        if !isempty(diffs)
            return DOM.div(
                (render_diff_block(d; max_height = EDIT_BODY_COMPACT_PX) for d in diffs)...;
                class = length(diffs) > 1 ? "bt-multi-diff bt-edit-tool-body" : "bt-edit-tool-body",
                dataEditTool = "1")
        end
    end

    if m.kind == "search"
        text = join((c.text for c in content if c isa TextContent), "\n")
        if !isempty(text)
            return render_search_results(text)
        end
    end

    if m.kind in ("execute", "read")
        text = join((c.text for c in content if c isa TextContent), "\n")
        if !isempty(text)
            lang = m.kind == "read" ? detect_language(m.title) : "shell"
            return monaco_readonly(text, lang)
        end
    end

    # Default / "think" / "other" / "fetch" / "move" / "delete" / mixed:
    # text blocks that ARE a fenced code block become Monaco; prose stays
    # markdown. Diff blocks (uncommon outside `edit`) render inline.
    parts = []
    for c in content
        if c isa TextContent
            push!(parts, render_text_block(c.text))
        elseif c isa DiffContent
            push!(parts, render_diff_block(c))
        elseif c isa ImageContent
            push!(parts, read_image_element(state, project_id, m, c))
        end
    end
    isempty(parts) && return DOM.div("(empty)", class="bt-tool-empty")
    return DOM.div(parts...)
end

# ── The message is the streaming target ─────────────────────────────────────
# Each `ChatMsg` carries a `chat` back-ref (set when it goes live). The three
# sinks — in-memory store, browser (comm), disk (chat.md) — are each expressed
# ONCE here, as common verbs:
#
#   send!(chat, m)     store + emit the "new" wire event       (render a bubble)
#   append!(m, chunk)  grow the bubble's text + emit "chunk"   (stream into it)
#   close(m)           persist to chat.md + emit the "*_final"  (finalize)
#
# These are the ONLY things that touch `msgs_store` / `comm` / chat.md, and
# they all run on the single `run_chat!` consumer task — so the lock degenerates
# to a brief Vector guard around the `msgs_store` push (the read-only comm
# handlers read it concurrently), not a mutation funnel.

# Add a fresh message to the chat: push to the store, emit its "new" event.
function send!(model::ChatModel, m::ChatMsg)
    n = lock(model.lock) do
        push!(model.msgs_store, m)
        length(model.msgs_store)
    end
    d = wire_new(model, m)
    d["n"] = n            # JS bumps totalCount from `n`; no separate broadcast
    chat_emit(model, d)
    return m
end

# Grow a streaming text bubble in place and emit the delta. `m.chat` is the
# sink captured when the bubble was created. AgentMsg clears its cached html
# so a finalize-then-rerequest never serves the pre-streaming snapshot.
# Stream a text delta into the bubble. We still ACCUMULATE `m.text` (cheap), but
# once cancel is requested we stop shipping each chunk over the wire — under a
# heavy token stream that per-chunk `chat_emit` to a (possibly slow) browser is
# the one thing that keeps the turn "busy" after the user hit stop. The seal
# (`close` → `wire_final`) still ships the final partial, so the bubble is
# correct; we just don't stream the now-discarded tail.
function Base.append!(m::AgentMsg, t::AbstractString)
    # Grow + clear-cache atomically w.r.t. a concurrent `ensure_html!` on the
    # comm task (msgs.request) — see MARKDOWN_LOCK.
    lock(MARKDOWN_LOCK) do
        m.text *= t
        m.html = ""
    end
    c = m.chat === nothing ? nothing : client(m.chat.agent)
    (c !== nothing && (@atomic c.conn.cancelling)) || chat_emit(m.chat, wire_chunk(m, t))
    return m
end
Base.append!(m::UserMsg, t::AbstractString) = (m.text *= t; chat_emit(m.chat, wire_chunk(m, t)); m)
# Summaries arrive whole on replay; live they can stream through `process_update!`
# like a UserMessage. Append clears the HTML cache so the eventual close-time
# render reflects the full text.
Base.append!(m::SummaryMsg, t::AbstractString) =
    (lock(MARKDOWN_LOCK) do; m.text *= t; m.html = ""; end; m)

# Finalize a message: persist to chat.md (per-type writer) + emit its closing
# event. UserMsg / TodoListMsg have no `*_final` event; a ToolMsg only persists once
# it reaches a terminal status. AgentMsg builds its rendered html ONCE here so
# later `msgs.request` round-trips (scroll-back, re-mount) reuse the cache.
function Base.close(m::AgentMsg)
    # Idempotent: the orphan sweep can race with `process_update!`'s own
    # close-in-finally. Without this guard a second close would re-append to
    # chat.md (not idempotent on disk) and re-emit `agent_final` to JS.
    m.in_flight || return nothing
    m.in_flight = false
    ensure_html!(m)
    finalize_agent(m.chat.chat_session, m)
    chat_emit(m.chat, wire_final(m))
    return nothing
end
function Base.close(m::ThoughtMsg)
    m.in_flight || return nothing
    m.in_flight = false
    append_thought(m.chat.chat_session, m)
    chat_emit(m.chat, wire_final(m))
    return nothing
end
Base.close(m::UserMsg) = (append_user(m.chat.chat_session, m); nothing)
# Persist only. The previous version also stamped `finished_at = time()`,
# which made every just-created TodoListMsg immediately stop being "live"
# and broke cross-turn absorption (the next TodoWrite found the prior
# bubble as not-live and spawned a fresh one — visible in the chat
# history as a parallel stack of duplicate todo bubbles, each with its
# own timer ticking). Normal lifecycle: persist initial snapshot only —
# `try_absorb_todo!` is the path that flips `finished_at` once entries
# go all-done; mid-life updates keep landing through there. This close
# runs at INITIAL emit (a fresh `TodoListMsg` that couldn't absorb into
# a prior bubble), so it must NOT touch `finished_at` — otherwise a
# brand-new plan with pending entries lands non-live and the JS taskbar
# misses it. The orphan sweep on `restart_chat_session!` uses the
# `finalize_orphan!` verb below, NOT this close.
Base.close(m::TodoListMsg) =
    (append_plan(m.chat.chat_session, m); nothing)

# `finalize_orphan!` — what the restart orphan sweep calls. For most
# kinds it IS `close` (their normal finalize): AgentMsg / ThoughtMsg
# close is already idempotent + ships the trailing wire_final; ToolMsg
# close force-fails non-terminal status + emits the terminal
# tool_update. For TodoListMsg the two are distinct verbs: `close` is
# the initial-persist step the live-emit path uses, while
# `finalize_orphan!` is the "your driving agent went away — stop being
# live so a fresh one doesn't absorb into you" path. Splitting them
# avoids the trap where the initial-emit close accidentally drops
# liveness off a plan whose entries are still pending.
finalize_orphan!(m::AgentMsg)   = close(m)
finalize_orphan!(m::ThoughtMsg) = close(m)
finalize_orphan!(m::ToolMsg)    = close(m)
function finalize_orphan!(m::TodoListMsg)
    m.finished_at === nothing || return nothing
    m.finished_at = time()
    append_plan(m.chat.chat_session, m)
    chat_emit(m.chat, plan_update_dict(m))
    return nothing
end
# Default for kinds we don't sweep (UserMsg, SummaryMsg, BashToolMsg in
# background mode, …). Explicit no-op so dispatch never falls into a
# generic `close` for something we deliberately don't want finalised.
finalize_orphan!(::ChatMsg) = nothing
# Close is TOTAL: every reachable status finalizes. If the status isn't already
# terminal (cancel mid-tool, EOF, an upstream backstop that closed `updates`
# without a final snap), treat that as failure — flip to "failed", emit one
# trailing `tool_update` so the browser freezes the timer + stops the pulse,
# then persist. The old guarded form silently no-op'd on non-terminal status,
# which left the bubble pulsing forever AND skipped the chat.md append (so a
# reload couldn't show the tool either). Callers should not need to satisfy a
# precondition on `status` — that's exactly the "wrong-by-construction" shape
# we're trying to avoid here.
function Base.close(m::ToolMsg)
    if !(m.status in ("completed", "failed"))
        m.status = "failed"
        pretty_title, _ = pretty_tool_title(m.title)
        m.finished_at === nothing && (m.finished_at = time())
        chat_emit(m.chat, Dict{String,Any}("type" => "tool_update", "id" => m.id,
            "status" => "failed", "title" => pretty_title,
            "summary" => m.summary, "finished_at" => m.finished_at))
    end
    m.finished_at === nothing && (m.finished_at = time())
    append_tool(m.chat.chat_session, m)
    nothing
end
Base.close(m::SummaryMsg) = (ensure_html!(m); append_summary(m.chat.chat_session, m); chat_emit(m.chat, wire_final(m)); nothing)

# ── Wire-dict builders (the browser protocol; byte-identical to before) ─────
# CommonMark for rendering — `Bonito.bonito_parser()` already turns on the
# extensions we want (TableRule, FootnoteRule, DollarMath, Admonition,
# Strikethrough, RawContent, AttributeRule), so we share its config instead
# of maintaining a parallel `enable!` list here. The bare stdlib `Markdown`
# / `CM.Parser()` paths were both wrong: stdlib `Markdown` italicizes
# intraword `_` (`foo_bar_baz` → `foo<em>bar</em>baz`); a bare `CM.Parser()`
# fixes that but drops tables on the floor (they came out as literal `|`).
# The parser is reused across calls; CommonMark.Parser is mutating but the
# parse + write_html cycle leaves it in the same state each time.
const MARKDOWN_PARSER = Bonito.bonito_parser()
# Serializes everything that touches MARKDOWN_PARSER and the per-message
# html caches. Two tasks render concurrently — the `run_chat!` consumer
# (append!/close → wire_chunk/wire_final) and the comm/session task
# (msgs.request → msg_to_dict → ensure_html!):
#   • MARKDOWN_PARSER is a MUTATING CommonMark parser; interleaved use from
#     two tasks can corrupt a parse.
#   • `ensure_html!`'s read-text → render → write-cache must not interleave
#     with `append!`'s text-grow + cache-clear, or a stale render computed
#     before the append lands in `m.html` AFTER the clear — `close` then
#     ships a final missing the trailing chunks.
const MARKDOWN_LOCK = ReentrantLock()
# Wrap the rendered html in `.markdown-body` so `Bonito.MarkdownCSS` (which
# is GitHub-style and already loaded into the shell) handles tables, code
# blocks, lists, etc. — we don't have to duplicate the styling.
markdown_html(text::AbstractString) = lock(MARKDOWN_LOCK) do
    inner = try
        sprint(io -> CM.html(io, MARKDOWN_PARSER(String(text))))
    catch e
        # We re-render on every streamed chunk, so the parser is routinely handed
        # half-formed markdown — it must not be able to break message rendering.
        # The one known failure is CommonMark's GFM table rule: a separator row
        # that starts with `|` and is all `|-: ` passes its permissive
        # `valid_table_spec`, but `parse_table_spec` (which needs `|dashes|`)
        # returns an empty column spec, so `inline_modifier` indexes `spec[0]` →
        # BoundsError. A streamed table trips exactly that on its way to `|---|`
        # (`|`, `|-`, `| |`, …). Catch ONLY that and show the text verbatim
        # (escaped, line breaks kept) — this preserves the content (tightening
        # `valid_table_spec` instead makes CommonMark drop the header line) and
        # the next chunk re-renders cleanly. Anything else is an unexpected bug
        # and must surface, so rethrow. @debug not @warn: it fires per streamed
        # partial, and warning would just reproduce the log flood it prevents.
        e isa BoundsError || rethrow()
        @debug "markdown_html: CommonMark BoundsError; showing text verbatim" exception = (e, catch_backtrace())
        replace(esc_html(String(text)), "\n" => "<br>")
    end
    "<div class=\"markdown-body\">" * inner * "</div>"
end

# "new message" event. Streaming-open shape for agent/thought (seeded with the
# first chunk); plain shape for user/tool/plan. `send!` adds the `n` count.
wire_new(::ChatModel, m::AgentMsg) =
    Dict{String,Any}("type" => "agent", "id" => m.id, "html" => "", "streaming" => true, "text" => m.text)
# A thought is committed whole (see `process!(::Thought)`): render it collapsed
# like a reloaded one (summary only, lazy body); `close` then ships the html.
wire_new(::ChatModel, m::ThoughtMsg) = msg_to_dict(m)
wire_new(::ChatModel, m::UserMsg) =
    Dict{String,Any}("type" => "user", "text" => m.text, "queued" => m.queued)
wire_new(model::ChatModel, m::ToolMsg) = tool_header_dict(m, model.chat_dir)
wire_new(model::ChatModel, m::TodoListMsg) = msg_to_dict(m, model.chat_dir)
# Summary opens as a centered placeholder; `close` ships the rendered html
# (targeted by id — see `onSummaryFinal` in bonitoagents.js).
wire_new(::ChatModel, m::SummaryMsg) =
    Dict{String,Any}("type" => "summary", "id" => m.id, "html" => "", "streaming" => true)

# Stream the FULL rendered html of the message-so-far rather than the text
# delta — so a live agent message reads as proper markdown (lists, headings,
# code blocks, bold, links) instead of running together as one wall of text
# whose newlines also get lost. CommonMark is cheap per parse (~µs) and
# claude-agent-acp chunks are paragraph-sized, not per-character, so the
# O(N²) cumulative cost over a single message stays well under a millisecond
# for typical lengths. `append!` already invalidated the cache; `ensure_html!`
# rebuilds it from the new accumulated text.
wire_chunk(m::AgentMsg, _t) = Dict{String,Any}(
    "type" => "chunk", "id" => m.id, "html" => ensure_html!(m))
wire_chunk(m::UserMsg, t) = Dict{String,Any}("type" => "user_chunk", "text" => t)

wire_final(m::AgentMsg) = Dict{String,Any}("type" => "agent_final", "id" => m.id, "html" => ensure_html!(m))
wire_final(m::ThoughtMsg) = Dict{String,Any}("type" => "thought_final", "id" => m.id, "html" => markdown_html(m.text))
wire_final(m::SummaryMsg) = Dict{String,Any}("type" => "summary_final", "id" => m.id, "html" => ensure_html!(m))

# ── Rendering one ACP message into a bubble ─────────────────────────────────
# `process!` is the per-message renderer used by the `run_chat!` loop: turn the
# clean ACP message into a chat bubble, `send!` it, then stream its `updates`
# into that bubble via `process_update!`. Only tools/plan override
# `process_update!`; text messages use the default (drain the text deltas).
process!(chat::ChatModel, m::AgentClientProtocol.Message) =
    process_update!(send!(chat, to_message(chat, m)), m)

# Thoughts get special handling. This agent redacts the plaintext reasoning
# (the model returns thinking blocks with an empty `thinking` field and only an
# encrypted `signature`), so a thought is almost always EMPTY. We show a
# transient "reasoning…" indicator for the lifetime of the thought and only
# commit a real (collapsed, persisted) thought bubble if non-empty text
# actually arrives — empty redacted thoughts leave no trace in the store, while
# an agent that DOES expose plaintext still renders one.
function process!(chat::ChatModel, m::AgentClientProtocol.Thought)
    chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => true, "count" => 0))
    text = m.text
    # Liveness counter for long thinks. The reasoning plaintext is redacted, so
    # we have nothing to render — but each streamed (empty) chunk still ticks the
    # channel, so the running chunk count is the only real-time proof that the
    # model is still churning. Shipped next to the "reasoning…" indicator.
    n = 0
    c = client(chat.agent)
    last_emit = 0.0
    try
        for delta in m.updates
            text *= delta
            n += 1
            # Mirror AgentMsg.append!: once stop is pressed, quit shipping per-
            # chunk wire events (the one thing that keeps the turn "busy" after a
            # cancel). The final active=false below still fires from the finally.
            # Throttled to ~6/s — the count is a liveness ticker, and a wire
            # event per redacted token chunk (broadcast to every tab) was
            # pure overhead at high token rates. A ≤150 ms-stale count is
            # invisible; the finally's active=false handles teardown.
            if !(c !== nothing && (@atomic c.conn.cancelling)) && time() - last_emit > 0.15
                last_emit = time()
                chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => true, "count" => n))
            end
        end
    finally
        # MUST fire even if the update iteration threw (session died mid-
        # thought / channel closed with InvalidStateException). Without
        # this, the JS `bt-thinking-active` class stays on forever — the
        # whole "reasoning…" indicator is stuck until another full thought
        # turn completes successfully. `run_turn!`'s finally has a second
        # defensive emit as a belt-and-suspenders backstop.
        chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => false))
    end
    isempty(strip(text)) || close(send!(chat, ThoughtMsg(chat, text)))
    return nothing
end

# Session-config changes mid-turn: pure header metadata — update the shared
# observable, no chat bubble, no persistence (config is ephemeral per
# connection; the next bring-up resets it from the session-setup result).
function process!(chat::ChatModel, m::AgentClientProtocol.ConfigUpdate)
    s = shared(chat)
    # The spec payload is the COMPLETE config state: replace the ConfigOption
    # items, preserve any other meta kinds a future parser may have added.
    rest = [x for x in s.session_meta[] if !(x isa AgentClientProtocol.ConfigOption)]
    s.session_meta[] = Any[m.options..., rest...]
    return nothing
end

function process!(chat::ChatModel, m::AgentClientProtocol.ModeUpdate)
    s = shared(chat)
    s.session_meta[] = Any[map(s.session_meta[]) do x
        x isa AgentClientProtocol.ConfigOption && x.id == "mode" ?
            AgentClientProtocol.ConfigOption(x.id, x.name, x.description,
                x.category, m.mode_id, x.choices) : x
    end...]
    return nothing
end

# Adopt the AUTHORITATIVE config state the agent returns in a session/new,
# session/load, or session/set_config_option result. The `set_config_option`
# RESPONSE carries the complete updated `configOptions` (verified on the wire,
# claude-agent-acp 0.42.0 — it is NOT an empty object, and no separate
# `config_option_update` notification arrives for model/effort), so reading it
# back is the correct source of truth — it even reflects a value the agent
# clamped or rejected. Replaces the ConfigOption items on `session_meta`,
# preserving any other meta kinds. No-op (returns false) when the result has no
# configOptions (e.g. the test mock returns `{}`), so callers fall back to the
# optimistic single-field patch.
function adopt_config_options!(model::ChatModel, result)
    opts = AgentClientProtocol.parse_config_options(result)
    isempty(opts) && return false
    s = shared(model)
    rest = [x for x in s.session_meta[] if !(x isa AgentClientProtocol.ConfigOption)]
    s.session_meta[] = Any[opts..., rest...]
    return true
end

# Optimistic single-field patch: swap `current_value` on one ConfigOption.
function patch_config_value!(s, cfg_id::AbstractString, value::AbstractString)
    s.session_meta[] = Any[map(s.session_meta[]) do x
        x isa AgentClientProtocol.ConfigOption && x.id == cfg_id ?
            AgentClientProtocol.ConfigOption(x.id, x.name, x.description,
                x.category, String(value), x.choices) : x
    end...]
    return nothing
end

# User clicked a config option (model / mode / effort) in the header pill.
# Patch `session_meta` OPTIMISTICALLY so the pill reflects the choice at once,
# then send `session/set_config_option` off-task (a slow agent mustn't freeze the
# click handler) and reconcile to the AUTHORITATIVE state in the set response;
# a failure logs and reverts to the previous value.
function apply_config_pick!(model::ChatModel, cfg_id::AbstractString,
                            value::AbstractString)
    cli = client(model.agent)
    cli === nothing && return nothing

    s = shared(model)
    prev = nothing
    for x in s.session_meta[]
        x isa AgentClientProtocol.ConfigOption && x.id == cfg_id && (prev = x.current_value)
    end
    patch_config_value!(s, cfg_id, value)

    @async try
        result = AgentClientProtocol.set_config_option!(cli, cfg_id, value)
        adopt_config_options!(model, result)   # authoritative; falls back to the patch above
    catch e
        @warn "set_config_option failed; reverting" cfg_id value exception = e
        prev === nothing && return
        patch_config_value!(s, cfg_id, prev)
    end
    return nothing
end

# ── Desired session config (permission mode / effort / model) ─────────────────
# claude reports these as ACP config options, but we can neither trust nor rely
# on them: on `session/load` (resume) claude-agent-acp reports mode/model/effort
# ALL as "default" regardless of the session's real settings, and permission mode
# + effort are per-invocation in claude (they reset to "default" on resume; the
# `CLAUDE_PERMISSION_MODE` env is a no-op — claude ignores it). So we DRIVE them:
# assert the desired config via `set_config_option` on every bring-up (fresh AND
# resume), and persist per-thread picks so a resumed thread returns exactly as the
# user left it. Verified against claude 2.1.195 / claude-agent-acp 0.42.0.
const DEFAULT_PERMISSION_MODE = "default"
const DEFAULT_EFFORT          = "xhigh"

project_of(model::ChatModel) =
    isempty(model.project_id) ? nothing :
        get(model.state.projects[], model.project_id, nothing)

# The config to assert at bring-up: global defaults overlaid with this thread's
# persisted picks. Model carries NO global default — a fresh session keeps the
# agent's own default model (which claude preserves across resume anyway); it's
# only asserted here once the user has explicitly chosen one.
function effective_session_config(model::ChatModel)
    cfg = Dict{String,String}("mode" => DEFAULT_PERMISSION_MODE,
                              "effort" => DEFAULT_EFFORT)
    p = project_of(model)
    p === nothing || merge!(cfg, p.desired_config)
    return cfg
end

# Assert the desired config on the live session SYNCHRONOUSLY (so the turn's
# first prompt runs under it) and optimistically patch `session_meta` so the
# header pills show the asserted values at once. Only options the agent actually
# advertises are set (a provider without `effort`/`mode` is skipped); a per-option
# failure logs and continues — it must not abort bring-up.
function apply_session_config!(model::ChatModel)
    cli = client(model.agent); cli === nothing && return nothing
    # Only set options the agent advertises, and skip ones already at the desired
    # value (so e.g. mode default→default fires no RPC). `current` is keyed by id.
    current = Dict(o.id => o.current_value
                   for o in AgentClientProtocol.parse_config_options(cli.session_result))
    s = shared(model)
    for (id, val) in effective_session_config(model)
        (isempty(val) || !haskey(current, id) || current[id] == val) && continue
        # Patch the display NOW (so the pill shows the desired value immediately),
        # but drive the agent OFF-TASK: `set_config_option` is a blocking RPC and
        # bring-up runs in the chat-open path — a slow/large resume (where the
        # response queues behind the history replay) would otherwise hang the chat
        # from ever opening. The async task reconciles to the authoritative set
        # response when it lands.
        patch_config_value!(s, id, val)
        @async try
            result = AgentClientProtocol.set_config_option!(cli, id, val)
            adopt_config_options!(model, result)
        catch e
            @warn "apply_session_config: set_config_option failed" id val exception = e
        end
    end
    return nothing
end

# Remember a user's header-pill pick on the thread so resume restores it.
function persist_desired_config!(model::ChatModel, cfg_id::AbstractString, value::AbstractString)
    p = project_of(model); p === nothing && return nothing
    p.desired_config[String(cfg_id)] = String(value)
    save_projects!(model.state)
    return nothing
end

to_message(chat::ChatModel, m::AgentClientProtocol.AgentMessage) = AgentMsg(chat, m.text)
# Compact-summary "user" messages get their own centered kind. ACP doesn't carry
# Claude Code's `isCompactSummary` flag, so we route on the verbatim opening.
to_message(chat::ChatModel, m::AgentClientProtocol.UserMessage) =
    is_summary_text(m.text) ? SummaryMsg(chat, m.text) : UserMsg(chat, m.text)
# Typed dispatch on the ACP variant — one method per concrete `ToolCall`.
to_message(chat::ChatModel, tc::AgentClientProtocol.GenericTool)   = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.BashCall)      = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.TaskCall)      = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.MCPCall)       = build_tool_msg(chat, tc)
to_message(chat::ChatModel, tc::AgentClientProtocol.TodoWriteCall) = TodoListMsg(chat, tc.entries)
to_message(chat::ChatModel, m::AgentClientProtocol.Plan)           = TodoListMsg(chat, m.entries)

# Concrete-typed builders for the four ToolMsg variants. Each one knows which
# tool-specific fields to lift out of its ACP source.
# `bt_show_app` (an MCP call) and any tool already tagged `bonito_app`
# (`show_remote_app!`) are live worker apps — route them to `BonitoAppMsg`,
# decided purely from the tool name / kind (no content sniffing).
is_bonito_app(tc::AgentClientProtocol.MCPCall)     = tc.tool_name == "bt_show_app"
is_bonito_app(tc::AgentClientProtocol.GenericTool) = tc.kind == "bonito_app"
is_bonito_app(::AgentClientProtocol.ToolCall)      = false

bonito_app_msg(tc, server, chat) =
    BonitoAppMsg(tc.id, "bonito_app", tc.title, tc.status,
                 content_summary("bonito_app", tc.content),
                 time(), nothing, server,
                 something(find_app_reference(tc.content), ""), chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.GenericTool) =
    is_bonito_app(tc) ? bonito_app_msg(tc, "", chat) :
    GenericToolMsg(tc.id, tc.kind, tc.name, tc.title, tc.status,
                   content_summary(tc.kind, tc.content),
                   time(), nothing, chat, Dict{String,Any}(tc.raw_input))

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.BashCall) =
    BashToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), nothing,
                tc.command, tc.description, tc.run_in_background,
                "", 0, false, "", chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.TaskCall) =
    TaskToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), nothing,
                tc.description, tc.run_in_background, tc.task_name, chat)

build_tool_msg(chat::ChatModel, tc::AgentClientProtocol.MCPCall) =
    is_bonito_app(tc) ? bonito_app_msg(tc, tc.server, chat) :
    MCPToolMsg(tc.id, tc.kind, tc.title, tc.status,
               content_summary(tc.kind, tc.content),
               time(), nothing,
               tc.server, tc.tool_name, Dict{String,Any}(tc.raw_input), chat)

# Default: stream the message's text deltas into the bubble, then finalize.
function process_update!(b::ChatMsg, m::AgentClientProtocol.Message)
    try
        for delta in m.updates
            append!(b, delta)
        end
    finally
        # The `close(b)` MUST fire even when the update iteration threw
        # (session died mid-stream). `Base.close(::AgentMsg/::ThoughtMsg)`
        # is now idempotent + emits `agent_final`/`thought_final`, so the
        # browser sees a finalized bubble instead of one stuck in
        # `bt-stream-active`. If we somehow miss this path the orphan
        # sweep catches it via `is_turn_orphan(::AgentMsg) = m.in_flight`.
        close(b)
    end
    return nothing
end

# Tools: persist the content snapshot to disk (so the lazily-loaded body stays
# current), re-render the header on each change, finalize on terminal status.
# A tool's `updates` channel yields the (mutated) ToolCall after each change.
# `b::ToolMsg` covers every concrete variant — they all carry the same five
# header fields the update path touches.
function process_update!(b::ToolMsg, m::AgentClientProtocol.ToolCall)
    pin_tool!(b.chat, b)
    try
        persist_tool_content!(b.chat.chat_dir, m)
        cache_tool_content!(b.chat, m.id, m.content)
        # The "new" wire event (send!, inside process!) fired BEFORE this
        # initial persist, so content-derived header extras — ✎ editable,
        # bt_show auto-expand, media mime — were missing for a tool that
        # arrived already-terminal (e.g. a completed Read: no later snap ever
        # comes to carry them). Re-emit just those extras when the initial
        # content warrants any.
        if !isempty(m.content)
            pt0, _ = pretty_tool_title(b.title)
            d0 = Dict{String,Any}("type" => "tool_update", "id" => b.id,
                "status" => b.status, "title" => pt0, "summary" => b.summary)
            (auto_expand_body(b, m.content) || has_show_reference(m.content)) &&
                (d0["expand"] = true)
            mime0 = tool_media_mime(m.content)
            mime0 === nothing || (d0["show_mime"] = mime0)
            hd0 = Dict{String,Any}("kind" => b.kind, "title" => pt0)
            hint0 = tool_path_hint(b)
            hint0 === nothing || (hd0["path_hint"] = hint0)
            ep0 = editable_path_from(hd0, m.content)
            if ep0 !== nothing
                d0["editable"]  = true
                d0["edit_path"] = ep0
            end
            (haskey(d0, "expand") || haskey(d0, "show_mime") || haskey(d0, "editable")) &&
                chat_emit(b.chat, d0)
        end
        for snap in m.updates
            prev_status = b.status
            b.status = snap.status
            b.title = snap.title
            b.summary = content_summary(snap.kind, snap.content)
            # Stamp `finished_at` on terminal-transition so the live timer freezes.
            prev_status in ("completed", "failed") || !(b.status in ("completed", "failed")) ||
                (b.finished_at = time())
            persist_tool_content!(b.chat.chat_dir, snap)
            cache_tool_content!(b.chat, snap.id, snap.content)
            # Per-type extraction from THIS snap (e.g. BonitoAppMsg pulls the
            # worker-registered `shown_app: <id>` out of the result content).
            update_from_snap!(b, snap)
            pretty_title, _ = pretty_tool_title(b.title)
            d = Dict{String,Any}("type" => "tool_update", "id" => b.id,
                "status" => b.status, "title" => pretty_title, "summary" => b.summary)
            b.finished_at === nothing || (d["finished_at"] = b.finished_at)
            # Auto-expand the body: live Bonito app once we've captured its
            # app_id, `bt_show` tool once content carries a `shown:` ref, or
            # an edit tool once its first DiffContent has landed (so the
            # compact Monaco preview shows up under the header without a
            # click). `auto_expand_body` dispatches on the type + content
            # presence — no content sniffing inline here.
            (auto_expand_body(b, snap.content) || has_show_reference(snap.content)) &&
                (d["expand"] = true)
            # Displayable media (bt_show mime, or inline image content from
            # e.g. Read on a PNG) — the client's Native Images mode keys on
            # this; ship it with the update that carries the result.
            mime = tool_media_mime(snap.content)
            mime === nothing || (d["show_mime"] = mime)
            # Path-link affordance — content/arguments usually land with an
            # update, not the initial header, so re-derive it per snap.
            hd = Dict{String,Any}("kind" => b.kind, "title" => pretty_title)
            hint = tool_path_hint(b)
            hint === nothing || (hd["path_hint"] = hint)
            ep = editable_path_from(hd, snap.content)
            if ep !== nothing
                d["editable"]  = true
                d["edit_path"] = ep
            end
            # Eval extras (code preview / timeout / ⊗): the arguments stream
            # in AFTER the initial header (see update_from_snap!(::MCPToolMsg)),
            # so each snap re-ships them once available — the client adds the
            # missing affordances on the fly.
            snap_header_extras!(d, b)
            chat_emit(b.chat, d)
        end
    finally
        close(b)        # total: finalizes the bubble even if the loop body threw
        unpin_task!(b.chat, b.id)
    end
    return nothing
end

# Does this tool's body auto-open on render? Three signals:
#   • BonitoAppMsg with a captured app_id — the worker route exists now, so
#     the embed can mount (without an app_id the body would try to delegate
#     with the tool_id as the app id and the worker KeyErrors).
#   • Edit tool whose snap content has a `DiffContent` — the body IS the
#     diff preview now (compact Monaco editor under the header); the user
#     should see it without an extra click. The auxiliary `snap_content`
#     parameter lets the generic loop pass the SAME snap content it's
#     about to ship, so we don't re-load from cache/disk.
#   • Everything else stays click-to-expand.
auto_expand_body(::ToolMsg, snap_content) = false
auto_expand_body(m::BonitoAppMsg, snap_content) = !isempty(m.app_id)
auto_expand_body(m::GenericToolMsg, snap_content) =
    m.kind == "edit" && any(c -> c isa DiffContent, snap_content)
# Two-arg fallback for tests / call sites that don't have the snap yet.
auto_expand_body(b::ToolMsg) = auto_expand_body(b, Any[])

# Per-snap state mutation, run inside the generic loop BEFORE the expand/emit
# decisions so freshly-captured state (e.g. BonitoAppMsg's app_id from the
# `shown_app: <id>` result block) participates in this snap's tool_update —
# the browser receives the expand event on the SAME update that carried the
# result, no second round-trip.
snap_header_extras!(::Dict, ::ToolMsg) = nothing
snap_header_extras!(d::Dict, b::MCPToolMsg) = (eval_header_extras!(d, b); nothing)

update_from_snap!(::ToolMsg, _snap) = nothing
function update_from_snap!(b::BonitoAppMsg, snap)
    isempty(b.app_id) || return
    ref = find_app_reference(snap.content)
    ref === nothing || (b.app_id = ref)
    return nothing
end
# Streamed tool input: `MCPToolMsg.raw_input` is a COPY taken at build time,
# when claude-agent-acp typically hasn't sent the arguments yet (rawInput
# arrives on a later tool_call_update; ACP merges it into the live MCPCall).
# Pull the merged arguments off each snap so the eval extras (code preview,
# timeout, ⊗) and the ✎ path hint see them.
function update_from_snap!(b::MCPToolMsg, snap)
    snap isa AgentClientProtocol.MCPCall && merge!(b.raw_input, snap.raw_input)
    return nothing
end
function update_from_snap!(b::GenericToolMsg, snap)
    snap isa AgentClientProtocol.GenericTool && merge!(b.raw_input, snap.raw_input)
    return nothing
end

# Background bash (`run_in_background`): the agent "completes" the tool_call the
# instant the command is LAUNCHED and hands back an output-file path; the shell
# keeps running. We do the normal persist + header updates but, instead of
# finalizing on "completed", capture the output path and go live (`bg_running`) —
# the background-task poller then streams the file and finalizes when the shell
# exits. Non-background bashes fall through to the generic ToolMsg handling.
function process_update!(b::BashToolMsg, m::AgentClientProtocol.ToolCall)
    pin_tool!(b.chat, b)
    try
        persist_tool_content!(b.chat.chat_dir, m)
        for snap in m.updates
            b.status  = snap.status
            b.title   = snap.title
            b.summary = content_summary(snap.kind, snap.content)
            # Streamed tool input: command/description/run_in_background are
            # usually EMPTY on the initial tool_call and arrive on a later
            # update (ACP merges them into the live BashCall) — refresh.
            if snap isa AgentClientProtocol.BashCall
                isempty(snap.command) || (b.command = snap.command)
                snap.description === nothing || (b.description = snap.description)
                snap.run_in_background && (b.is_background = true)
                # The pin's label is the human description — refresh once it
                # streams in.
                refresh_pin!(b.chat, b)
            end
            persist_tool_content!(b.chat.chat_dir, snap)
            # Detect a background launch from the RESULT ("…running in background…
            # Output is being written to: <path>"), NOT from rawInput's
            # `run_in_background` — some agent builds don't forward it, so
            # `is_background` reads false even for a real background bash. The result
            # text is the reliable signal; flip `is_background` on so the taskbar +
            # `is_live` treat it as the live task it is.
            if isempty(b.bg_output_path)
                path = parse_bg_output_path(snap.content)
                if path !== nothing
                    @debug "background task detected from result" id = b.id path = basename(path)
                    b.is_background  = true
                    b.bg_output_path = path
                    b.bg_offset      = 0
                    b.bg_running     = true       # the poller now owns its lifecycle
                end
            end
            # Foreground bash (or a failed launch): stamp finished_at on terminal.
            # A live background task is left unstamped — the poller finalizes it.
            if !b.bg_running && b.status in ("completed", "failed")
                b.finished_at === nothing && (b.finished_at = time())
            end
            # Claude's human-readable description beats the raw script as
            # the visible title ("Monitor system load" vs a 5-line loop).
            # The command itself stays available in the body + tooltip.
            pretty_title, _ = pretty_tool_title(bash_display_title(b))
            d = Dict{String,Any}("type" => "tool_update", "id" => b.id,
                "status" => b.bg_running ? "in_progress" : b.status,
                "title" => pretty_title, "summary" => b.summary)
            # Description took over the title → the raw command rides as a
            # header tooltip.
            b.description === nothing || isempty(b.command) ||
                (d["command"] = b.command)
            if b.bg_running || b.is_background
                d["background"] = true
                # `wire_new` shipped `taskbar=false` (is_background was still
                # false — the streamed rawInput hadn't arrived); now that we
                # know it IS a background task, flip the taskbar slot on.
                d["taskbar"] = true
            end
            if !b.bg_running && b.finished_at !== nothing
                d["finished_at"] = b.finished_at
            end
            chat_emit(b.chat, d)
        end
    finally
        # A live background task is finalized later (by `finalize_bg_task!` when the
        # shell exits); only persist-to-chat.md here if it already terminated. The
        # guard belongs inside `finally` so a thrown loop body doesn't accidentally
        # close (= mark "failed") a still-running background shell. Same for
        # the pin: a live bg shell keeps its taskbar slot until the poller
        # finalizes it.
        if !b.bg_running
            close(b)
            unpin_task!(b.chat, b.id)
        end
    end
    return nothing
end

# Pull the output-file path from a background-launch result, e.g.
# "… Output is being written to: /tmp/…/<id>.output".
function parse_bg_output_path(content)
    for c in content
        txt = try
            hasproperty(c, :text) ? String(getproperty(c, :text)) :
                (c isa AbstractDict ? String(get(c, "text", "")) : "")
        catch e
            # A `.text` field that isn't string-convertible (unexpected content
            # shape) — treat as "no text" but don't swallow other errors (T20).
            e isa Union{MethodError, ArgumentError, InexactError} || rethrow()
            ""
        end
        mm = match(r"written to:\s*(\S+)", txt)
        # The sentence ends "…/<id>.output. You will be notified" — `\S+`
        # greedily eats the trailing period, yielding a path that doesn't
        # exist. Strip trailing sentence punctuation. (Bug: the dotted path
        # made every tail report exists=false, so the pill never finalized.)
        mm === nothing || return String(rstrip(mm.captures[1], ['.', ',', ')']))
    end
    return nothing
end

# ── Background-task output poller ───────────────────────────────────────────
# ONE server-wide loop streams every live background bash. The agent backgrounds
# the shell and only returns a file path (it does NOT stream), so we tail that
# file ourselves. Per task we back off 0.5s → 1 → 2 → 4 → 5s (responsive while
# fresh, cheap once settled). "Done" is the output file's fd closing — the shell
# exited (see the worker's `file_held_open`); a non-Linux worker falls back to
# output quiescence.
# Non-Linux fallback: if the worker can't report `open_known` on the
# output file's fd, we infer "the shell exited" from "no growth in 20 s".
const BG_QUIESCE_SECS = 20.0

# Per-chat background-output poller. Spawned on `start_chat_client!`,
# torn down when the chat closes. The task IS the taskbar's bookkeeping
# loop from the server's side: every second it walks THIS chat's live
# bg items (the same set the JS `_refreshTaskbar` paints) and tails
# their output. No global loop walking every model's msgs_store; no
# global cadence constant — the 1 s sleep is inline, the task's
# lifetime is the chat's, and a closed chat takes its poller with it.
#
# The poller lives on `shared(model).poller_task` (a field), so its lifetime is
# the chat's — no global registry pinning every chat alive and no per-teardown
# hand-draining. Idempotent: a still-running poller is left alone; a finished one
# (the chat closed and `background_poll_loop`'s `while isopen(user_messages)`
# guard exited) is replaced. The check-and-set runs under the model lock so two
# concurrent `start_chat_client!`s can't spawn two pollers.
function start_background_poller!(state::ServerState, model::ChatModel)
    s = shared(model)
    lock(s.lock) do
        existing = s.poller_task[]
        existing === nothing || istaskdone(existing) || return  # already live
        s.poller_task[] = Base.errormonitor(@async background_poll_loop(state, s))
        return nothing
    end
    return nothing
end

bg_worker_id(state::ServerState, model::ChatModel) =
    let pid = model.project_id
        (isempty(pid) || !haskey(state.projects[], pid)) ? nothing :
            state.projects[][pid].worker_id
    end

function write_bg_content!(chat_dir::AbstractString, m::BashToolMsg)
    body = isempty(strip(m.command)) ? m.bg_text : "\$ $(m.command)\n\n$(m.bg_text)"
    open(tool_file(chat_dir, m.id), "w") do io
        JSON.print(io, Dict("content" => [Dict("type" => "text", "text" => body)]))
    end
    return nothing
end

bg_line_count(m::BashToolMsg) = count(==('\n'), m.bg_text)

function stream_bg_update!(model::ChatModel, m::BashToolMsg)
    write_bg_content!(model.chat_dir, m)
    n = bg_line_count(m)
    m.summary = "running… $n line$(n == 1 ? "" : "s")"
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => m.id,
        "status" => "in_progress", "summary" => m.summary,
        "background" => true, "taskbar" => true))
    return nothing
end

function finalize_bg_task!(model::ChatModel, m::BashToolMsg)
    m.bg_running = false
    m.status = "completed"
    m.finished_at === nothing && (m.finished_at = time())
    write_bg_content!(model.chat_dir, m)
    try
        append_tool(model.chat_session, m)
    catch e
        @warn "append_tool for finished bg task failed" id = m.id exception = e
    end
    n = bg_line_count(m)
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => m.id,
        "status" => "completed", "summary" => "done · $n line$(n == 1 ? "" : "s")",
        "finished_at" => m.finished_at))
    unpin_task!(model, m.id)
    return nothing
end

# Tail one task's output; stream new bytes to the bubble. Returns the worker's
# tail result (or `nothing` on a transient error → retry next tick).
function poll_background_task!(state::ServerState, model::ChatModel, m::BashToolMsg)
    wid = bg_worker_id(state, model)
    wid === nothing && return nothing
    r = try
        tail_worker_file(state, wid, m.bg_output_path; offset = m.bg_offset, timeout = 10.0)
    catch e
        @debug "tail_file failed (will retry)" id = m.id exception = e
        return nothing
    end
    if r.exists && !isempty(r.chunk)
        m.bg_text  *= r.chunk
        m.bg_offset = r.offset
        stream_bg_update!(model, m)
    end
    return r
end

function background_poll_loop(state::ServerState, model::ChatModel)
    # Per-tool state lives in the loop's closure: `last_grew` tracks the
    # last time each id's output file grew (only consulted for the non-
    # Linux quiesce fallback). When a tool finalizes we drop its entry.
    last_grew = Dict{String,Float64}()
    # The loop's lifetime is the chat's: `close(::ChatModel)` closes
    # `user_messages`, which both ends the `run_chat!` consumer and signals this
    # poller to exit (T4). Before this guard the loop was `while true` with a
    # catch-all, so a closed chat left an immortal 1 Hz poller holding a strong
    # ref to the ChatModel forever.
    while isopen(model.user_messages)
        try
            # Snapshot msgs_store ONCE per tick under `model.lock` — the single
            # `run_chat!` consumer `push!`es to this Vector on another task, and a
            # regrow mid-iteration is a data race (T8). We iterate the snapshot.
            snapshot = lock(model.lock) do; copy(model.msgs_store); end
            for m in snapshot
                (m isa BashToolMsg && m.is_background && m.bg_running &&
                    !isempty(m.bg_output_path)) || continue
                before = m.bg_offset
                r = poll_background_task!(state, model, m)
                if m.bg_offset > before
                    last_grew[m.id] = time()
                end
                lg = get(last_grew, m.id, time())
                # Done when, per the worker's fd scan (open_known on Linux):
                # the file exists but no longer has a writer (shell exited),
                # OR the file is GONE entirely (exists=false) — a vanished
                # output file means the task is over, NOT "still running".
                # (The latter previously read as not-done, which — combined
                # with the trailing-dot path bug — pinned pills forever.)
                # Non-Linux: fall back to mtime quiescence.
                done = r !== nothing &&
                    (r.open_known ? (!r.exists || !r.open) :
                                    (time() - lg > BG_QUIESCE_SECS))
                if done
                    finalize_bg_task!(model, m)
                    delete!(last_grew, m.id)
                end
            end
            # GC `last_grew` for ids that are no longer live (finalized
            # on a previous tick or an orphan sweep cleared them).
            for id in collect(keys(last_grew))
                any(x -> x isa BashToolMsg && x.id == id && x.bg_running,
                    snapshot) || delete!(last_grew, id)
            end
        catch e
            @warn "background task poll loop tick failed" exception = e
        end
        sleep(1.0)
    end
end

# Todos are one-shot snapshots — nothing to stream, just finalize (persist).
process_update!(b::TodoListMsg, ::AgentClientProtocol.Plan) = (close(b); nothing)
process_update!(b::TodoListMsg, ::AgentClientProtocol.TodoWriteCall) = (close(b); nothing)

# ── TodoList lifecycle ───────────────────────────────────────────────────────
# A LIVE todo list is NOT a chat message: it lives on `shared(chat).live_todo`
# and renders ONLY in the taskbar (a pinned panel — full item list, finished
# entries crossed out). Each update mutates that one list. Only when it
# finishes (all entries done) or zombies (turn ends/cancelled with items
# still open) does it become a chat-history bubble (`finalize_todo!` →
# `send!`), persisted to chat.md exactly once.
#
# SINGLE CHANNEL: real claude-agent-acp reports todos exclusively as `plan`
# SessionUpdates (verified on a live session's acp.jsonl — 26 plan updates,
# 0 TodoWrite tool_calls). The TodoWrite tool_call path is therefore inert:
# its entries also suffer the streamed-rawInput emptiness at announcement.
# We just drain its update channel so the consumer can move on.
function process!(::ChatModel, m::AgentClientProtocol.TodoWriteCall)
    for _ in m.updates; end
    return nothing
end

process!(chat::ChatModel, m::AgentClientProtocol.Plan) =
    process_todo!(chat, m.entries)

todo_taskbar_item(t::TodoListMsg) =
    TaskbarItem(t.id, :todo, "📋", "Todos"; started = t.started_at,
                entries = Tuple{String,String}[(e.content, e.status)
                                                for e in t.entries])

function process_todo!(chat::ChatModel, entries)
    s = shared(chat)
    t = s.live_todo[]
    if t isa TodoListMsg && is_live(t)
        t.entries = collect(PlanEntry, entries)
    else
        # Claude habitually RE-SENDS the final all-done list ("todos
        # cleared"). Starting a fresh list from that would immediately
        # finalize a duplicate history bubble — drop it when it matches
        # the most recent finalized list.
        new = collect(PlanEntry, entries)
        if !any(e -> e.status in ("pending", "in_progress"), new)
            last_todo = lock(s.lock) do
                idx = findlast(m -> m isa TodoListMsg, s.msgs_store)
                idx === nothing ? nothing : s.msgs_store[idx]
            end
            if last_todo !== nothing &&
               [(e.content, e.status) for e in last_todo.entries] ==
               [(e.content, e.status) for e in new]
                return nothing
            end
        end
        t = TodoListMsg(chat, new)
        s.live_todo[] = t
    end
    if is_live(t)
        pin_task!(chat, todo_taskbar_item(t))   # the taskbar IS the live view
    else
        finalize_todo!(chat, t)                 # all done → history bubble
    end
    return nothing
end

# Retire the live list: drop the pin and append the final state to the chat
# history + chat.md. Statuses are kept as-is — a zombied list shows exactly
# how far it got.
function finalize_todo!(chat::ChatModel, t::TodoListMsg)
    s = shared(chat)
    s.live_todo[] === t && (s.live_todo[] = nothing)
    t.finished_at === nothing && (t.finished_at = time())
    unpin_task!(chat, t.id)
    send!(chat, t)
    t.chat === nothing || append_plan(t.chat.chat_session, t)
    return nothing
end

plan_update_dict(m::TodoListMsg) = merge(msg_to_dict(m),
    Dict{String,Any}("type" => "plan_update"))

# ── The chat consumer loop ──────────────────────────────────────────────────
# ONE task per ChatModel drains `user_messages` and drives one prompt turn at a
# time. ALL chat-state mutation (`send!`/`append!`/`close`) happens on THIS
# task, so there is no funnel lock and the "user-submit lands mid agent-chunk"
# race cannot occur. Started in `start_chat_client!`; ends when `user_messages`
# is closed (chat teardown).
# Each turn runs in its OWN task — the consumer does NOT wait for one turn
# to resolve before sending the next prompt. Two reasons (both validated
# against the real agent on the raw wire):
#
#   1. STEERING. claude-agent-acp officially supports a `session/prompt`
#      while one is running (`promptQueueing: true` in its initialize
#      capabilities): the new user message is injected into the live turn,
#      and when the SDK replays it, the FIRST prompt resolves end_turn and
#      the stream hands off to the second. Serializing client-side would
#      forfeit that and turn every mid-turn message into a dead wait.
#   2. BACKGROUND SHELLS. While a background shell lives, the SDK never goes
#      idle, so the prompt that launched it NEVER resolves on its own —
#      the held-open turn is how the SDK delivers the shell's completion
#      notification later. The next prompt (handoff) is the only thing that
#      releases it. With a serializing consumer the user is locked out of
#      the chat for as long as the shell runs — the bug this fixes.
#
# Update ordering stays strict: the ACP dispatcher routes every
# session/update to the OLDEST unresolved prompt (the handoff contract), so
# concurrent run_turn! tasks never interleave message content.
function run_chat!(chat::ChatModel)
    for user_msg in chat.user_messages
        # The prompt REGISTRATION + wire send happen HERE, in the consumer,
        # so prompts hit the wire in user order (an all-async spawn could
        # schedule turn 2's registration before turn 1's). Only the drain
        # of the turn's update stream runs in its own task.
        turn = try
            begin_turn!(chat, user_msg)
        catch e
            @error "starting chat turn failed" exception = (e, catch_backtrace())
            nothing
        end
        turn === nothing && continue
        Base.errormonitor(@async try
            drain_turn!(chat, turn)
        catch e
            @error "chat turn failed" exception = (e, catch_backtrace())
        end)
    end
    return nothing
end

# Tear a ChatModel's long-lived tasks down (T4). Closing `user_messages` ends
# the `run_chat!` consumer (its `for … in chat.user_messages` loop exits on a
# closed channel) AND signals `background_poll_loop` to exit (its
# `while isopen(model.user_messages)` guard) — so the 1 Hz poller stops and its
# `model.poller_task` finishes, releasing the running task's ref to the model.
# We resolve to the shared parent so a per-session view never half-closes the
# real model.
#
# Idempotent: closing an already-closed channel is a no-op (we guard `isopen`),
# and `stop_session!` may run more than once for the same project.
function Base.close(model::ChatModel)
    s = shared(model)
    isopen(s.user_messages) && close(s.user_messages)
    return nothing
end

# One user turn: drive the prompt and render each whole message of the agent's
# reply. The user bubble is ALREADY rendered + persisted — `send_message!` did
# that synchronously when the user hit send, so the message appears in the
# chat instantly (even when a prior turn is still running, where it shows up
# as a "queued" bubble). Here we just promote any queued bubble that's about
# to be processed, then prompt. `busy_active` is the single source of truth
# for the spinner (set here, cleared in `finally`).
# Synchronous turn start, run IN the consumer so prompts hit the wire in
# user order: promote the queued bubble, claim a turn slot, and SEND the
# prompt (`prompt!` registers + writes the frame synchronously; only the
# stream coalescer inside it is a task). Returns the turn's message channel
# for `drain_turn!`, or `nothing` when there's no client.
function begin_turn!(chat::ChatModel, user_msg::UserMessage)
    promote_queued_user_bubble!(chat)
    s = shared(chat)
    # A turn can still be drained from the channel AFTER the chat is closed:
    # `close(::ChatModel)` shuts `user_messages`, but the consumer keeps draining
    # whatever was already buffered (a `for … in channel` finishes the buffer
    # before exiting). Lazily binding here would spawn an agent + an LRU entry
    # for a session that's already gone — an orphaned MockACP subprocess (the
    # leak_cycle CI flake) and a stale `bound_lru` entry that never clears. The
    # bind_lock can't catch this: the turn fires entirely AFTER stop_session!.
    isopen(s.user_messages) || return nothing
    cli = client(chat.agent)
    if cli === nothing
        try
            start_chat_client!(chat)   # LAZY ACP: bind the agent on the first turn
        catch e
            @error "lazy ACP bind failed" project_id = chat.project_id exception = (e, catch_backtrace())
        end
        cli = client(chat.agent)
    end
    cli === nothing && return nothing
    lock(() -> s.turns_active[] += 1, s.lock)
    s.last_stream_at[] = time()
    s.busy_active[] || (s.busy_active[] = true)
    # Ship the turn's sequence number — a stop-click echoes it back so the
    # cancel can be scoped to THIS turn (see CancelCommand).
    seq = (s.turn_seq[] += 1)
    chat_emit(chat, Dict{String,Any}("type" => "turn_begin", "seq" => seq))
    try
        return AgentClientProtocol.prompt!(cli, with_prelude(chat, user_msg.text);
            images=user_msg.images)
    catch e
        # Failed to even send: release the slot we claimed; surface the error
        # like a failed turn would.
        lock(() -> s.turns_active[] -= 1, s.lock)
        update_busy!(chat)
        rethrow()
    end
end

# Test seam: the old single-call entry, used by unit tests that drive one
# turn synchronously.
function run_turn!(chat::ChatModel, user_msg::UserMessage)
    turn = begin_turn!(chat, user_msg)
    turn === nothing && return nothing
    return drain_turn!(chat, turn)
end

function drain_turn!(chat::ChatModel, turn)
    s = shared(chat)
    # Busy watchdog: with a live background shell the SDK holds this prompt
    # open even after the agent goes idle (no idle event, no response —
    # validated on the real wire), so the spinner must follow STREAM
    # ACTIVITY, not prompt resolution. The watchdog flips busy off once the
    # wire quiesces with only background work running; any later activity on
    # this turn (e.g. the agent reacting to the shell finishing) flips it
    # back on (every inbound frame bumps `last_stream_at` via the wire tap).
    turn_done = Ref(false)
    # Track whether the turn produced ANY visible message, so a turn that ends
    # with nothing (e.g. a freshly-switched provider that isn't authenticated
    # and returns an empty `end_turn`) doesn't leave the user staring at
    # silence — we surface a hint below instead.
    nstore0 = lock(() -> length(s.msgs_store), s.lock)
    errored = false
    Base.errormonitor(@async while !turn_done[]
        update_busy!(chat)
        sleep(2)
    end)
    try
        for m in turn
            s.last_stream_at[] = time()
            # Re-arm after a quiesce (set-if-changed: every assignment fires
            # the Observable, and the JS bridge doesn't need a busy event
            # per message).
            s.busy_active[] || (s.busy_active[] = true)
            process!(chat, m)
            s.last_stream_at[] = time()
        end
    catch e
        errored = true
        # `prompt!` runs the turn's producer in a bound task, so a dead session
        # surfaces as a TaskFailedException wrapping the real cause — unwrap it
        # before classifying.
        e = e isa TaskFailedException ? e.task.result : e
        if is_session_dead_error(e)
            chat.session_alive[] = false
            chat.last_error[] = sprint(showerror, e)
        else
            close(send!(chat, AgentMsg(chat, "[error: $(sprint(showerror, e))]")))
        end
    finally
        turn_done[] = true
        # End-of-turn cleanup belongs to the LAST active turn only. On a
        # handoff (this turn resolved because a newer prompt took over the
        # stream) the conversation is still going: sweeping orphans here
        # would force-fail the successor's live tools, and finalizing the
        # todo list would zombie a list the successor is still working.
        last_turn = lock(() -> (s.turns_active[] -= 1) == 0, s.lock)
        if last_turn
            chat.busy_active[] = false
            # The turn added messages (agent reply, tools, …) → refresh the
            # lens autocomplete vocabulary so new tool/type keys are
            # suggestable. (Emitted on mount too, but that's before any
            # messages exist.)
            emit_lens_vocab(chat)
            # Defensive thinking=off. `process!(::Thought)` already emits this
            # in its own finally, but in the multi-thought turn case the LAST
            # thought may not be reached if an exception unwinds through
            # `prompt!`'s consumer; this one-line backstop guarantees the JS
            # indicator is cleared regardless. Idempotent in the JS handler.
            chat_emit(chat, Dict{String,Any}("type" => "thinking", "active" => false))
            # Defense in depth: anything still in non-terminal status at end-of-turn is
            # an orphan — the `process_update!` per-tool drain SHOULD have finalized it
            # via `close(b)` once the ACP `close(::TurnState)` backstop force-failed
            # any tool the agent never resolved (see messages.jl). This sweep catches
            # the case where `process!` itself threw before reaching that close. Keyed
            # on `is_turn_orphan` — `ToolMsg` keys on status, `AgentMsg`/`ThoughtMsg`
            # on `in_flight`, so background bashes (status already "completed" at
            # launch) and live worker apps are correctly left alone, but a half-
            # streamed agent reply / thought lands properly finalized in JS.
            sweep_turn_orphans!(chat)
            # A cancelled turn can abandon a pending permission/question card —
            # the agent's request died with the turn, but the blocked handler
            # would otherwise wait out its full timeout and the card would
            # linger on screen. Resolve this chat's pending asks now (the reply
            # lands on a dead request id, which the agent ignores).
            sweep_pending_asks!(chat)
            # A live todo list dies with the conversation's last turn:
            # finalize it (zombied — the statuses show how far it got) into
            # the chat history; the taskbar slot drops.
            let t = s.live_todo[]
                t isa TodoListMsg && finalize_todo!(chat, t)
            end
            # Empty turn: the agent resolved without emitting any message (no
            # text, tool, or thought) and it wasn't an error or a user cancel.
            # The common cause is a just-switched provider that isn't
            # authenticated (its prompts return an empty `end_turn`). Surface a
            # hint rather than leave the user staring at silence.
            cli = client(chat.agent)
            cancelled = cli !== nothing && (@atomic cli.conn.cancelling)
            if !errored && !cancelled &&
               lock(() -> length(s.msgs_store), s.lock) == nstore0
                close(send!(chat, AgentMsg(chat,
                    "_The agent ended the turn without a reply. The selected " *
                    "model may be unavailable on your plan, or the provider may " *
                    "need authentication — try picking a different model, or " *
                    "check the provider's login/credentials._")))
            end
        end
    end
    return nothing
end

# Busy = "the agent is actually doing something we can see". With a live
# background shell the SDK never resolves the prompt (it keeps the turn open
# to deliver the shell's completion later), so an open turn alone must not
# pin the spinner. Flip busy OFF only when ALL of:
#   • the wire has been quiet for BG_IDLE_QUIESCE seconds (real agent work
#     streams chunks/usage heartbeats; tool execution is covered next),
#   • no live FOREGROUND tool (a long fg bash streams nothing while it runs),
#   • at least one background shell is running (without one, a quiet open
#     turn is either about to resolve or genuinely wedged — keep the honest
#     spinner rather than mask it).
const BG_IDLE_QUIESCE = 8.0

function update_busy!(chat::ChatModel)
    s = shared(chat)
    active, snapshot = lock(s.lock) do
        s.turns_active[], copy(s.msgs_store)
    end
    busy = active > 0
    if busy && time() - s.last_stream_at[] > BG_IDLE_QUIESCE
        bg_running = any(m -> m isa BashToolMsg && m.bg_running, snapshot)
        # Anything live that isn't a running background shell is foreground
        # work — including a long bt_show_app render or an eval between
        # checkpoints (their pills are status-live exactly while the call is
        # in flight). Quiet wire + foreground work ⇒ still busy.
        fg_live = any(snapshot) do m
            m isa ToolMsg && is_live(m) && !(m isa BashToolMsg && m.bg_running)
        end
        bg_running && !fg_live && (busy = false)
    end
    s.busy_active[] == busy || (s.busy_active[] = busy)
    return nothing
end

# Resolve every pending permission ("") / question (:skip) for `chat` by sending
# each one its registered teardown default. The asks live on the shared model
# (`pending_asks`), so this is just "drain my own dict" — no global scan, no
# cross-chat identity filter. The blocked handlers then run their own cleanup
# (the *_done teardown broadcast); the dict entry is already gone.
function sweep_pending_asks!(chat::ChatModel)
    s = shared(chat)
    asks = lock(s.lock) do
        v = collect(values(s.pending_asks)); empty!(s.pending_asks); v
    end
    for (ch, default) in asks
        try
            put!(ch, default)
        catch e
            e isa InvalidStateException || rethrow()
        end
    end
    return nothing
end

function sweep_turn_orphans!(chat::ChatModel)
    orphans = lock(chat.lock) do
        ChatMsg[m for m in chat.msgs_store if is_turn_orphan(m)]
    end
    for m in orphans
        try
            # Dispatch to the kind-specific orphan verb (close for agent/
            # thought/tool, the dedicated final stamp for TodoListMsg).
            # Going through `close` directly would force a live plan into
            # its initial-persist path AGAIN instead of finalising it.
            finalize_orphan!(m)
        catch e
            @warn "turn-orphan sweep finalize failed" id = getfield(m, :id) exception = e
        end
    end
    return nothing
end

# Classify a turn exception. "Session dead" ⇒ the transport is torn down and the
# only path forward is a reconnect (banner shown, user clicks Restart).
# "Transient" ⇒ one bad turn, the session is still live (inline error bubble).
# We dispatch on the exception TYPE, never `showerror` text. ACP raises a typed
# `ConnectionClosed` for transport teardown; subprocess EOF / TCP errors surface
# as `EOFError` / `Base.IOError`; the WS transport as `WebSocketError`.
is_session_dead_error(::AgentClientProtocol.ConnectionClosed) = true
is_session_dead_error(::EOFError) = true
is_session_dead_error(::Base.IOError) = true
is_session_dead_error(::HTTP.WebSockets.WebSocketError) = true
is_session_dead_error(::Exception) = false

# ── Permission / question requests (AskUserQuestion, plan approval, …) ──────
# claude surfaces user-decision points as `session/request_permission` RPCs
# carrying a list of options. The stock `FSRequestHandler` auto-allows them
# (bypassPermissions makes them rare); the chat wraps it so a request with
# real choices renders as an interactive card with buttons — the user's
# click answers the RPC. Each pending request is one entry here, keyed by a
# fresh uuid that round-trips through the wire events.
# Each entry lives on the asking chat's `pending_asks` (key → (reply channel,
# teardown default)), so a cancelled turn's `sweep_pending_asks!` drains only
# that chat's requests and the model is never pinned by a global.
# Generous: a question the user never answers should not wedge the agent
# forever — after this we fall back to the old auto-allow default.
const PERMISSION_TIMEOUT = 600.0

struct ChatPermissionHandler <: AgentClientProtocol.Handler
    fs::AgentClientProtocol.FSRequestHandler
    chat::ChatModel                      # the SHARED parent model
end

function AgentClientProtocol.on_request(h::ChatPermissionHandler,
                                        method::AbstractString, params)
    method == "session/request_permission" &&
        return handle_permission_request(h.chat, params)
    # AskUserQuestion (and MCP elicitations) arrive as form elicitations —
    # enabled by the `elicitation.form` capability the transports advertise.
    method == "elicitation/create" &&
        return handle_elicitation_request(h.chat, params)
    return AgentClientProtocol.on_request(h.fs, method, params)
end

# Pull a human question out of the request. AskUserQuestion carries its
# question(s) in the tool call's rawInput; other permission requests only
# have the tool title ("Bash", "Edit file …"). Best-effort, never throws.
function permission_question_text(tc::AbstractDict)
    raw = get(tc, "rawInput", nothing)
    if raw isa AbstractDict
        qs = get(raw, "questions", nothing)
        if qs isa AbstractVector && !isempty(qs) && qs[1] isa AbstractDict
            q = String(get(qs[1], "question", ""))
            isempty(q) || return q
        end
        q = get(raw, "question", nothing)
        q isa AbstractString && !isempty(q) && return String(q)
    end
    t = String(get(tc, "title", ""))
    return isempty(t) ? "The agent is asking for permission" : t
end

# Runs on its own task (the connection spawns one per agent→client request),
# so blocking here until the user clicks is safe — claude itself is blocked
# on this RPC anyway.
function handle_permission_request(chat::ChatModel, params)
    options = get(params, "options", Any[])
    opts = Any[Dict{String,Any}(
                   "optionId" => String(get(o, "optionId", "")),
                   "name"     => String(get(o, "name", get(o, "optionId", "?"))),
                   "kind"     => String(get(o, "kind", "")))
               for o in options if o isa AbstractDict]
    isempty(opts) && return Dict("outcome" => Dict("outcome" => "cancelled"))
    tc = get(params, "toolCall", Dict{String,Any}())
    tc isa AbstractDict || (tc = Dict{String,Any}())
    key = string(uuid4())
    ch  = Channel{String}(1)
    let s = shared(chat); lock(s.lock) do; s.pending_asks[key] = (ch, ""); end; end
    chat_emit(chat, Dict{String,Any}(
        "type"     => "permission",
        "key"      => key,
        "question" => permission_question_text(tc),
        "options"  => opts))
    picked = try
        Base.timedwait(() -> isready(ch), PERMISSION_TIMEOUT) === :ok ? take!(ch) : ""
    finally
        let s = shared(chat); lock(s.lock) do; delete!(s.pending_asks, key); end; end
        # Tell every tab to drop the card (the one that answered already
        # swapped it to its chosen state locally).
        chat_emit(chat, Dict{String,Any}("type" => "permission_done", "key" => key))
    end
    if isempty(picked)
        # Timeout: fall back to the pre-card behavior (auto-allow when an
        # allow option exists) so an unattended chat doesn't wedge forever.
        idx = findfirst(o -> o["kind"] in ("allow_once", "allow_always"), opts)
        idx === nothing && return Dict("outcome" => Dict("outcome" => "cancelled"))
        picked = opts[idx]["optionId"]
    end
    return Dict("outcome" => Dict("outcome" => "selected", "optionId" => String(picked)))
end

# ── Form elicitations (AskUserQuestion, MCP elicitations) ───────────────────
# claude-agent-acp renders the built-in AskUserQuestion tool as an ACP
# `elicitation/create` request: `requestedSchema` is a flat JSON-Schema
# object whose `question_<n>` fields carry a titled `oneOf` (single-select)
# or array-of-`anyOf` (multi-select) enum over the option labels, plus an
# optional free-text `customAnswer` field. We render that as an interactive
# question card; the user's picks come back as `{action: "accept", content:
# {question_0: label, …, customAnswer?: text}}`. Decline = "the user
# skipped" (the agent continues and decides itself) — the same fallback the
# server applies when nobody answers within the timeout.

elicitation_options(raw) = Any[Dict{String,Any}(
        "value" => String(get(o, "const", get(o, "title", ""))),
        "label" => String(get(o, "title", get(o, "const", ""))))
    for o in raw if o isa AbstractDict]

# Flatten the requestedSchema into renderable field descriptors, ordered
# `question_0 … question_N` first, free-text fields last.
function parse_elicitation_fields(schema)
    props = get(schema, "properties", nothing)
    props isa AbstractDict || return Any[]
    fields = Any[]
    for (k, v) in props
        v isa AbstractDict || continue
        f = Dict{String,Any}(
            "key"         => String(k),
            "title"       => String(get(v, "title", "")),
            "description" => String(get(v, "description", "")))
        one_of = get(v, "oneOf", nothing)
        items  = get(v, "items", nothing)
        any_of = items isa AbstractDict ? get(items, "anyOf", nothing) : nothing
        if one_of isa AbstractVector
            f["kind"] = "select"
            f["options"] = elicitation_options(one_of)
        elseif any_of isa AbstractVector
            f["kind"] = "multiselect"
            f["options"] = elicitation_options(any_of)
        else
            f["kind"] = "text"
        end
        push!(fields, f)
    end
    rank(f) = let m = match(r"^question_(\d+)$", f["key"])
        m === nothing ? (1, 0, String(f["key"])) : (0, parse(Int, m.captures[1]), "")
    end
    sort!(fields; by = rank)
    return fields
end

function handle_elicitation_request(chat::ChatModel, params)
    # URL-mode elicitations can't be rendered in the chat — cancel cleanly.
    String(get(params, "mode", "form")) == "form" ||
        return Dict("action" => "cancel")
    fields = parse_elicitation_fields(get(params, "requestedSchema", Dict{String,Any}()))
    isempty(fields) && return Dict("action" => "decline")
    key = string(uuid4())
    ch  = Channel{Any}(1)
    let s = shared(chat); lock(s.lock) do; s.pending_asks[key] = (ch, :skip); end; end
    chat_emit(chat, Dict{String,Any}(
        "type"    => "question",
        "key"     => key,
        "message" => String(get(params, "message", "The agent has a question")),
        "fields"  => fields))
    answer = try
        Base.timedwait(() -> isready(ch), PERMISSION_TIMEOUT) === :ok ? take!(ch) : :skip
    finally
        let s = shared(chat); lock(s.lock) do; delete!(s.pending_asks, key); end; end
        chat_emit(chat, Dict{String,Any}("type" => "question_done", "key" => key))
    end
    answer isa AbstractDict ||
        return Dict("action" => "decline")     # skipped / timed out
    return Dict("action" => "accept", "content" => Dict{String,Any}(answer))
end

# ── Client lifecycle ───────────────────────────────────────────────────────

# At most this many chats keep a live agent (ACP subprocess) at once. Lazy ACP
# already means only chats you've MESSAGED bind; this caps even that so a server
# can't accumulate unbounded agent processes. Generous — the rest still open
# instantly and show history from disk.
const BIND_CAP = 8

# Record that `pid`'s agent just bound (MRU) and keep at most BIND_CAP agents
# alive: when we exceed it, fully CLOSE the oldest IDLE session (`stop_session!`
# reaps its agent + drops the model). With lazy ACP a re-open rebuilds the chat
# from its on-disk history and re-binds on the next turn — and the fresh
# ChatModel/agent avoids reusing one agent's `ws` Ref across generations.
function note_bound!(state::ServerState, pid::AbstractString)
    isempty(pid) && return nothing
    victim_pid = lock(state.lock) do
        # If the chat was closed (removed from chat_models) before this bind's
        # note_bound! landed — a turn buffered past close that still lazily
        # bound — don't (re)enter it into the LRU. stop_session! already pruned
        # the pid under THIS lock; re-adding it here leaks a dead entry that
        # nothing ever filters out again (the leak_cycle bound_lru leak).
        haskey(state.chat_models, pid) || return ""
        lru = state.bound_lru
        filter!(!=(pid), lru)
        push!(lru, pid)                       # most-recently-bound last
        length(lru) <= BIND_CAP && return ""
        for i in eachindex(lru)
            cand = lru[i]
            cand == pid && continue           # never evict the one we just bound
            m = get(state.chat_models, cand, nothing)
            m === nothing && (deleteat!(lru, i); return "")   # stale entry
            shared(m).busy_active[] && continue               # don't cut a chat off mid-turn
            return cand
        end
        return ""                             # everyone's busy — let it ride once
    end
    if !isempty(victim_pid)
        p = get(state.projects[], victim_pid, nothing)
        if p !== nothing
            @info "LRU: closing idle chat to cap live agents" pid = victim_pid cap = BIND_CAP
            stop_session!(state, p)           # reaps the agent + prunes bound_lru
        end
    end
    return nothing
end

function start_chat_client!(model::ChatModel)
    # fs/* RPCs delegate to the stock FSRequestHandler; permission requests
    # render as interactive cards (see ChatPermissionHandler above).
    # `agent_cwd(agent)` is the path the agent sees (cwd locally, worker_path
    # remotely) so fs reads resolve against the right root. Install the handler
    # on the agent so `start!` wires it into the Connection.
    handler = ChatPermissionHandler(
        AgentClientProtocol.FSRequestHandler(agent_cwd(model.agent)),
        shared(model))
    model.agent.handler = handler

    # Capture the recorded session id BEFORE start! so we can detect
    # "fresh session, not a resume". A mismatch means claude has no memory of
    # `msgs_store` (e.g. project synced to a different worker), so we arm a
    # one-shot history prelude that the next prompt consumes (`with_prelude`).
    prev_session_id = model.chat_session.session_id
    # `on_frame` taps every raw ACP frame (both directions) into
    # chat_dir/acp.jsonl — inspectable live via GET /acp-log/<project_id>.
    start!(model.agent;
           on_frame = let logger = acp_frame_logger(model.chat_dir),
                          s = shared(model)
               (dir, msg) -> begin
                   # Every inbound frame counts as stream activity — the busy
                   # heuristic (`update_busy!`) keys off this, and a minutes-long
                   # streaming reply must not read as "quiet" just because the
                   # turn loop sits inside one message.
                   dir === :in && (s.last_stream_at[] = time())
                   logger(dir, msg)
               end
           end)
    cli = client(model.agent)
    replay_msgs = replay(model.agent)
    # Header metadata: typed views over the raw session-setup result. A future
    # agent kind extends this line with additional parsers over the same dict.
    # (What the header SHOWS is a separate, display-side decision — see
    # `show_in_header`.)
    shared(model).session_meta[] =
        Any[AgentClientProtocol.parse_config_options(cli.session_result)...]
    # Assert this thread's permission mode / effort / model on the live session —
    # fresh OR resume — since claude doesn't remember them across resume. Synchronous
    # so the first prompt of the turn runs under the asserted config.
    apply_session_config!(model)
    new_session_id = cli.session_id
    if isempty(replay_msgs)
        # No replay (fresh session/new, or an agent without resume). If WE
        # have history but claude doesn't (the session changed under us), feed
        # ours forward as a one-shot text prelude on the next prompt.
        if !isempty(model.msgs_store) && prev_session_id != new_session_id
            arm_history_replay!(model)
        end
    else
        # claude resumed and re-streamed its history — reconcile into chat.md
        # (keep ours canonical, adopt only what we're missing). Mutually
        # exclusive with the prelude: claude HAS memory here, so we never
        # double-feed it ours.
        reconcile_replay!(model, replay_msgs)
    end
    update_session_id!(model.chat_session, new_session_id)
    # Bind the claude session id onto the project. A fresh `session/new` chat
    # gets its real session id only HERE (the agent assigned it); without writing
    # it back, `ProjectInfo.resume_session_id` stayed `nothing` forever, so:
    #   * the SAME open chat appeared in BOTH the homebar (under its title) AND
    #     the folder→threads browser (under its first message) — the dedup there
    #     keys on resume_session_id and couldn't recognise it, and
    #   * reopening it from that browser ran `find_thread` with the real id,
    #     matched nothing, and spawned a DUPLICATE untitled project — "the name
    #     reverted to the first message".
    # Recording it makes the thread dedup/resume machinery (thread_dedup_key,
    # find_thread, the browser's imported-session hide) all agree on one chat.
    record_bound_session!(model, new_session_id)
    shared(model).session_alive[] = true
    note_bound!(model.state, model.project_id)
    return nothing
end

# Make a chat LIVE for VIEWING — cache it, start its consumer + poller — WITHOUT
# binding an agent (the ACP subprocess is spawned lazily on the first turn).
function register_chat_model!(model::ChatModel)
    s = shared(model)
    if s.consumer_task[] === nothing
        s.consumer_task[] = Base.errormonitor(@async run_chat!(s))
    end
    start_background_poller!(model.state, s)
    if !isempty(model.project_id)
        @info "registering chat model" project_id = model.project_id
        lock(model.state.lock) do
            model.state.chat_models[model.project_id] = model
        end
        notify_chats!(model.state)
    end
    return nothing
end

# Restart coordination lives on the shared ChatModel (`restart_inflight`,
# `restart_gen`, `restart_lock` fields), so per-session views funnel to one gate
# and the state dies with the chat. Two concurrent restart calls would otherwise
# both close(old_client), both wait, both call start_chat_client! — at best one
# losing its newly-spawned client, at worst deadlocking because each blocks the
# consumer task's `sweep_turn_orphans!` from acquiring `model.lock`. `restart_lock`
# guards the brief read-test-set; `restart_inflight` elects the single worker; and
# `restart_gen` is the monotonic "restart requested" counter — every call bumps it
# and the in-flight worker re-runs the bring-up until it has satisfied the LATEST
# request, so a rapid provider switch can't be coalesced away (which used to bring
# the session up on the *previous* provider while the header showed the new one).

# One bring-up cycle: tear the old client down and spin a fresh one from the
# CURRENT `model.agent` (so it reflects the latest provider). Errors are
# caught + recorded on `last_error` (the session is left dead, not crashed) so
# the worker loop in `restart_chat_session!` can keep going.
function bring_up_once!(model::ChatModel)
    s = shared(model)
    try
        old = client(model.agent)
        # stop! is idempotent + total: stdin EOF / WS peer close makes the
        # agent exit cleanly and cascades through the Connection teardown, so
        # any in-flight `prompt!` errors out (its turn loop ends) without stale
        # updates leaking into the new session. The agent owns its own
        # subprocess/ws, so a fresh `start!` can't clobber the old session.
        if old !== nothing
            stop!(model.agent)
            # Wait for the in-flight turn (if any) to actually exit so its
            # try/catch/finally in `run_turn!` runs to completion BEFORE we
            # boot a fresh client (it emits the trailing `thinking=false`, runs
            # `sweep_turn_orphans!`, clears `busy_active`). Racing past it lets
            # the new client emit chunks against the same comm while the old
            # finally is still running — undefined wire ordering. Bounded so a
            # wedged consumer can't block us forever.
            deadline = time() + 2.0
            while s.busy_active[] && time() < deadline
                sleep(0.02)
            end
        end
        s.busy_active[] = false
        chat_emit(s, Dict{String,Any}("type" => "thinking", "active" => false))
        sweep_turn_orphans!(s)
        # JS-side reset: drop any UI state attached to the dead session before
        # the new client can emit against it.
        chat_emit(s, Dict{String,Any}("type" => "session_reset"))

        start_chat_client!(model)      # brings up a fresh client[]; consumer keeps running
        s.session_alive[] = true
        s.last_error[] = ""
        chat_emit(s, Dict{String,Any}(
            "type" => "msgs.count", "n" => length(s.msgs_store)))
    catch e
        s.session_alive[] = false
        s.last_error[] = "restart failed: $(sprint(showerror, e))"
        @error "restart_chat_session! failed" exception=(e, catch_backtrace())
    end
    return nothing
end

function restart_chat_session!(model::ChatModel)
    s = shared(model)
    # Register this request (bump the generation) and decide who runs the work.
    # If a worker is already in flight we just leave our bumped generation for it
    # — it will loop and bring up the LATEST `transport.provider` before
    # finishing — and wait (bounded) for it to settle. Otherwise WE are the
    # worker. Concurrent restarts must never both `close(old)`/`start_chat_client!`
    # (lost client / consumer-lock deadlock), so exactly one worker runs at a time.
    iam_worker = lock(s.restart_lock) do
        s.restart_gen[] += 1
        if s.restart_inflight[]
            false
        else
            s.restart_inflight[] = true
            true
        end
    end
    if !iam_worker
        deadline = time() + 20.0
        while time() < deadline && lock(() -> s.restart_inflight[], s.restart_lock)
            sleep(0.02)
        end
        return nothing
    end
    try
        # Loop until we've satisfied the newest request: if another restart was
        # requested (generation bumped) while we were bringing one up, go again
        # so the FINAL session reflects the last switch's provider.
        while true
            target = lock(() -> s.restart_gen[], s.restart_lock)
            bring_up_once!(model)
            done = lock(s.restart_lock) do
                if s.restart_gen[] == target
                    s.restart_inflight[] = false
                    true
                else
                    false   # a newer request arrived mid-restart — run again
                end
            end
            done && break
        end
    catch
        # Defensive: never leave the in-flight flag stuck (would wedge all future
        # restarts). bring_up_once! already swallows bring-up errors, so this only
        # fires on something truly unexpected.
        lock(() -> (s.restart_inflight[] = false), s.restart_lock)
        rethrow()
    end
    return nothing
end

# Single-entry "user submitted a message" path. Every call site (input area,
# auto-prompt, scripted hooks) goes through here. We render + persist the user
# bubble synchronously so the message appears the instant the user hits send —
# previously the bubble was created inside `run_turn!`, which meant messages
# submitted while an earlier turn was still running stayed invisible (queued
# silently on the channel) until that turn finished. Now they show up as
# "queued" bubbles immediately; `promote_queued_user_bubble!` clears the
# `queued` flag when `run_turn!` actually picks them up.
#
# `images` are sent to the agent as multimodal content blocks; the caller is
# responsible for embedding any file-path reference into `msg.text` so display
# + replay see what claude does.
function send_message!(model::ChatModel, msg::UserMsg;
    images=AgentClientProtocol.ImageAttachment[])
    s = shared(model)
    # If there's a turn in flight, the bubble joins the queue (visually dim).
    bubble = UserMsg(model, msg.text)
    bubble.queued = s.busy_active[]
    close(send!(model, bubble))   # send! pushes + emits wire_new; close persists
    # Refresh the lens vocabulary NOW that a user message exists, rather than
    # waiting for end-of-turn (drain_turn!'s emit_lens_vocab). Otherwise the
    # `/user_message` key isn't suggestable until the agent's reply lands — the
    # user can't lens-filter their own just-sent message mid-turn.
    emit_lens_vocab(model)
    put!(s.user_messages,
        UserMessage(msg.text, collect(AgentClientProtocol.ImageAttachment, images)))
    backfill_project_title!(model, msg.text)
    return nothing
end

# Strip claude-agent-acp injected context blocks (`<ide_opened_file>…`,
# `<system-reminder>…`, `<local-command-*>…`, …) and the "Caveat" prefix.
# A duplicate of BonitoWorker's `strip_injected_context`/`meaningful_prompt`
# kept here so the server side doesn't depend on the deployed worker's
# version of those helpers (older workers pre-date them).
#
# Generic strategy: peel any leading wrapper — three shapes:
#   1. `<tag …attrs?…>body</tag>` paired block (closer backref'd to opener)
#   2. `<tag …attrs?…/>` self-closing (no body)
#   3. `<tag …attrs?…>` bare opener at start of remainder ⇒ system commentary
#      with no following user prose ⇒ skip the message
#
# Attributes inside the opener (`<command-args foo="bar">`) are tolerated
# via the `[^>]*` arm — without it the regex bailed at the first space and
# the whole tag leaked into the title.
const TITLE_LEADING_TAG_BLOCK = r"\A\s*<\s*([A-Za-z][\w-]*)(?:\s+[^>]*)?\s*>.*?<\s*/\s*\1\s*>"is
const TITLE_LEADING_TAG_SELF  = r"\A\s*<\s*[A-Za-z][\w-]*(?:\s+[^>]*)?\s*/\s*>"is
const TITLE_LEADING_TAG_OPENER= r"\A\s*<\s*[A-Za-z][\w-]*(?:\s+[^>]*)?\s*>"is

function meaningful_title(raw::AbstractString)
    s = String(raw)
    # Peel paired blocks and self-closing tags from the front. A single loop
    # iteration handles either shape; alternate-pattern peeling lets the
    # caller's intermixed wrappers (e.g. `<command-args/><system-reminder>x</system-reminder>real`)
    # collapse to the user prose in one pass.
    while true
        m = match(TITLE_LEADING_TAG_BLOCK, s)
        if m === nothing
            m = match(TITLE_LEADING_TAG_SELF, s)
        end
        m === nothing && break
        s = s[nextind(s, lastindex(m.match)):end]
    end
    s = strip(s)
    isempty(s) && return nothing
    # A bare opener still up front means the message is system commentary
    # (`<ide_opened_file>The user opened …` with no closer; not user prose).
    occursin(TITLE_LEADING_TAG_OPENER, s) && return nothing
    startswith(s, "Caveat: The messages below were generated by the user") && return nothing
    # Collapse whitespace runs, then truncate to a sidebar-friendly length.
    s = strip(replace(s, r"\s+" => " "))
    isempty(s) && return nothing
    return length(s) > 80 ? String(first(s, 79)) * "…" : String(s)
end

# Set `p.title` from the user's first meaningful prompt — what makes the
# sidebar / project card read `[DT] resume the build refactor` instead of
# `[DT] ClaudeExperiments`. Idempotent: only fires while `title` is still
# `nothing` (a user edit pins it forever). No-op for projects whose
# state.projects[] entry is gone (project removed mid-send).
function backfill_project_title!(model::ChatModel, prompt::AbstractString)
    pid = model.project_id
    isempty(pid) && return
    haskey(model.state.projects[], pid) || return
    p = model.state.projects[][pid]
    p.title === nothing || return
    t = meaningful_title(prompt)
    t === nothing && return
    p.title = t
    try
        save_projects!(model.state)
    catch e
        @warn "backfill_project_title!: persist failed" exception=e
    end
    safe_notify!(model.state.projects)
    return nothing
end

# Persist the agent-assigned claude session id onto the project so the thread
# becomes resumable + dedupable (see the call site in `start_chat_client!`).
# Idempotent: a no-op when the id is unchanged (a restart/resume re-binds the
# same id) or empty, and when the project entry is gone. Notifies `projects` on
# a real change so the folder→threads browser hides the now-tracked session.
function record_bound_session!(model::ChatModel, session_id::AbstractString)
    pid = model.project_id
    (isempty(pid) || isempty(session_id)) && return
    # Only persist a session id for providers that support claude-style
    # `session/load` re-attach (ClaudeCode, and the mock which mimics it).
    # Recording e.g. a MiMo session id would make the next bring-up `session/load`
    # a session that provider never created — the exact error `switch_provider!`
    # clears the id to avoid. Claude sessions are also the only ones the worker's
    # discover scan surfaces, so this is exactly the set thread dedup/resume needs.
    resumable_session(agent_kind(model.agent)) || return
    haskey(model.state.projects[], pid) || return
    p = model.state.projects[][pid]
    p.resume_session_id == session_id && return
    p.resume_session_id = String(session_id)
    try
        lock(model.state.lock) do; save_projects!(model.state); end
    catch e
        @warn "record_bound_session!: persist failed" exception=e
    end
    safe_notify!(model.state.projects)
    return nothing
end

# `run_turn!` calls this right before driving the agent prompt for a popped
# `UserMessage`. Finds the oldest UserMsg in `msgs_store` still marked queued
# (FIFO matches the channel order under `send_message!`) and emits a
# `user_unqueue` event so the browser drops the "queued" class. No-op when
# the chat was idle — the just-pushed bubble was never queued.
function promote_queued_user_bubble!(chat::ChatModel)
    idx = lock(chat.lock) do
        for (i, m) in enumerate(chat.msgs_store)
            if m isa UserMsg && m.queued
                m.queued = false
                return i
            end
        end
        return nothing
    end
    idx === nothing && return nothing
    # Ship the store index (0-based for JS): the client must clear the badge
    # on the CACHED node at that index — a DOM-only lookup misses bubbles
    # that are virtually scrolled out, leaving a stale QUEUED badge that
    # makes the whole chat read as wedged.
    chat_emit(chat, Dict{String,Any}("type" => "user_unqueue", "idx" => idx - 1))
    return nothing
end

# Auto-prompt: if the project carries an `auto_prompt` (set by the "From
# GitHub" template) and the chat is otherwise empty, fire it once as the
# first user message. Cleared + persisted right away so a server restart or
# session reconnect doesn't double-fire.
function fire_auto_prompt!(model::ChatModel)
    isempty(model.project_id) && return
    haskey(model.state.projects[], model.project_id) || return
    proj = model.state.projects[][model.project_id]
    ap = proj.auto_prompt
    (ap === nothing || isempty(ap) || !isempty(model.msgs_store)) && return
    proj.auto_prompt = nothing
    try
        save_projects!(model.state)
    catch e
        @warn "auto_prompt: persist clear failed" exception = e
    end
    send_message!(model, UserMsg(String(ap)))
    return nothing
end

# Build a transcript prelude from `msgs_store` to feed into claude's first
# prompt after a session change (project synced to a new worker, restart
# without a usable resume_id, etc.). User + agent turns only — tool calls
# and thoughts are claude-internal artifacts and don't belong in the
# conversation context. Capped at the last 60 turns to keep the prompt
# size sane on long histories.
function build_history_prelude(model::ChatModel)::String
    relevant = ChatMsg[]
    lock(model.lock) do
        for m in model.msgs_store
            (m isa UserMsg || m isa AgentMsg) && push!(relevant, m)
        end
    end
    if length(relevant) > 60
        relevant = relevant[end-59:end]
    end
    io = IOBuffer()
    println(io, "Below is a transcript of our previous conversation on this project. ",
        "I'm continuing where we left off — please read it for context, then respond ",
        "to my new message after the divider.")
    println(io)
    println(io, "--- PREVIOUS CONVERSATION ---")
    for m in relevant
        if m isa UserMsg
            println(io, "USER: ", m.text)
        elseif m isa AgentMsg
            println(io, "ASSISTANT: ", m.text)
        end
        println(io)
    end
    println(io, "--- END OF PREVIOUS CONVERSATION ---")
    println(io)
    println(io, "My new message:")
    println(io)
    return String(take!(io))
end

# Arm a one-shot history replay for the next prompt. Builds the prelude
# **now** (so any messages the user types between arming and sending are
# their own conversation, not part of the replay) and stashes it on the
# model. Idempotent — a second arm before consume replaces the prelude.
function arm_history_replay!(model::ChatModel)
    lock(model.lock) do
        model.pending_history_replay[] = build_history_prelude(model)
    end
    @info "chat history replay armed" project_id = model.project_id n_msgs = length(model.msgs_store)
    return nothing
end

# Prepend any armed one-shot history prelude to `text`, consuming it. Empty in
# steady state — only set right after a session change that lost claude's jsonl.
function with_prelude(model::ChatModel, text::AbstractString)
    p = model.pending_history_replay[]
    isempty(p) || (model.pending_history_replay[] = "")
    return p * text
end

# ── Reconcile claude's resumed history into chat.md (keep ours, fill gaps) ───
# On `session/load` claude re-streams the resumed session's full history (see
# `ACP.replay_history`). `chat.md` is canonical, so we adopt only what we're
# missing: the whole replay when chat.md is empty (importing a claude session),
# or the tail beyond our last recorded turn (e.g. the user used the Claude Code
# CLI directly). Our history is always an in-order prefix of claude's — every
# turn goes through claude — so we match the shared prefix and append the rest.

# Which replayed messages belong in persisted history. Redacted/empty thoughts
# and empty text turns leave no trace (consistent with `process!(::Thought)`).
keep_in_history(m::AgentClientProtocol.AgentMessage) = !isempty(strip(m.text))
keep_in_history(m::AgentClientProtocol.UserMessage)  = !isempty(strip(m.text))
keep_in_history(m::AgentClientProtocol.Thought)      = false
keep_in_history(m::AgentClientProtocol.ToolCall)     = true
keep_in_history(m::AgentClientProtocol.Plan)         = true

# Does an existing (chat.md) message correspond to a replayed one? Tools key on
# claude's tool_use id (the one id that survives the replay, stored as ToolMsg.id);
# user/agent turns on text; plans on entries. Different shapes never match.
msg_matches(a::ToolMsg,  b::AgentClientProtocol.ToolCall)     = a.id == b.id
msg_matches(a::UserMsg,  b::AgentClientProtocol.UserMessage)  =
    !is_summary_text(b.text) && strip(a.text) == strip(b.text)
msg_matches(a::SummaryMsg, b::AgentClientProtocol.UserMessage) =
    is_summary_text(b.text) && strip(a.text) == strip(b.text)
msg_matches(a::AgentMsg, b::AgentClientProtocol.AgentMessage) = strip(a.text) == strip(b.text)
msg_matches(a::TodoListMsg, b::AgentClientProtocol.Plan)         = plan_entries_equal(a.entries, b.entries)
msg_matches(a::TodoListMsg, b::AgentClientProtocol.TodoWriteCall) = plan_entries_equal(a.entries, b.entries)
msg_matches(::ChatMsg,   ::AgentClientProtocol.Message)       = false

plan_entries_equal(a, b) = length(a) == length(b) &&
    all(ea.content == eb.content && ea.status == eb.status for (ea, eb) in zip(a, b))

# Length of the leading run where our store and the replay candidates line up
# index-for-index (the shared prefix). Everything after is claude-only → adopt.
function longest_matched_prefix(existing, candidates)
    n = min(length(existing), length(candidates))
    i = 1
    while i <= n && msg_matches(existing[i], candidates[i])
        i += 1
    end
    return i - 1
end

# Persist + store one replayed message as history (chat === nothing; never emits
# live UI events — the single `msgs.count` from `reconcile_replay!` covers it).
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.AgentMessage)
    msg = AgentMsg(string(uuid4()), m.text)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    finalize_agent(model.chat_session, msg)
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.UserMessage)
    if is_summary_text(m.text)
        msg = SummaryMsg(m.text)
        lock(model.lock) do; push!(model.msgs_store, msg); end
        append_summary(model.chat_session, msg)
    else
        msg = UserMsg(m.text)
        lock(model.lock) do; push!(model.msgs_store, msg); end
        append_user(model.chat_session, msg)
    end
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.ToolCall)
    isempty(m.content) || persist_tool_content!(model.chat_dir, m)
    # Pick the typed BonitoAgents variant per ACP subtype. Replay always lands
    # as a finished call (no live updates afterwards), so `finished_at = now`.
    msg = replayed_tool_msg(m)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    msg.status in ("completed", "failed") && append_tool(model.chat_session, msg)
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.TodoWriteCall)
    msg = TodoListMsg(string(uuid4()), collect(PlanEntry, m.entries),
                      time(), time(), nothing)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    append_plan(model.chat_session, msg)
end
function adopt_replayed!(model::ChatModel, m::AgentClientProtocol.Plan)
    msg = TodoListMsg(string(uuid4()), collect(PlanEntry, m.entries),
                      time(), time(), nothing)
    lock(model.lock) do; push!(model.msgs_store, msg); end
    append_plan(model.chat_session, msg)
end

# Mirror of `build_tool_msg` for the replay path: no `chat`, finished_at
# stamped now so the timer doesn't tick. The typed variants persist their
# subtype-specific fields too (so e.g. a replayed background bash still
# rendered the right way).
# Replayed live app — content is on disk (so the app id is available now); same
# type-driven recognition as the live path (`is_bonito_app`).
replayed_bonito_app_msg(tc, server) =
    BonitoAppMsg(tc.id, "bonito_app", tc.title, tc.status,
                 content_summary("bonito_app", tc.content),
                 time(), time(), server,
                 something(find_app_reference(tc.content), ""), nothing)

replayed_tool_msg(tc::AgentClientProtocol.GenericTool) =
    is_bonito_app(tc) ? replayed_bonito_app_msg(tc, "") :
    GenericToolMsg(tc.id, tc.kind, tc.name, tc.title, tc.status,
                   content_summary(tc.kind, tc.content),
                   time(), time(), nothing, Dict{String,Any}(tc.raw_input))
replayed_tool_msg(tc::AgentClientProtocol.BashCall) =
    BashToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), time(),
                tc.command, tc.description, tc.run_in_background,
                "", 0, false, "", nothing)   # bg fields: history → already done
replayed_tool_msg(tc::AgentClientProtocol.TaskCall) =
    TaskToolMsg(tc.id, tc.kind, tc.title, tc.status,
                content_summary(tc.kind, tc.content),
                time(), time(),
                tc.description, tc.run_in_background, tc.task_name, nothing)
replayed_tool_msg(tc::AgentClientProtocol.MCPCall) =
    is_bonito_app(tc) ? replayed_bonito_app_msg(tc, tc.server) :
    MCPToolMsg(tc.id, tc.kind, tc.title, tc.status,
               content_summary(tc.kind, tc.content),
               time(), time(),
               tc.server, tc.tool_name, Dict{String,Any}(tc.raw_input), nothing)

function reconcile_replay!(model::ChatModel, replay)
    candidates = filter(keep_in_history, replay)
    adopt = lock(model.lock) do
        existing = model.msgs_store
        isempty(existing) ? candidates :
            candidates[(longest_matched_prefix(existing, candidates) + 1):end]
    end
    isempty(adopt) && return nothing
    for m in adopt
        adopt_replayed!(model, m)
    end
    chat_emit(model, Dict{String,Any}(
        "type" => "msgs.count", "n" => length(model.msgs_store)))
    @info "reconciled claude history" project_id = model.project_id adopted = length(adopt)
    return nothing
end

# ── DOM building (split into header / messages / input / banner) ──────────
# ── Header metadata line ─────────────────────────────────────────────────────
# One `header_pill` method per metadata kind in `session_meta` — future agents
# add a struct + a method here, never touch the header skeleton. Display-only:
# plain text spans (tooltip carries the full description), joined with " · "
# on a second header line below the title/sync row.

function pill_tooltip(o::AgentClientProtocol.ConfigOption)
    c = AgentClientProtocol.current_choice(o)
    c === nothing && return "$(o.name): $(o.current_value)"
    isnothing(c.description) || isempty(c.description) ?
        "$(o.name): $(c.name)" : "$(o.name): $(c.name) — $(c.description)"
end

# The model label ("Opus 4.7 with 1M context") is self-explanatory; the other
# options need their name as a prefix to read well ("mode: Default").
#
# `pick` is an Observable{Tuple{String,String}} ((configId, value)) the model
# pill posts into on selection; nothing for the static (no-picker) rendering
# path (e.g. unit tests of `header_meta_line` with a plain item list).
# Config options the user can change live from the header (model, permission
# mode, reasoning effort). All three drive the SAME `set_config_option` path —
# verified to actually take effect mid-session (model switch flips the model used
# for the next turn; mode/effort are accepted too).
const SELECTABLE_CONFIG = ("model", "mode", "thought_level")

# `lowercase_modes` lower-cases the PERMISSION-MODE labels (claude reports them
# title-cased — "Default", "Bypass Permissions"); set for the Claude provider so
# the mode pill reads in the same lower-case style as the underlying values.
function header_pill(o::AgentClientProtocol.ConfigOption,
                     pick::Union{Observable,Nothing} = nothing;
                     lowercase_modes::Bool = false)
    lc = lowercase_modes && o.category == "mode"
    if pick !== nothing && o.category in SELECTABLE_CONFIG && length(o.choices) > 1
        return config_select_pill(o, pick; lc = lc)
    end
    label = AgentClientProtocol.pill_label(o)
    lc && (label = lowercase(label))
    # No name prefix — just the value; the option name lives in the tooltip.
    DOM.span(label; class = "bt-header-meta-item", title = pill_tooltip(o))
end
# Fallback so an unknown meta kind degrades to its string form, not an error.
header_pill(x, pick::Union{Observable,Nothing} = nothing; lowercase_modes::Bool = false) =
    DOM.span(string(x); class = "bt-header-meta-item")

# A native <select> wrapped to look like the meta-item pill. The agent's
# config_option_update is the SOURCE OF TRUTH for the displayed value — we
# rebuild the select on every session_meta change, so `selected` is whatever
# the agent currently reports. `onchange` posts `(configId, value)` into
# `pick`; the parent handler (registered ONCE in `chat_header`) translates
# that into a `set_config_option!` RPC.
function config_select_pill(o::AgentClientProtocol.ConfigOption, pick::Observable;
                            lc::Bool = false)
    cfg_id = o.id
    cur    = o.current_value
    lab(name) = lc ? lowercase(name) : name   # lower-case the option labels (mode)
    # Build each option separately so we can conditionally include the
    # `selected` attribute — Bonito's DOM renders `selected = nothing` as a
    # bare `selected` (boolean attribute is present, just empty), which then
    # marks EVERY option as selected. Splatting kwargs lets us omit the key
    # entirely on the non-current options.
    function mkopt(c)
        title = isnothing(c.description) ? c.name : c.description
        kwargs = c.value == cur ?
            (; value = c.value, title = title, selected = true) :
            (; value = c.value, title = title)
        DOM.option(lab(c.name); kwargs...)
    end
    sel = DOM.select((mkopt(c) for c in o.choices)...;
            class = "bt-header-meta-select",
            onchange = js"event => $(pick).notify([$(cfg_id), event.target.value])")
    # No name prefix — each pill shows just its value; the full "Mode: …" /
    # "Effort: …" label rides on the hover tooltip (`pill_tooltip`).
    DOM.div(sel;
        class = "bt-header-meta-item bt-header-meta-pick",
        title = pill_tooltip(o))
end

# Display policy: which meta items make it into the header line. We surface the
# three controllable claude options — model, permission mode, reasoning effort —
# as interactive pills. Their displayed values are now TRUSTWORTHY because we
# assert them at bring-up (`apply_session_config!`) instead of passively echoing
# claude's reported value (which is "default" on resume regardless of reality).
# Future meta kinds default to visible.
show_in_header(o::AgentClientProtocol.ConfigOption) = o.category in SELECTABLE_CONFIG
show_in_header(::Any) = true

# Lead with the model, then permission mode, then effort; other config kinds and
# non-config meta trail.
meta_order(x) = x isa AgentClientProtocol.ConfigOption ?
    (x.category == "model" ? 0 : x.category == "mode" ? 1 :
     x.category == "thought_level" ? 2 : 3) : 4

function header_meta_line(items, pick::Union{Observable,Nothing} = nothing;
                          lowercase_modes::Bool = false)
    shown = sort(filter(show_in_header, collect(Any, items)); by = meta_order)
    # Keep the `.bt-header-meta` element (and its `margin-left:auto`) even when
    # empty — e.g. while a provider switch has cleared `session_meta`. A bare,
    # class-less span here drops the auto-margin, so the whole control cluster
    # (provider/sync/restart) collapses leftward and snaps back when the new
    # model loads — a jarring header jump on every switch.
    isempty(shown) && return DOM.div(; class = "bt-header-meta")
    # Each pill is a bordered button (see `.bt-header-meta-pick`); spacing comes
    # from the flex `gap`, so no " · " text separators between them.
    DOM.div((header_pill(x, pick; lowercase_modes) for x in shown)...; class = "bt-header-meta")
end

# Compact the per-file sync progress ("Sending 137/999: src/long/path.jl")
# down to header-pill size; the full message rides on the button tooltip.
function compact_sync_label(s::AbstractString)
    (isempty(s) || s == "__click__") && return "Sync"
    length(s) <= 26 ? String(s) : String(first(s, 25)) * "…"
end

function chat_header(session::Bonito.Session, model::ChatModel, sync_modal_state::Observable)
    state = model.state
    project_id = model.project_id
    cwd = model.cwd
    # The folder shown to the user is the project's path ON THE WORKER — where the
    # agent and `bt_julia_eval` actually run, and the same path the projects scan
    # list shows (`ProjectInfo.worker_path`). `model.cwd` is the server-side mirror
    # under the state dir (`/…/state/working/<worker>-<name>`), which is
    # meaningless to the user. Fall back to `cwd` only when there's no project yet.
    project_now = isempty(project_id) ? nothing : get(state.projects[], project_id, nothing)
    worker_dir = (project_now === nothing || isempty(project_now.worker_path)) ?
        cwd : project_now.worker_path

    status_dot = map(model.session_alive) do alive
        DOM.span(""; class=alive ? "bt-dot bt-dot-online" : "bt-dot bt-dot-offline",
            title=alive ? "session live" : "session ended")
    end

    # ── Editable chat title ───────────────────────────────────────────────
    # The header title is an inline-editable input over `ProjectInfo.title`
    # (the same field the sidebar label and the auto-backfill use). Editing
    # here persists via `set_project_title!`, which notifies
    # `state.projects` — so the sidebar entry and every other tab's header
    # update in lockstep. An empty edit clears the override back to the
    # folder name. Session-scoped `map` so the listener dies with the tab.
    fallback_title = basename(rstrip(cwd, '/'))
    title_val = map(session, state.projects) do projects
        q = isempty(project_id) ? nothing : get(projects, project_id, nothing)
        q === nothing ? fallback_title : project_display_title(q)
    end
    title_edit = Observable("")
    on(session, title_edit) do t
        isempty(project_id) && return
        haskey(state.projects[], project_id) || return
        try
            set_project_title!(state, project_id, t)
        catch e
            @warn "chat title edit failed" project_id exception = e
        end
    end
    title_node = if isempty(project_id)
        DOM.div(DOM.span(fallback_title; title=worker_dir), class="bt-header-title")
    else
        DOM.input(; type = "text",
            class = "bt-header-title bt-header-title-edit",
            value = title_val,
            title = "Chat title — click to edit · folder: $worker_dir",
            onchange  = js"event => $(title_edit).notify(event.target.value)",
            onkeydown = js"""event => {
                if (event.key === 'Enter') { event.target.blur(); }
                else if (event.key === 'Escape') {
                    event.target.value = $(title_val).value;
                    event.target.blur();
                }
            }""")
    end

    # Project environment this chat's eval sessions run in (the Project.toml /
    # working dir). A muted monospace sub-line under the title row so each tab
    # makes its env unmistakable. Home-contracted for readability; full path on
    # hover.
    env_line = DOM.div(replace(worker_dir, homedir() => "~"); class="bt-header-env", title=worker_dir)

    # Session config (model / mode / effort …) as a plain-text second header
    # line; re-renders whenever the agent reports a change (bring-up,
    # config_option_update). The model pill is a native `<select>` and posts
    # `(configId, value)` into `config_pick` when the user chooses; the
    # handler below sends `session/set_config_option` and optimistically
    # patches `session_meta` so the new choice is reflected immediately
    # (the agent's follow-up `config_option_update` reconciles).
    # The model <select>'s JS posts `[configId, value]` as a JSON array, which
    # arrives over the wire as a `Vector{Any}`. A `Observable{Tuple{String,String}}`
    # REJECTS that ("Cannot convert Vector{Any} to Tuple{String,String}") and the
    # pick is dropped on the floor — the agent's model never changes, so the
    # session stays on whatever it defaulted to (e.g. a paid model that returns
    # empty turns). Hold the raw payload and normalize in the handler.
    config_pick = Observable{Any}(["", ""])
    # Always lower-case the permission-mode labels (claude reports them
    # title-cased — "Default", "Bypass Permissions"). Unconditional: the
    # provider-gated version didn't reliably detect Claude at render time, and
    # lower-case reads fine for any provider's mode option.
    meta_line = map(items -> header_meta_line(items, config_pick; lowercase_modes = true),
                    model.session_meta)
    on(session, config_pick) do pick
        (pick isa AbstractVector || pick isa Tuple) && length(pick) == 2 || return
        cfg_id, value = String(pick[1]), String(pick[2])
        isempty(cfg_id) && return
        apply_config_pick!(model, cfg_id, value)
        # Remember the pick on the thread so resume restores it (claude won't).
        persist_desired_config!(model, cfg_id, value)
    end

    sync_status = Observable("")
    # Keep the button COMPACT: the idle label is "Sync"; while syncing the
    # label is a truncated progress string and the full message (long
    # per-file paths) rides on the tooltip.
    sync_title = map(sync_status) do s
        isempty(s) || s == "__click__" ?
            "Pull this project from the worker to the server" : s
    end
    sync_button = DOM.button(map(compact_sync_label, sync_status);
        class="bt-header-sync",
        title=sync_title,
        onclick=js"event => $(sync_status).notify('__click__')")
    on(session, sync_status) do s
        s == "__click__" || return
        sync_status[] = ""
        isempty(project_id) && (sync_status[] = "no project bound"; return)
        handle_chat_sync_click(state, project_id, sync_status)
    end

    # Cross-worker sync: only present when this project has a same-named
    # sibling on another worker. Clicking inspects both sides and opens the
    # comparison modal (see `render_sync_modal`). Computed at header build
    # time — re-navigating refreshes it if siblings appear/disappear.
    sibs = isempty(project_id) ? ProjectInfo[] : same_name_siblings(state, project_id)
    xsync_control = if isempty(sibs)
        DOM.span()
    else
        other = first(sibs)
        other_label = haskey(state.workers[], other.worker_id) ?
            state.workers[][other.worker_id].name : other.worker_id
        xsync_status = Observable("")
        xsync_button = DOM.button(map(s -> isempty(s) ? "⇄ $other_label" : s, xsync_status);
            class="bt-header-sync",
            title="Compare and sync this project with $other_label",
            onclick=js"event => $(xsync_status).notify('__click__')")
        on(session, xsync_status) do s
            s == "__click__" || return
            # Guard the lookup BEFORE flipping the label to "comparing…" (T18):
            # an unguarded `state.projects[][project_id]` KeyErrors if the project
            # was deleted, escaping before the @async whose catch resets the
            # label — so the button wedged on "comparing…" forever.
            cur = get(state.projects[], project_id, nothing)
            if cur === nothing
                safe_set!(xsync_status, "project gone")
                return
            end
            xsync_status[] = "comparing…"
            @async begin
                try
                    cmp = compare_projects(state, cur, other)
                    sync_modal_state[] = (current = cur, other = other, comparison = cmp)
                    safe_set!(xsync_status, "")
                catch e
                    @warn "cross-worker compare failed" exception=(e, catch_backtrace())
                    safe_set!(xsync_status, "compare failed")
                end
            end
        end
        xsync_button
    end

    # Header-level restart: the ONE affordance for restarting the ACP session.
    # Previously a banner showed only on session death + had its own button;
    # that banner used Bonito.Button inside a conditional `map(…)` output,
    # which re-rendered the DOM each `session_alive` toggle and on some
    # cycles left the click handler bound to an orphaned element — "click
    # does nothing". The permanent header button avoids that entirely:
    # plain `DOM.button` + Observable click (same pattern as the sync
    # buttons above), one DOM element for the lifetime of the chat.
    #
    # When the session dies, the button gains `bt-header-restart-dead` →
    # CSS pulses it red and the title flips to the error message, so a
    # failure is visible without a separate banner. Mid-restart the label
    # reads "Restarting…" so the click is acknowledged synchronously.
    restart_status = Observable("")
    restart_label  = map(s -> isempty(s) ? "Restart" : s, restart_status)
    restart_class  = map(model.session_alive, restart_status) do alive, status
        # While a restart is running show the "working" state — NOT the red dead
        # pulse — so the button reads as busy, not as a clickable failure. The
        # handler also ignores clicks during a restart, but dropping the dead look
        # is what stops a user (or an impatient poll) from trying to click again.
        if status == "Restarting…"
            "bt-header-restart bt-header-restart-busy"
        elseif alive
            "bt-header-restart"
        else
            "bt-header-restart bt-header-restart-dead"
        end
    end
    restart_title  = map(model.session_alive, model.last_error) do alive, err
        alive  && return "Stop and respawn the agent process for this chat"
        isempty(err) ? "Session ended — click to reconnect" :
                       "Session ended: $err — click to reconnect"
    end
    restart_button = DOM.button(restart_label;
        class   = restart_class,
        title   = restart_title,
        onclick = js"event => $(restart_status).notify('__click__')")
    on(session, restart_status) do s
        s == "__click__" || return
        # The dead-state button stays clickable through the seconds-long bring-up,
        # so a quick second click (or an e2e poller that re-clicks until the dead
        # class clears) would otherwise bump the restart generation and trigger a
        # redundant second bring-up — which tears down the just-revived session and
        # drops the next prompt. Ignore a click while a restart is already running.
        sh = shared(model)
        lock(() -> sh.restart_inflight[], sh.restart_lock) && return
        restart_status[] = "Restarting…"
        @async begin
            try
                restart_chat_session!(model)
            finally
                safe_set!(restart_status, "")
            end
        end
    end

    # ── Provider switcher ──────────────────────────────────────────────────
    # Dropdown to switch between Claude Code, MiMo Code, and OpenCode per chat.
    # Changing the provider restarts the session with the new backend.
    # Wiring follows the restart button above: the DOM event notifies a plain
    # Observable, Julia reacts via `on(session, …)` (a DOM node itself is not
    # observable — `on(session, ::Node)` has no method).
    #
    # A reactive `value=` binding does NOT work on a native <select> (it sticks
    # on the first option — "Claude Code" — regardless of the real provider, so
    # the header lied about the backend). Instead mark the current provider's
    # <option selected> and rebuild the select when `model.provider` changes —
    # the same proven pattern as `config_select_pill`. The `selected` kwarg is
    # splatted in only on the current option (Bonito renders `selected=nothing`
    # as a bare, always-on attribute, which would select every option).
    provider_status = Observable("")
    provider_choice = Observable("")
    # Each menu entry is a provider singleton (a `BinAgent` descriptor). The
    # <option> value is its stable `provider_name` ("ClaudeCode", …); the label is
    # its `label`. `cur` is the current provider held by `model.provider`. The set
    # offered is `current_providers()` — the mock appears only when its env is set.
    provider_opt(p, cur) = DOM.option(label(p);
        (p === cur ? (; value = provider_name(p), selected = true) :
                     (; value = provider_name(p)))...)
    provider_select = map(session, model.provider) do cur
        DOM.select(
            (provider_opt(p, cur) for p in current_providers())...;
            class = "bt-header-provider-select",
            title = "Switch AI agent backend",
            onchange = js"event => $(provider_choice).notify(event.target.value)")
    end
    on(session, provider_choice) do val
        isempty(val) && return
        # Resolve the wire name back to the provider singleton (default Claude).
        new_provider = try
            find_provider(val)
        catch
            find_provider("ClaudeCode")
        end
        current = model.provider[]
        new_provider === current && return
        provider_status[] = "Switching to $(label(new_provider))…"
        @async begin
            try
                switch_provider!(model, new_provider)
                # `switch_provider!` → `restart_chat_session!` swallows bring-up
                # errors (sets `last_error`, keeps the chat object alive), so a
                # failed switch returns normally. Surface it from the resulting
                # session state instead of relying on an exception.
                safe_set!(provider_status,
                    model.session_alive[] ? "" : "switch failed")
            catch e
                @warn "provider switch failed" exception=(e, catch_backtrace())
                safe_set!(provider_status, "switch failed")
            end
        end
    end

    # No back arrow — the unified app's sidebar Home icon is the way home.
    # One compact control row (title + the session-config "model" picks + the
    # provider/sync/restart buttons), then the always-on lens search bar.
    DOM.div(
        DOM.div(
            status_dot,
            title_node,
            # The transient "Switching…" text sits LEFT (in the flexible area),
            # absorbed by the gap so it never shoves the controls. The agent
            # controls — model pill · provider · sync · restart — are ONE
            # right-anchored group (`margin-left:auto` on `.bt-header-actions`),
            # so the model and provider pickers stay together. The model pill is
            # the group's leftmost item: when its label changes width (or clears
            # mid-switch) only its own left edge moves into the gap — the
            # provider/sync/restart buttons never reflow.
            DOM.span(provider_status; class="bt-header-status"),
            DOM.div(
                meta_line,
                provider_select,
                xsync_control,
                sync_button,
                restart_button;
                class="bt-header-actions"),
            class="bt-header-row"),
        env_line,
        # Lens search bar — always visible. JS (`_setupLens`) builds the input
        # + autocomplete + saved-lens chips inside it and wires it to `comm`.
        DOM.div(class="bt-lens-bar");
        class="bt-header")
end

# ── Provider switching ────────────────────────────────────────────────────────

"""
    switch_provider!(model::ChatModel, new_provider::BinAgent)

Switch the agent backend for a chat. This:
1. Updates the provider observable
2. Points the live `WorkerAgent` at `new_provider` (the worker spawns it on the
   next bring-up; the chat's cwd / mcp / project context are preserved)
3. Restarts the session with the new backend

The provider choice is NOT persisted across server restarts — it resets
to ClaudeCode on construction. This is by design: providers may not be
available on all machines, so a hard-coded preference would break.
"""
function switch_provider!(model::ChatModel, new_provider::BinAgent)
    s = shared(model)
    s.provider[] = new_provider
    # Drop the previous provider's session config (model/mode pills) right away:
    # otherwise the header keeps showing e.g. Claude's model list while we bring
    # up MiMo, which reads as "switched, but the model picker is still Claude's".
    # `start_chat_client!` repopulates it from the new session's config.
    s.session_meta[] = Any[]

    # Every chat's agent is a `WorkerAgent`: keep the worker wiring, change only
    # WHICH provider it spawns. A switch must start a FRESH session:
    # `resume_session_id` is the OLD provider's session id (e.g. a
    # claude-agent-acp UUID). Asking MiMo to `session/load` a session it never
    # created errors ("Internal error") and the restart fails — leaving the chat
    # dead with no model picker. Clearing it routes start! through `session/new`;
    # the chat's history is fed forward to the new agent as a one-shot prelude
    # (see `arm_history_replay!` in start_chat_client!).
    old = s.agent::WorkerAgent
    old.provider = new_provider
    old.resume_session_id = nothing

    # Restart the session with the new provider
    restart_chat_session!(model)
    return nothing
end

# Icons live as standalone SVG files under assets/icons/ and ship as
# Bonito.Asset (hashed URL, served by the same machinery as bonitoagents.js).
# Colors are baked into the SVGs since <img> doesn't inherit currentColor.
send_icon() = bonito_asset("icons", "send.svg")
stop_icon() = bonito_asset("icons", "stop.svg")
icon_img(asset, alt) = DOM.img(src=asset, alt=alt, draggable="false",
    style=Styles("pointer-events" => "none",
        "user-select" => "none"))

function chat_input_area(::Session, ::ChatModel)
    # Pure DOM. The input widgets are entirely JS-owned: `BonitoChat`
    # (assets/bonitoagents.js → `_setupInputs`) attaches capture-phase
    # click + Enter listeners, reads the textarea on submit, posts a
    # `{type: 'send', text, attachments}` event over `comm`, and clears
    # the textarea locally. The stop button posts `{type: 'cancel'}`.
    # On the Julia side, those land as `SendCommand` / `CancelCommand`
    # in `chat_dispatch!` — there's no Observable round-trip for the
    # textarea value or for clearing it, which removes a whole class of
    # echo-bug ("server-echoed stale value overwrites user keystroke").
    text_input = DOM.textarea(
        placeholder="Message…",
        title="Enter to send  ·  Shift+Enter for newline",
        class="bt-text-input", rows=1,
        oninput=js"""event => {
            event.target.style.height = 'auto';
            event.target.style.height = Math.min(event.target.scrollHeight, 120) + 'px';
        }""")
    send_btn = DOM.button(icon_img(send_icon(), "Send"); type="button",
        class="bt-send-btn", title="Send (Enter)")
    stop_btn = DOM.button(icon_img(stop_icon(), "Stop"); type="button",
        class="bt-stop-btn", title="Stop generation")
    DOM.div(DOM.div(text_input, send_btn, stop_btn, class="bt-input-row");
        class="bt-input-area")
end

# JS counterpart. `connect(node, comm)` is called by the inline init JS in
# `jsrender(::ChatModel)` below — same pattern as BonitoBook's MonacoEditor.
const ChatLib = Bonito.ES6Module(joinpath(@__DIR__, "..", "assets", "bonitoagents.js"))

# ── Image attachments ─────────────────────────────────────────────────────
# The JS input area collects pasted / dropped images locally and ships them
# as a base64 + mime payload in the "send" comm event. This helper saves
# each one to `<cwd>/.bt-attachments/<ts>-<short>.<ext>` so:
#   1. The bubble's UserMsg text carries a `[attached: …]` reference that
#      survives chat.md replay (claude can `Read` the file on resume).
#   2. The worker mirror has the same file when send_file_to_worker! lands.
#   3. The multimodal blocks let claude see the image *right now* without
#      doing an extra Read tool call.
const ATTACHMENT_DIR_NAME = ".bt-attachments"

# Map mime types to the canonical file extension we save under. Anything
# not in this table is rejected (caller raises) — silently saving foreign
# blobs as `.bin` would surprise users on replay.
const ATTACHMENT_EXTENSIONS = Dict(
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/jpg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
    "image/svg+xml" => "svg",
)

# 5 MB per image. ACP / claude will balk much later than this, but we want
# a clear error path before we burn bandwidth sending bytes downstream.
const ATTACHMENT_MAX_BYTES = 5 * 1024 * 1024

function attachment_ext(mime::AbstractString)
    ext = get(ATTACHMENT_EXTENSIONS, lowercase(String(mime)), nothing)
    ext === nothing || return ext
    allowed = join(sort(collect(keys(ATTACHMENT_EXTENSIONS))), ", ")
    error("Unsupported attachment mime type: $mime (allowed: $allowed)")
end

# Save one attachment to disk under the project's `.bt-attachments/` dir.
# Returns the path RELATIVE to `model.cwd` so it round-trips into the
# UserMsg text as a portable reference. The absolute path is the second
# return value (used by the worker push).
function save_attachment(model::ChatModel,
    mime::AbstractString,
    bytes::AbstractVector{UInt8})
    length(bytes) <= ATTACHMENT_MAX_BYTES ||
        error("Attachment too large: $(length(bytes)) bytes > $(ATTACHMENT_MAX_BYTES)")
    ext = attachment_ext(mime)
    ts = Dates.format(now(UTC), "yyyy-mm-dd_HHMMSS")
    short = string(uuid4())[1:8]
    rel = joinpath(ATTACHMENT_DIR_NAME, "$(ts)_$(short).$(ext)")
    abs = joinpath(model.cwd, rel)
    mkpath(dirname(abs))
    write(abs, bytes)
    return rel, abs
end

# Best-effort push of an attachment from the server mirror to the worker
# mirror. Failure here doesn't abort the send — the file still exists on
# the server, so a subsequent full sync (or move) will replicate it. We
# only push when there's a project bound and the worker is connected.
function push_attachment_to_worker(model::ChatModel, rel_path::AbstractString)
    pid = model.project_id
    isempty(pid) && return
    proj = get(model.state.projects[], pid, nothing)
    proj === nothing && return
    haskey(model.state.worker_control_ws, proj.worker_id) || return
    src = joinpath(model.cwd, rel_path)
    dst = joinpath(proj.worker_path, rel_path)
    try
        send_file_to_worker!(model.state, proj.worker_id, src, dst;
            handoff_timeout=15.0)
    catch e
        @warn "attachment push to worker failed" worker = proj.worker_id rel_path exception = e
    end
    return
end

# Parse JS-side attachment payloads ({mime, data, filename?}) into a
# (display_text_suffix, [ImageAttachment]) pair. `attachments` may be
# empty (no-op). Each entry's base64 `data` field is decoded once.
function process_attachments!(model::ChatModel, attachments)
    attachments isa AbstractVector || return ("", AgentClientProtocol.ImageAttachment[])
    isempty(attachments) && return ("", AgentClientProtocol.ImageAttachment[])

    suffix_lines = String[]
    blocks = AgentClientProtocol.ImageAttachment[]
    for a in attachments
        a isa AbstractDict || continue
        mime = String(get(a, "mime", ""))
        b64 = String(get(a, "data", ""))
        (isempty(mime) || isempty(b64)) && continue
        bytes = Base64.base64decode(b64)
        rel, _ = save_attachment(model, mime, bytes)
        push_attachment_to_worker(model, rel)
        push!(blocks, AgentClientProtocol.ImageAttachment(bytes, mime))
        push!(suffix_lines, "  - $(rel)")
    end
    suffix = isempty(suffix_lines) ? "" :
             "\n\n[attached files in this message]\n" * join(suffix_lines, "\n")
    return suffix, blocks
end

# JS-originated commands sent over the `comm` Observable, modelled as a
# sum type so each command kind is parsed once and routed via dispatch.
# Adding a new JS command = add a struct + a `parse_chat_command` arm +
# a `handle_command!` method. No further branching in the entry point.
abstract type ChatCommand end

# Wire `{type: "init"}` — browser is fresh and asks for the current
# message count to bootstrap virtual scroll.
struct InitCommand <: ChatCommand end

# Lens search (see lens.jl). The query is parsed + applied server-side over
# the full msgs_store; the result is the set of visible indices + actions.
struct LensQueryCommand <: ChatCommand;  query::String;  end
struct LensSaveCommand   <: ChatCommand;  query::String;  end
struct LensDeleteCommand <: ChatCommand;  query::String;  end

# Wire `{type: "msgs.request", range: [s, e]}` — JS virtual-scroll wants
# messages [s..e] (zero-based, inclusive) for the visible window.
struct MsgsRequestCommand <: ChatCommand
    s::Int
    e::Int
end

# Wire `{type: "tool.render", id: <tool_id>}` — user expanded the tool
# row; Julia mounts the rich body (Monaco / DiffEditor) via `dom_in_js`.
struct ToolRenderCommand <: ChatCommand
    tool_id::String
end

# Wire `{type: "thought.render", id: <thought_id>}` — same shape for the
# lazy-loaded thought body.
struct ThoughtRenderCommand <: ChatCommand
    thought_id::String
end

# Wire `{type: "send", text, attachments: [...]}` — user submitted a
# message (possibly with image attachments). `attachments` is the raw
# list of `{mime, data, ...}` dicts shipped by JS.
struct SendCommand <: ChatCommand
    text::String
    attachments::Vector{Any}
end

# Wire `{type: "cancel"}` — user clicked stop. Cancels the active ACP
# turn (notification, non-blocking).
# `seq` scopes the cancel to the turn the user was LOOKING AT when they
# clicked (the client echoes the last `turn_begin` it saw). A stale click —
# buffered behind a turn that has since finished — must not murder the next
# turn (observed in a real session: stop-clicks on a desynced UI cancelled
# three consecutive fresh prompts within one frame each). `-1` ⇒ unscoped.
struct CancelCommand <: ChatCommand
    seq::Int
end
CancelCommand() = CancelCommand(-1)

# Wire `{type: "stop_tool", id: "<tool_id>"}` — user clicked the ⊗ on a
# taskbar slot. Background bash / Task run on the worker outside of any
# ACP-defined cancel primitive (the SDK doesn't surface a KillShell tool;
# only `TaskStop` exists). The handler routes per concrete `ToolMsg`
# subtype — see `request_tool_stop!` below for the per-variant strategy.
struct StopToolCommand <: ChatCommand
    tool_id::String
end

# Wire `{type: "permission_answer", key, optionId}` — user clicked a choice
# button on a permission/question card. Resolves the matching pending
# `session/request_permission` (see `handle_permission_request`).
struct PermissionAnswerCommand <: ChatCommand
    key::String
    option_id::String
end

# Wire `{type: "question_answer", key, content}` / `{type: "question_skip",
# key}` — user answered (or skipped) a form-elicitation question card.
struct QuestionAnswerCommand <: ChatCommand
    key::String
    content::Dict{String,Any}
end
struct QuestionSkipCommand <: ChatCommand
    key::String
end

# Wire `{type: "edit_file", id: <tool_id>}` or `{type: "edit_file",
# path: <file>}` — user clicked a file-path link (tool title, diff header,
# search hit, a path in an agent message). Opens the file in the plotpane
# Monaco editor. The id form re-derives the path from the tool's stored
# arguments/content; the path form opens directly.
struct EditFileCommand <: ChatCommand
    tool_id::String
    path::String
end
EditFileCommand(tool_id) = EditFileCommand(tool_id, "")

# Wire `{type: "detach_app", id: <tool_id>}` — ⤢ on a bonito_app pill. Routed
# to the window's PlotPane (`pane.detach_app`); the PopupController moves the
# embed DOM to its remembered surface.
struct DetachAppCommand <: ChatCommand
    tool_id::String
end

# Used when `msg` doesn't match any known shape — handler is a no-op.
# Lets `chat_dispatch!` stay total without `return` plumbing.
struct UnknownCommand <: ChatCommand end

function parse_chat_command(msg::AbstractDict)::ChatCommand
    type = String(get(msg, "type", ""))
    if type == "init"
        return InitCommand()
    elseif type == "msgs.request"
        rng = get(msg, "range", nothing)
        rng isa AbstractVector && length(rng) == 2 || return UnknownCommand()
        return MsgsRequestCommand(Int(rng[1]), Int(rng[2]))
    elseif type == "tool.render"
        return ToolRenderCommand(String(get(msg, "id", "")))
    elseif type == "thought.render"
        return ThoughtRenderCommand(String(get(msg, "id", "")))
    elseif type == "send"
        atts = get(msg, "attachments", Any[])
        return SendCommand(String(get(msg, "text", "")),
            atts isa AbstractVector ? collect(atts) : Any[])
    elseif type == "cancel"
        return CancelCommand(Int(get(msg, "seq", -1)))
    elseif type == "stop_tool"
        id = String(get(msg, "id", ""))
        return isempty(id) ? UnknownCommand() : StopToolCommand(id)
    elseif type == "permission_answer"
        key = String(get(msg, "key", ""))
        oid = String(get(msg, "optionId", ""))
        return (isempty(key) || isempty(oid)) ? UnknownCommand() :
               PermissionAnswerCommand(key, oid)
    elseif type == "question_answer"
        key = String(get(msg, "key", ""))
        content = get(msg, "content", nothing)
        (isempty(key) || !(content isa AbstractDict)) && return UnknownCommand()
        return QuestionAnswerCommand(key,
            Dict{String,Any}(String(k) => v for (k, v) in content))
    elseif type == "question_skip"
        key = String(get(msg, "key", ""))
        return isempty(key) ? UnknownCommand() : QuestionSkipCommand(key)
    elseif type == "edit_file"
        id   = String(get(msg, "id", ""))
        path = String(get(msg, "path", ""))
        return (isempty(id) && isempty(path)) ? UnknownCommand() :
               EditFileCommand(id, path)
    elseif type == "detach_app"
        id = String(get(msg, "id", ""))
        return isempty(id) ? UnknownCommand() : DetachAppCommand(id)
    elseif type == "lens.query"
        return LensQueryCommand(String(get(msg, "q", "")))
    elseif type == "lens.save"
        q = String(get(msg, "q", ""))
        return isempty(strip(q)) ? UnknownCommand() : LensSaveCommand(q)
    elseif type == "lens.delete"
        q = String(get(msg, "q", ""))
        return isempty(strip(q)) ? UnknownCommand() : LensDeleteCommand(q)
    end
    return UnknownCommand()
end

# One `handle_command!` method per concrete `ChatCommand` subtype. The
# `session` argument is needed for `dom_in_js` (tool body rendering); the
# other handlers ignore it but take it uniformly so the dispatch shape
# stays predictable.

handle_command!(::ChatModel, ::Session, ::UnknownCommand) = nothing

# (The TaskBar needs no init handshake: it's an Observable component — a
# tab joining mid-turn renders the current pin-board state on mount.)
function handle_command!(model::ChatModel, ::Session, ::InitCommand)
    chat_emit(model, Dict{String,Any}(
        "type" => "msgs.count", "n" => length(model.msgs_store)))
    # Seed the lens UI: the chat-derived autocomplete vocabulary + the global
    # saved lenses. Broadcasts are fine — every tab of this chat shares the
    # same vocabulary, and saved lenses are global favorites.
    emit_lens_vocab(model)
    emit_saved_lenses(model, load_saved_lenses())
    return nothing
end

# (Lens search wiring — emit_lens_vocab / emit_saved_lenses and the
#  Lens*Command handlers — lives in lens.jl, included after this file so the
#  `SavedLens` type is defined.)

function handle_command!(model::ChatModel, ::Session, cmd::MsgsRequestCommand)
    # Snapshot the requested slice under `model.lock` — the single `run_chat!`
    # consumer `push!`es to `msgs_store` on another task, and reading it
    # concurrently (Vector regrow) is the data race the lock exists for (T8).
    # We render `msg_to_dict` OUTSIDE the lock (it can touch disk).
    batch = lock(model.lock) do
        store = model.msgs_store
        n = length(store)
        # Empty store: clamp(x, 0, -1) inverts the bounds and `store[0:0]`
        # throws — a stale request right after a reset must be a no-op.
        n == 0 && return nothing
        s = clamp(cmd.s, 0, n - 1)
        e = clamp(cmd.e, 0, n - 1)
        s > e && return nothing
        (s, store[(s+1):(e+1)])
    end
    batch === nothing && return nothing
    s, slice = batch
    msgs = [msg_to_dict(m, model.chat_dir) for m in slice]
    chat_emit(model, Dict{String,Any}(
        "type" => "msgs.range", "start" => s, "msgs" => msgs))
    return nothing
end

function handle_command!(model::ChatModel, session::Session, cmd::ToolRenderCommand)
    isempty(cmd.tool_id) && return nothing
    # Find + grab the ToolMsg under `model.lock` (T8): `findfirst` over
    # `msgs_store` races the consumer's `push!`. The msg object itself is then
    # rendered off-lock below.
    msg = lock(model.lock) do
        idx = findfirst(m -> m isa ToolMsg && m.id == cmd.tool_id, model.msgs_store)
        idx === nothing ? nothing : model.msgs_store[idx]
    end
    msg === nothing && return nothing
    # Run the render OFF the comm task. `render_tool_body` for a `bonito_app`
    # ToolMsg mounts a `RemoteAppPlaceholder` whose `jsrender` calls
    # `embed_remote_app` → `call_ctrl(eb, "delegate")`, which blocks up to 30 s
    # on the worker bridge. If we ran it inline, that 30 s would stop EVERY
    # other chat event for this tab (scroll fetches, sends, tab switches) until
    # the timeout — multiple stuck tools compound to minutes of frozen UI.
    #
    # Each render is fire-and-forget — no return value the comm handler needs.
    # Concurrent renders are safe: `call_ctrl` uses per-request channels +
    # serial WS writes under `eb.wlock`, and `dom_in_js` opens its own
    # subsession per call. The catch keeps a stale tool id / dead bridge from
    # leaking out as an uncaught task error.
    Base.errormonitor(@async try
        body = render_tool_body(model.state, msg,
            model.cwd, model.chat_dir; project_id=model.project_id)
        # `toolSlot` (a ChatLib module export — no window.* global) also
        # finds slots on nodes the virtual scroll holds DETACHED (cache
        # window / prefetch) — a plain document.querySelector misses those
        # and the body would be stuck on "loading…".
        Bonito.dom_in_js(
            session,
            body,
            js"""(elem) => {
    $(ChatLib).then(lib => {
        const slot = lib.toolSlot($(cmd.tool_id));
        if (slot) { slot.innerHTML = ''; slot.appendChild(elem); }
    });
}"""
        )
    catch e
        @warn "tool render failed" tool_id = cmd.tool_id exception = e
        # Replace the stale "loading…" with a visible failure so the user knows
        # the body is gone (typically: the eval bridge was rebuilt since this
        # turn, so the `shown_app:` id is no longer registered on the worker).
        # We `dom_in_js` a tiny static node — no RemoteAppPlaceholder, no
        # control round-trip, can't repeat the failure.
        try
            Bonito.dom_in_js(
                session,
                DOM.div("tool body unavailable: $(sprint(showerror, e))";
                        class = "bt-tool-error"),
                js"""(elem) => {
    $(ChatLib).then(lib => {
        const slot = lib.toolSlot($(cmd.tool_id));
        if (slot) { slot.innerHTML = ''; slot.appendChild(elem); }
    });
}""")
        catch fallback_e
            # The fallback render itself failed — almost always the tab's session
            # went away mid-render. Log instead of swallowing (T20); there's no
            # further recovery (the slot is gone with the page).
            @debug "tool render fallback failed (session likely gone)" tool_id = cmd.tool_id exception = fallback_e
        end
    end)
    return nothing
end

function handle_command!(model::ChatModel, ::Session, cmd::ThoughtRenderCommand)
    isempty(cmd.thought_id) && return nothing
    # Read the matching thought's text under `model.lock` (T8) — the lookup +
    # field read race the consumer's `push!`. Render markdown off-lock.
    text = lock(model.lock) do
        idx = findfirst(m -> m isa ThoughtMsg && m.id == cmd.thought_id, model.msgs_store)
        idx === nothing ? nothing : model.msgs_store[idx].text
    end
    text === nothing && return nothing
    # Same renderer as `thought_final` (markdown_html / CommonMark). The
    # stdlib `Markdown.parse` used here before italicized intraword `_` and
    # dropped tables — the body looked different live vs. on reload-expand.
    html = markdown_html(text)
    chat_emit(model, Dict{String,Any}("type" => "thought.body",
        "id" => cmd.thought_id, "html" => html))
    return nothing
end

function handle_command!(model::ChatModel, ::Session, cmd::SendCommand)
    # `process_attachments!` decodes user-supplied base64 and writes files
    # to disk. Any failure (bad mime, oversize image, IO error) becomes an
    # `attach_error` event the JS side shows inline — we deliberately
    # surface the showerror message rather than abort silently.
    suffix, blocks = try
        process_attachments!(model, cmd.attachments)
    catch e
        chat_emit(model, Dict{String,Any}(
            "type" => "attach_error", "error" => sprint(showerror, e)))
        return nothing
    end
    display_text = isempty(strip(cmd.text)) && !isempty(blocks) ?
                   "(image attached)" * suffix :
                   cmd.text * suffix
    # No server-side ack — JS already cleared the input optimistically on
    # submit. Errors (attachment-rejection above, or ACP send failures
    # surfaced by `send_message!`'s downstream code) flow back through
    # their own events.
    send_message!(model, UserMsg(display_text); images=blocks)
    return nothing
end

# A re-cancel only escalates to a force-close after the agent has had a real
# chance to honor the first one. Set well past the worst observed cold-start
# honor latency (warm ≈ 0.1s, cold-fresh ≈ 3.9s, cold-resumed ≈ 6–18s) so an
# impatient double-click never force-closes a turn that's about to honor.
const CANCEL_ESCALATE_WAIT = 20.0

function handle_command!(model::ChatModel, ::Any, cmd::CancelCommand)
    # Off-band, instant: cancel is a lone ACP notification, not a chat-state
    # mutation, so it never goes through the `run_chat!` consumer. Reading
    # `client(model.agent)` is a single-field read. (Session arg is unused here —
    # typed `::Any` so the cancel path is unit-testable without a Bonito.Session.)
    c = client(model.agent)
    c === nothing && return nothing
    s = shared(model)
    # Turn-scoped: a cancel aimed at a turn that already ended is DROPPED —
    # it must not kill whatever turn happens to be running now.
    if cmd.seq >= 0 && cmd.seq != s.turn_seq[]
        @debug "dropping stale cancel" clicked_turn = cmd.seq current = s.turn_seq[]
        return nothing
    end

    # A graceful `session/cancel` makes ACP close the active turn's update
    # channel; the `prompt!` loop ends, `run_turn!`'s `finally` clears
    # `busy_active`, and the partial bubble is sealed. We do NOT force-close on a
    # timer: the agent's honor latency is large + unbounded on a cold/resumed turn,
    # so a timer races it, and a premature mid-turn teardown leaves an orphaned
    # tool_use that wedges every future resume (a doom loop). A clean cancel always
    # honors eventually.
    #
    # The hammer is reserved for a genuinely-wedged agent (resumed onto an
    # already-orphaned tool call, ignores cancel, connection still alive so no
    # `ConnectionClosed` fires) — and it's the USER's call: cancel AGAIN, after the
    # agent's had a real chance (≥ CANCEL_ESCALATE_WAIT) and it's STILL busy. That
    # distinguishes a deliberate "force it" from both an impatient double-click
    # (< the wait → graceful re-send) and a slow-but-honoring cold cancel.
    now      = time()
    first_at = (@atomic c.conn.cancel_at)              # 0.0 ⇒ first cancel this turn
    escalate = first_at > 0 && (now - first_at) ≥ CANCEL_ESCALATE_WAIT && s.busy_active[]
    first_at > 0 || (@atomic c.conn.cancel_at = now)   # stamp the first cancel
    AgentClientProtocol.cancel!(c)                      # graceful (idempotent re-send)
    if escalate
        @warn "deliberate re-cancel: agent not honoring — force-closing" project_id = model.project_id
        s.last_error[] = "The agent didn't respond to cancel; session stopped. Click Restart to reconnect."
        try
            close(c)
        catch e
            @warn "force-close after cancel failed" exception = e
        end
    end
    return nothing
end

# ── Stop background tool ───────────────────────────────────────────────────
# Find the tool by id, then dispatch on its concrete subtype so each tool
# family decides its own honest stop strategy. We deliberately don't fake
# anything: the SDK has no `KillShell`, only `TaskStop` for subagents and
# `BashOutput` polling for background bashes. So we route a synthetic user
# message asking Claude to stop the thing — visible in the chat history,
# honest about what the agent is being asked to do. The slot keeps pulsing
# until the actual tool transitions to terminal status (no fake "Stopping…"
# state that might never resolve).
# Resolve a pending permission/question request with the clicked option.
# `put!` on a capacity-1 channel a blocked `handle_permission_request` owns;
# a second click (another tab, double-click) finds the key gone — no-op.
# Deliver the answer to the request's reply channel on the SHARED model. The ask
# lives on `model.pending_asks` (an entry is `(channel, teardown-default)`), so a
# resolve is "pop my own dict + put!". A second click (another tab, double-click)
# finds the key gone — no-op.
function resolve_pending_ask!(model::ChatModel, key::AbstractString, value)
    s = shared(model)
    entry = lock(s.lock) do
        pop!(s.pending_asks, String(key), nothing)
    end
    entry === nothing && return nothing
    try
        put!(entry[1], value)
    catch e
        e isa InvalidStateException || rethrow()
    end
    return nothing
end
handle_command!(model::ChatModel, ::Any, cmd::PermissionAnswerCommand) =
    resolve_pending_ask!(model, cmd.key, cmd.option_id)
handle_command!(model::ChatModel, ::Any, cmd::QuestionAnswerCommand) =
    resolve_pending_ask!(model, cmd.key, cmd.content)
handle_command!(model::ChatModel, ::Any, cmd::QuestionSkipCommand) =
    resolve_pending_ask!(model, cmd.key, :skip)

function handle_command!(model::ChatModel, ::Any, cmd::StopToolCommand)
    isempty(cmd.tool_id) && return nothing
    target = lock(model.lock) do
        idx = findfirst(m -> m isa ToolMsg && m.id == cmd.tool_id, model.msgs_store)
        idx === nothing ? nothing : model.msgs_store[idx]
    end
    target === nothing && return nothing
    request_tool_stop!(model, target)
    return nothing
end

# Per-variant: each tool kind we surface in the taskbar gets its own arm.
# The default (`::ToolMsg`) is a no-op — we'd never have shown a slot for a
# one-shot tool, so a stop click on it is the user clicking a transient UI
# affordance after the tool already finished. Silent ignore is correct.
request_tool_stop!(::ChatModel, ::ToolMsg) = nothing

# Background bash: a DIRECT stop, never a chat message. claude-agent-acp
# completes the tool_call at LAUNCH and delivers the real exit as a separate
# task-notification (a new assistant turn) — it never sends a terminal
# tool_call_update on this tool id, and the SDK exposes no ACP kill. So:
#   1. SIGTERM the shell ourselves — it holds its `>> output` redirect fd
#      open until it exits, so the writers of `bg_output_path` ARE the shell
#      (worker-side `kill_file_writers`; the worker runs locally in dev too).
#   2. Finalize the pill immediately. The user asked to stop and we issued
#      the kill — the UI must reflect that deterministically, not wait on a
#      file-quiesce signal the script can defeat by redirecting elsewhere
#      (the exact "pill stuck in_progress forever" bug).
# Idempotent: a second click on an already-finalized pill is a no-op.
function request_tool_stop!(model::ChatModel, t::BashToolMsg)
    (t.is_background && t.bg_running) || return nothing
    wid = bg_worker_id(model.state, model)
    if wid !== nothing && !isempty(t.bg_output_path)
        try
            r = kill_worker_file_writers(model.state, wid, t.bg_output_path)
            @info "stop bg bash" tool_id = t.id killed = r.killed supported = r.supported
        catch e
            @warn "kill_file_writers failed; finalizing pill anyway" tool_id = t.id exception = e
        end
    end
    finalize_bg_task!(model, t)
    return nothing
end

# Background subagent Task: same story (no ACP kill, completion via
# task-notification). We can't fd-target a subagent, so the honest action is
# to finalize the pill — the user sees it stop, and the subagent's eventual
# task-notification lands as its own turn.
function request_tool_stop!(model::ChatModel, t::TaskToolMsg)
    (t.is_background && is_live(t)) || return nothing
    close(t)
    unpin_task!(model, t.id)
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => t.id,
        "status" => "completed", "summary" => "stopped"))
    return nothing
end

# Eval family (bt_julia_eval / bt_julia_continue): a REAL interrupt, not a
# synthetic chat message. The project's BonitoMCP process holds a control
# channel back to this server (see `interrupt_project_eval!`); over it we
# SIGINT exactly the eval session this call runs in. The agent's pending
# checkpoint then returns the InterruptException blocks and the TURN KEEPS
# GOING — the agent sees the interrupt as a tool result and reacts to it,
# unlike the chat-level cancel which kills the whole turn.
function request_tool_stop!(model::ChatModel, t::MCPToolMsg)
    t.tool_name in EVAL_STOPPABLE_TOOLS || return nothing
    is_live(t) || return nothing
    env_raw  = get(t.raw_input, "env_path", nothing)
    env_path = env_raw isa AbstractString && !isempty(env_raw) ? String(env_raw) : nothing
    # Immediate visual ack; the result itself arrives with the eval's next
    # checkpoint (tool_update from the agent).
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => t.id,
        "status" => "in_progress", "summary" => "interrupting…"))
    Base.errormonitor(@async try
        n = interrupt_project_eval!(model.state, model.project_id; env_path)
        n == 0 && chat_emit(model, Dict{String,Any}("type" => "tool_update",
            "id" => t.id, "status" => "in_progress",
            "summary" => "nothing in flight to interrupt"))
    catch e
        @warn "eval interrupt failed" tool_id = t.id exception = e
        chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => t.id,
            "status" => "in_progress",
            "summary" => "interrupt failed: $(sprint(showerror, e))"))
    end)
    return nothing
end

# ── Open a tool's file in the plotpane editor ───────────────────────────────
# Resolve the tool's path (Read title / bt_show ref), mirror the file to the
# server (ShowTool fetch path — may block on a worker transfer, so this runs
# off the comm task), then mount a `FileEditor` into the plotpane via
# `dom_in_js` and reveal the pane through the popup controller.
function handle_command!(model::ChatModel, session::Session, cmd::EditFileCommand)
    path = if !isempty(cmd.path)
        # Direct path-link click (diff header, search hit, agent-message
        # path). A trailing `:line` from grep-style hits is display sugar.
        p = replace(String(cmd.path), r":\d+$" => "")
        editor_openable(p) ? p : nothing
    else
        msg = lock(model.lock) do
            idx = findfirst(m -> m isa ToolMsg && m.id == cmd.tool_id, model.msgs_store)
            idx === nothing ? nothing : model.msgs_store[idx]
        end
        msg === nothing && return nothing
        content = tool_content_for_render(msg, model.chat_dir)
        pretty_title, _ = pretty_tool_title(msg.title)
        hd = Dict{String,Any}("kind" => msg.kind, "title" => pretty_title)
        # Live raw_input first; persisted rawInput covers history-reloaded
        # pills whose in-RAM arguments are gone.
        hint = tool_path_hint(msg)
        hint === nothing && (hint = stored_path_hint(model.chat_dir, msg.id))
        hint === nothing || (hd["path_hint"] = hint)
        editable_path_from(hd, content)
    end
    path === nothing && return nothing
    pane = model.plotpane
    if pane === nothing
        @warn "edit_file: no plotpane bound to this chat view (rendered outside the unified shell?)" path
        return nothing
    end
    open_file!(pane, model, path)
end

# Build the FileEditor for `path`: fetch the worker file to the server mirror
# (may block on a transfer, may throw on an error), then construct the editor.
# THROWS on failure — `open_file!` catches and flashes a toast rather than
# leaving an empty/error panel behind (the user clicked a link; a dead panel
# reads as "nothing happened").
file_panel_content(model::ChatModel, path::AbstractString) =
    file_panel_content(model.state, model.project_id, model.cwd, path)

function file_panel_content(state::ServerState, project_id::AbstractString,
                            server_cwd::AbstractString, path::AbstractString)
    st = ShowTool(state, project_id, server_cwd, path)
    server_file = fetch_show_file(st)
    proj = get(state.projects[], project_id, nothing)
    worker_abs = proj === nothing ? "" :
        (isabspath(path) ? String(path) : joinpath(proj.worker_path, path))
    return FileEditor(state, project_id, server_file, worker_abs)
end

# Ask the worker to stat the file BEFORE fetching — return a human-readable
# refusal (shown as a toast) when it isn't an openable text file, else `nothing`.
# Catches the cases that otherwise stream bytes only to show an empty editor: a
# directory, a missing path, a binary/media extension, or a file too big for
# Monaco (we already know the size, so we never fetch it). Parameterized by
# (state, project_id) so the sidebar file-tree shares it without a ChatModel.
open_guard_reject_reason(model::ChatModel, path::AbstractString) =
    open_guard_reject_reason(model.state, model.project_id, path)

function open_guard_reject_reason(state::ServerState, project_id::AbstractString,
                                  path::AbstractString)
    name = basename(String(path))
    editor_openable(path) ||
        return "Can't open $name — not a text file"
    proj = get(state.projects[], project_id, nothing)
    proj === nothing && return nothing      # no worker to stat → let the fetch try
    worker_src = isabspath(path) ? String(path) : joinpath(proj.worker_path, path)
    info = try
        stat_worker_path(state, proj.worker_id, worker_src)
    catch e
        @warn "open-guard stat failed; allowing the fetch to try" path exception = e
        return nothing                      # worker hiccup → don't block; fetch reports
    end
    info.exists || return "Can't open $name — not found on the worker"
    info.isdir  && return "Can't open $name — it's a folder"
    info.isfile || return "Can't open $name — not a regular file"
    info.size > FILE_EDITOR_MAX_BYTES &&
        return "Can't open $name — too large to edit ($(format_bytes(info.size)))"
    return nothing
end

# Short one-line reason for a fetch/build failure toast.
open_error_brief(e) = e isa EOFError ? "couldn't read the file" :
                      first(split(sprint(showerror, e), '\n'))

function handle_command!(model::ChatModel, ::Session, cmd::DetachAppCommand)
    pane = model.plotpane
    if pane === nothing
        @warn "detach_app: no plotpane bound to this chat view" tool_id = cmd.tool_id
        return nothing
    end
    pane.detach_app[] = cmd.tool_id
    return nothing
end

"""
    open_file!(pane::PlotPane, model::ChatModel, path)

Open `path` (a worker-side file path) as a PANEL in the window's
[`Workspace`](@ref BonitoWidgets.Workspace) — an editable Monaco the user can
tab / split / float next to the chat and any other open files. Re-opening a path
activates its existing panel (the editor keeps cursor/scroll/unsaved edits — the
Workspace renders it once and only ever moves its node). Fetches the file to the
server mirror first (from the worker if needed); failures land as an error card
in the panel instead of a silent log line — the user clicked a link and must see
SOMETHING happen.
"""
open_file!(pane::PlotPane, model::ChatModel, path::AbstractString) =
    open_project_file!(pane, model.state, model.project_id, model.cwd, path)

"""
    open_project_file!(pane, state, project_id, server_cwd, path)

Core of [`open_file!`](@ref), parameterized by `(state, project_id, server_cwd)`
instead of a `ChatModel` so the sidebar file-tree can open files even when the
chat's ACP session isn't up. Guards (worker stat) → fetches → adds the panel; a
refusal or fetch failure flashes a toast and opens NO panel.
"""
function open_project_file!(pane::PlotPane, state::ServerState, project_id::AbstractString,
                            server_cwd::AbstractString, path::AbstractString)
    ws = pane.workspace[]
    ws === nothing && return nothing
    id = file_tab_id(path)
    if any(p -> p.id == id, ws.panels[])
        BonitoWidgets.activate_panel!(ws, id)   # already open — focus it
        return nothing
    end
    # Fetch (worker transfer — can take seconds) off the event task, then add the
    # editor as the panel's DIRECT content. NOT via a placeholder + reactive
    # `DOM.div(Observable)` swap: that inserts auto-height `bonito-fragment`
    # wrappers between the panel and `.bt-file-editor`, breaking its `height:100%`
    # chain (Monaco collapses to ~1px). `add_panel!` dedupes by id, so racing
    # re-clicks still land one panel.
    Base.errormonitor(@async begin
        # Pre-fetch guard: a folder / missing / binary / oversize file flashes a
        # toast and opens NO panel, instead of streaming bytes into an empty
        # editor (the worker stat is the gate — see open_guard_reject_reason).
        reason = open_guard_reject_reason(state, project_id, path)
        if reason !== nothing
            show_toast!(pane, reason)
            return
        end
        elem = try
            file_panel_content(state, project_id, server_cwd, path)
        catch e
            @warn "file editor open failed" path exception = e
            show_toast!(pane, "Can't open $(basename(String(path))) — $(open_error_brief(e))")
            return
        end
        BonitoWidgets.add_panel!(ws, BonitoWidgets.Panel(id, elem;
            label = basename(path), closable = true))
    end)
    return nothing
end

# Thin entry point for the per-session `comm` listener wired up in
# `jsrender(::ChatModel)`. Parses once, dispatches once. The
# `session::Session` closure binding flows through unchanged because
# `handle_command!(::Any, ::Any, ::ToolRenderCommand)` needs it for
# `dom_in_js`.
chat_dispatch!(model::ChatModel, session::Session, msg::AbstractDict) =
    handle_command!(model, session, parse_chat_command(msg))

# `ChatModel` is a Bonito component. Per the convention, the shared instance
# (the one in `state.chat_models[pid]`) should never be rendered directly —
# we make a per-session view via `copy(model)` and bind handlers to *that*
# session. The shared bits (msgs_store, ACP client, lock) are still shared
# (sessions cooperate); the Observable `comm` is a connected child so each
# tab's JS bridge GC's cleanly when the tab closes.
function Bonito.jsrender(session::Session, m::ChatModel)
    # `model` is the per-session view: its `comm`, `session_alive`, and
    # `last_error` are connected children of the shared parent's, so the JS
    # bridge stays scoped to this tab. Rendering reads from `model`.
    # Handlers reach the shared parent via `shared(m)` so writes broadcast
    # to every connected tab — see the `parent` field doc on ChatModel.
    # ChatPaneRef hands us an ALREADY-copied view (it attaches the window's
    # plotpane to it); rendering a shared parent directly (tests, ad-hoc
    # display) makes the copy here.
    model = m.parent === nothing ? copy(m, session) : m

    # Single per-session dispatcher. `chat_dispatch!` itself does
    # `shared(m)` for any state-mutating writes, so passing `model` is
    # safe AND gives the handler access to `session` (for `dom_in_js`).
    on(session, model.comm) do msg
        chat_dispatch!(model, session, msg)
    end

    # Spinner class follows the shared busy_active observable so the
    # `bt-busy-active` class is set correctly on remount — the comm
    # `busy_start` / `busy_end` events only forward to FUTURE bridges,
    # so a tab that opens mid-prompt would otherwise miss the start.
    busy_class = map(b -> b ? "bt-busy bt-busy-active" : "bt-busy", model.busy_active)

    # The pin-board (taskbar.jl): renders the Julia-owned item list; its ⊗
    # routes through the same per-tool stop dispatch the old slots used.
    taskbar = TaskBar(model.taskbar_items, model.taskbar_clock)
    on(session, taskbar.stop_request) do id
        isempty(id) || handle_command!(model, session, StopToolCommand(id))
    end

    messages_container = DOM.div(
        DOM.div(class="bt-spacer-top"),
        DOM.div(class="bt-spacer-bottom"),
        # Busy dots + transient "reasoning…" indicator live INSIDE the
        # scroll content, after the bottom spacer (message nodes insert
        # before it) and before the overscroll tail — so they show up
        # directly under the last message, not below the tail's empty
        # space down by the composer. Like the tail, they're plain
        # content the virtual-scroll geometry never tracks.
        DOM.div(DOM.div(class="bt-busy-dot"),
            DOM.div(class="bt-busy-dot"),
            DOM.div(class="bt-busy-dot");
            class=busy_class),
        # Idle indicator — visible when the busy dots are NOT (CSS
        # adjacent-sibling rule on `.bt-busy`, so it MUST stay the dots'
        # immediate next sibling) AND the chat has agent replies on display
        # (`bt-waiting-on`, toggled by `_updateWaiting` in bonitoagents.js).
        # The slot under the last message thus says what the agent is
        # doing: dots/reasoning mid-turn, waiting between turns — and
        # nothing at all in a chat that hasn't been asked anything yet.
        DOM.div("Waiting for your next instruction"; class="bt-waiting"),
        # Transient "reasoning…" indicator (toggled by the `thinking` comm
        # event in bonitoagents.js). Hidden until an agent thought is in flight.
        DOM.div("💭 reasoning…", DOM.span(class="bt-thinking-count"); class="bt-thinking"),
        # Overscroll tail: empty space the user can scroll into below the
        # last message (~30% of the pane; JS sizes it from clientHeight).
        DOM.div(class="bt-messages-tail");
        class="bt-messages")

    init_script = js"""
        $(ChatLib).then(lib => lib.connect($(messages_container), $(model.comm)))
    """

    # Cross-worker sync modal state + apply. `nothing` ⇒ hidden; otherwise
    # `(current, other, comparison)`. `on_apply(src, dst)` runs the
    # directional overwrite in a Task and closes the modal when done.
    sync_modal_state = Observable{Union{Nothing,NamedTuple}}(nothing)
    sync_modal = render_sync_modal(session, model.state, sync_modal_state,
        (src, dst) -> @async begin
            try
                sync_across_workers!(model.state, src, dst)
            catch e
                @warn "cross-worker sync failed" src=src.name dst=dst.name exception=e
            finally
                sync_modal_state[] = nothing
            end
        end)

    Bonito.jsrender(session, DOM.div(
        chat_header(session, model, sync_modal_state),
        sync_modal,
        # The messages area + the taskbar share a positioning context so the
        # taskbar floats over the MESSAGES, anchored below the (variable-
        # height) header instead of on top of it.
        DOM.div(
            messages_container,
            taskbar;
            class = "bt-messages-wrap"),
        init_script,
        chat_input_area(session, model),
        # Toolbar below the composer. Populated entirely client-side by
        # BonitoChat (`noteType`): one show/hide checkbox per message type the
        # first time that type occurs. Sized to host future controls too.
        DOM.div(class = "bt-chat-toolbar"),
        # NOTE: there is deliberately NO mount curtain here. The dashboard's
        # load overlay (`chat_waiting_view`, sidebar.jl) covers this pane
        # from the moment the user clicks until the chat module reports the
        # geometry settled (`bt-chat-settling` / `bt-chat-settled` events
        # from `_startSettle` in bonitoagents.js) — one continuous loading
        # surface instead of the old bring-up pane → bare gap → per-chat
        # curtain relay.
        class="bt-app"))
end
