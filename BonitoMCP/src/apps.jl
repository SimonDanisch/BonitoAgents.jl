"""
    BonitoMCP.Apps

The interface a BonitoAgents App implements. An App is a Julia package that
runs a workflow: plain code for what is deterministic, `agent` calls for what
needs judgment, and a Bonito UI delivered into a chat as a live embed.

An app runs in the chat's **bt_worker** (the eval session that already serves
that chat's `bt_julia_eval`), so its data, its UI and the embed bridge are all
in one process. It composes a chat by `send`ing messages, which is why there is
no separate dashboard channel here.

An app subtypes [`App`](@ref), overrides the declaration methods it cares
about, and implements [`run`](@ref). The server supplies a [`Context`](@ref);
tests supply a [`ReplayContext`](@ref), so an app is exercisable with no
server, no worker, no agent process and no tokens.

See APPS_SPEC.md for the full design.
"""
module Apps

export App, Context, Chat

"""
    App

Supertype for apps. Subtype it, override the declaration methods below, and
implement [`run`](@ref).
"""
abstract type App end

"""
    Context

An app's runtime: config, persisted state, agent access, and the ability to
open chats. It is not itself a chat; an app opens none, one, or many.

`Context` is an interface, so an app can be driven by the live server, by
[`ReplayContext`](@ref) in tests, or by anything else implementing the verbs.
"""
abstract type Context end

"""
    Chat

A handle on one chat the app opened. Fill it with [`send`](@ref); drive a real
agent turn on it with [`ask`](@ref).
"""
abstract type Chat end

"""
    Field(label, default = "")

One entry in an app's launch form. Declared via [`config(::App)`](@ref); the
collected values come back from `config(::Context)`.
"""
struct Field
    label::String
    default::String
end
Field(label::AbstractString) = Field(String(label), "")

# ── What an app declares ─────────────────────────────────────────────────────
# `config` is deliberately one generic with two meanings by argument type:
# `config(app)` is what the app ASKS for, `config(ctx)` is what this run GOT.

name(app::App) = string(nameof(typeof(app)))
description(::App) = ""
icon(::App) = nothing
config(::App) = NamedTuple()

"""
    run(app, ctx, chat)

The workflow. Called once per launch on its own task, in `chat`'s bt_worker.

Running an app IS opening a chat: the launcher creates one and hands it in, so
`run` never has to. [`open_chat`](@ref) is for ADDITIONAL chats only, which
keeps one meaning per verb. A `chat` the app never sends to is discarded when
`run` returns, so a scheduled run with nothing to report leaves no trace and
apps need not declare whether they want a chat.

Cheap by construction: the ACP session (the agent subprocess) binds on the
first TURN, not at chat creation, so a transcript the user never replies to
costs no agent process.

Whatever it returns is kept as the run's result; throwing surfaces the error on
the app's tile and in `chat`.
"""
run(app::App, ::Context, ::Chat) =
    error("$(typeof(app)) does not implement Apps.run(app, ctx, chat)")

# ── Messages an app can put in a chat ────────────────────────────────────────
# Deliberately NOT a user or agent message: the agent reads the transcript, so
# a forged user turn would be prompt injection with extra steps.

abstract type Msg end

"""
    Note(markdown)

An app-authored message. Rendered with a visible app marker, never as the user
or the agent.
"""
struct Note <: Msg
    markdown::String
end
Note(markdown::AbstractString) = Note(String(markdown))

"""
    BtJuliaEval(value; pin = false)

A `bt_julia_eval` bubble whose result is `value`, live. The app runs in the
chat's worker, so `value` is passed as-is: the server parks it with
`RemoteProxy.remote_ref` and the chat mounts it through the same `RemoteRef`
path a real eval result uses. A `Bonito.App` gives an interactive embed;
anything else renders through `jsrender` exactly as an eval result would.

`pin = true` lifts the embed into its own workspace panel, so it stays put
while the conversation scrolls.
"""
struct BtJuliaEval <: Msg
    value::Any
    pin::Bool
end
BtJuliaEval(value; pin::Bool = false) = BtJuliaEval(value, pin)

"""
    Show(path)

A `bt_show` preview of a file on the worker.
"""
struct Show <: Msg
    path::String
end
Show(path::AbstractString) = Show(String(path))

# ── What a context provides ──────────────────────────────────────────────────
# Every verb errors by default, so a new Context that forgets one fails loudly
# instead of silently doing nothing.

"""
    agent(ctx, prompt; schema = nothing, tools = :read_only, label = "")

Run a scoped subagent and return its result. With `schema`, the subagent
answers through a structured-output tool and the parsed value comes back, so
app code gets data rather than prose. `tools` defaults to `:read_only`
because the app's subagents share a working directory with the main chat
agent. `label` names the call in the chat's activity feed, and is the key
[`ReplayContext`](@ref) looks canned replies up by.

Safe to call concurrently: each call is its own agent session.
"""
agent(ctx::Context, prompt::AbstractString; kw...) =
    error("$(typeof(ctx)) does not implement `agent`")

"""
    map_agents(f, ctx, items; limit = 8) -> Vector

`f` over `items` with up to `limit` subagent calls in flight. The cap matters:
every call is a separate agent session with its own context and its own cost.
"""
map_agents(f, ::Context, items; limit::Int = 8) =
    asyncmap(f, items; ntasks = limit)

"""
    open_chat(ctx; title = "", github = nothing, path = nothing, prompt = "")

Open an ADDITIONAL chat and return a handle — the app's own chat arrives as
`run`'s third argument. A `github` issue or PR URL clones the repo, checks out
the PR head, and seeds the description as the first prompt.
"""
open_chat(ctx::Context; kw...) =
    error("$(typeof(ctx)) does not implement `open_chat`")

"""
    config(ctx) -> NamedTuple

The values the launcher collected for the fields this app declared.
"""
config(ctx::Context) =
    error("$(typeof(ctx)) does not implement `config`")

"""
    state(ctx) -> AbstractDict
    state!(ctx, key, value)

Small persisted key/value store scoped to this app. Survives between runs,
which is how a daily app remembers where it left off.
"""
state(ctx::Context) =
    error("$(typeof(ctx)) does not implement `state`")

state!(ctx::Context, key::AbstractString, value) =
    error("$(typeof(ctx)) does not implement `state!`")

# ── What a chat provides ─────────────────────────────────────────────────────

"""
    agent_text(msg) -> Union{String,Nothing}

What `msg` tells the agent by default. A [`Note`](@ref) is its own summary;
everything else says nothing unless the app passes `to_agent` explicitly, since
there is no useful generic summary of a `Bonito.App`.
"""
agent_text(msg::Note) = msg.markdown
agent_text(::Msg) = nothing

"""
    send(chat, msg; to_agent = agent_text(msg))

Append `msg` to the chat's transcript.

`to_agent` is what the AGENT is told, which is not what the transcript shows:
app messages are injected server-side and never pass through the ACP session,
so without this the agent does not know they happened. The text rides on the
next prompt inside a `<bt-app>` block, the same tagged-block convention Claude
Code uses for its own injected context. `nothing` means display-only.

The app writes this line itself because it knows what matters about its own
output.

SECURITY: the block sits in a user turn, which the agent trusts. Author this
text; never paste fetched third-party content (issue bodies, web pages) into it
unfenced.
"""
send(chat::Chat, msg::Msg; to_agent::Union{AbstractString,Nothing} = agent_text(msg)) =
    error("$(typeof(chat)) does not implement `send`")

"""
    ask(chat, prompt; label = "") -> String

Run a real agent turn on `chat` and return the reply. Blocking, and it appears
in the transcript as an ordinary turn, unlike [`agent`](@ref) which is a scoped
side call.
"""
ask(chat::Chat, prompt::AbstractString; kw...) =
    error("$(typeof(chat)) does not implement `ask`")

Base.close(chat::Chat) = error("$(typeof(chat)) does not implement `close`")

# ── ReplayContext ────────────────────────────────────────────────────────────

"""
    ReplayContext(; replies, config, state)

A `Context` that replays canned agent answers instead of calling a real agent,
and records every verb an app invokes. This is how apps are tested: no server,
no worker, no agent process, no tokens.

`replies` maps a `label` to the value `agent` (or `ask`) should return for it.
A call whose label has no canned reply throws, so a test can never silently
pass on a path it did not script.

Inspect a finished run with [`calls`](@ref), [`chats`](@ref) and
[`sent`](@ref). For behaviour a script cannot express, subtype `Context`
directly and implement the verbs.
"""
struct ReplayContext <: Context
    lock::ReentrantLock
    replies::Dict{String,Any}
    values::NamedTuple
    store::Dict{String,Any}
    calls::Vector{Pair{Symbol,Any}}
    chats::Vector{Chat}
end

function ReplayContext(; replies = Dict{String,Any}(),
                         config = NamedTuple(),
                         state = Dict{String,Any}())
    return ReplayContext(ReentrantLock(),
                         Dict{String,Any}(replies), config,
                         Dict{String,Any}(state),
                         Pair{Symbol,Any}[], Chat[])
end

"""
    ReplayChat

The [`Chat`](@ref) a [`ReplayContext`](@ref) hands back: it records what was
sent instead of talking to a server.
"""
struct ReplayChat <: Chat
    ctx::ReplayContext
    title::String
    opts::Dict{Symbol,Any}
    messages::Vector{Msg}
    open::Base.RefValue{Bool}
end

record!(ctx::ReplayContext, verb::Symbol, payload) =
    lock(() -> push!(ctx.calls, verb => payload), ctx.lock)

"""
    calls(ctx) -> Vector{Pair{Symbol,Any}}

Every verb the app invoked, in order. `asyncmap` interleaves concurrent
`agent` calls, so assert on membership and counts rather than on the exact
ordering of a fan-out.
"""
calls(ctx::ReplayContext) = lock(() -> copy(ctx.calls), ctx.lock)

"""
    chats(ctx) -> Vector{Chat}

Every chat the app opened, in order.
"""
chats(ctx::ReplayContext) = lock(() -> copy(ctx.chats), ctx.lock)

"""
    sent(chat) -> Vector{Msg}

Every message the app put in `chat`, in order.
"""
sent(chat::ReplayChat) = lock(() -> copy(chat.messages), chat.ctx.lock)

function canned(ctx::ReplayContext, verb::AbstractString, label::AbstractString)
    key = String(label)
    haskey(ctx.replies, key) || error(
        "ReplayContext: no canned reply for $verb label $(repr(key)). " *
        "Scripted labels: $(sort!(collect(keys(ctx.replies))))")
    return ctx.replies[key]
end

function agent(ctx::ReplayContext, prompt::AbstractString;
               schema = nothing, tools = :read_only, label::AbstractString = "")
    record!(ctx, :agent, (; label = String(label), prompt = String(prompt),
                            schema, tools))
    return canned(ctx, "agent", label)
end

function open_chat(ctx::ReplayContext; title::AbstractString = "", kw...)
    chat = ReplayChat(ctx, String(title), Dict{Symbol,Any}(kw), Msg[],
                      Base.RefValue(true))
    lock(ctx.lock) do
        push!(ctx.calls, :open_chat => (; title = String(title), kw...))
        push!(ctx.chats, chat)
    end
    return chat
end

"""
    run(app, ctx; title = "") -> (result, chat)

Drive a whole run against a [`ReplayContext`](@ref) the way the launcher does:
open the app's chat, hand it to [`run`](@ref), and give both back. Mirrors the
real bring-up so a test never has to reproduce it by hand.
"""
function run(app::App, ctx::ReplayContext; title::AbstractString = "")
    chat = open_chat(ctx; title = title)
    return run(app, ctx, chat), chat
end

config(ctx::ReplayContext) = ctx.values

state(ctx::ReplayContext) = lock(() -> copy(ctx.store), ctx.lock)

state!(ctx::ReplayContext, key::AbstractString, value) =
    lock(ctx.lock) do
        push!(ctx.calls, :state! => (String(key) => value))
        ctx.store[String(key)] = value
    end

function send(chat::ReplayChat, msg::Msg;
              to_agent::Union{AbstractString,Nothing} = agent_text(msg))
    chat.open[] || error("send on a closed ReplayChat")
    lock(chat.ctx.lock) do
        push!(chat.ctx.calls, :send => (; msg, to_agent))
        push!(chat.messages, msg)
    end
    return msg
end

function ask(chat::ReplayChat, prompt::AbstractString; label::AbstractString = "")
    chat.open[] || error("ask on a closed ReplayChat")
    record!(chat.ctx, :ask, (; label = String(label), prompt = String(prompt)))
    return canned(chat.ctx, "ask", label)
end

Base.close(chat::ReplayChat) = (chat.open[] = false; nothing)

end # module Apps
