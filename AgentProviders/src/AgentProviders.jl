module AgentProviders

# The SINGLE source of truth for "what is agent provider X" — how to spawn it
# (bin/args/env) and how to show it (label/icon) — shared by BOTH the server
# (BonitoAgents) and the worker (BonitoWorker), so a provider is defined in
# exactly one place and the two sides can't drift.
#
# A provider is an immutable value DESCRIPTOR (plain struct + multiple dispatch,
# NOT a class with methods-as-fields). It carries no live session state: every
# chat runs behind a `WorkerAgent` (defined in BonitoAgents) that the worker
# spawns from a descriptor's `bin`/`args`/`env`. `current_providers()` is the one
# menu list (the mock is included only when its env var is set), read once and
# memoised. `find_provider(name)` maps the wire name back to its singleton.

export AgentProvider, BinAgent
export ClaudeCodeAgent, MiMoAgent, OpenCodeAgent, MockAgent, MockAgent2
export provider_name, label, icon, resumable_session
export current_providers, find_provider, refresh_providers!

# `WorkerAgent` (BonitoAgents) also subtypes `AgentProvider`; the worker-spawned
# binary providers are `BinAgent`s.
abstract type AgentProvider end
abstract type BinAgent <: AgentProvider end

# ── bin resolvers (env override → PATH → well-known path → bare name) ─────────
# Plain functions, run wherever the descriptor is constructed — so `Sys.which`
# resolves on the host that owns the binary (the worker, when the worker builds
# the descriptor).
function claude_bin()
    e = get(ENV, "CLAUDE_AGENT_ACP", ""); isempty(e) || return e
    b = Sys.which("claude-agent-acp"); b === nothing ? "claude-agent-acp" : b
end
function mimo_bin()
    e = get(ENV, "MIMO_AGENT_ACP", ""); isempty(e) || return e
    b = Sys.which("mimo"); b !== nothing && return b
    p = joinpath(homedir(), ".mimocode", "bin", "mimo"); isfile(p) ? p : "mimo"
end
function opencode_bin()
    e = get(ENV, "OPENCODE_AGENT_ACP", ""); isempty(e) || return e
    b = Sys.which("opencode"); b !== nothing && return b
    p = joinpath(homedir(), ".opencode", "bin", "opencode"); isfile(p) ? p : "opencode"
end
# The mock runs as a Julia application: `julia --project=<env> -m MockACP`. The
# test harness sets `BT_MOCK_PROJECT` to the env where MockACP is resolvable (the
# BonitoAgents test env). `MOCK_AGENT_ACP` can override the whole bin for ad-hoc
# use. Launched via the descriptor's bin+args like any other provider — no wrapper.
_julia_exe() = joinpath(Sys.BINDIR, Base.julia_exename())

function mock_bin_args()
    override = get(ENV, "MOCK_AGENT_ACP", "")
    isempty(override) || return (override, String[])
    proj = get(ENV, "BT_MOCK_PROJECT", Base.active_project())
    return (_julia_exe(),
            ["--startup-file=no", "--color=no", "--history-file=no",
             "--project=$(proj)", "-m", "MockACP"])
end

# ── Descriptors ──────────────────────────────────────────────────────────────
# Fields: spawn data only. `env` holds the PROVIDER-SPECIFIC extras (e.g.
# `CLAUDE_*`), NOT a snapshot of the whole process ENV — the worker merges live
# ENV on top at spawn time. Immutable: these are singletons (see
# `current_providers`), one per provider for the whole process.

struct ClaudeCodeAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
end
ClaudeCodeAgent() = ClaudeCodeAgent(claude_bin(), String[],
    Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions", "CLAUDE_MAX_TURNS" => "100"),
    Dict{String,Any}("form" => true))

struct MiMoAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
end
# `mimo`/`opencode` are multi-command CLIs whose ACP server lives under the `acp`
# subcommand; the bare binary launches their TUI and never speaks ACP.
MiMoAgent() = MiMoAgent(mimo_bin(), ["acp"], Dict{String,String}(),
    Dict{String,Any}("form" => true))

struct OpenCodeAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
end
OpenCodeAgent() = OpenCodeAgent(opencode_bin(), ["acp"], Dict{String,String}(),
    Dict{String,Any}("form" => Dict{String,Any}()))

struct MockAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
end
function MockAgent()
    bin, args = mock_bin_args()
    # No baked scenario env: the scenario (and dispatcher coords) are RUNTIME
    # config the spawner provides via the inherited ENV. Baking it here would
    # override what the test harness set (the worker merges provider.env OVER the
    # inherited ENV). MockACP defaults to "normal" internally when unset.
    MockAgent(bin, args, Dict{String,String}(), Dict{String,Any}("form" => true))
end

# A SECOND mock backend, identical to `MockAgent` but with its own provider
# identity ("MockCode2"). Exists ONLY so the test harness can offer two
# distinct, hermetic backends and exercise a REAL provider switch end-to-end
# (`MockCode` → `MockCode2`) — a switch between the SAME singleton is a no-op
# (`switch_provider!` early-returns on `new === current`), so a single mock can
# never test the switch path. Gated behind the same `BT_ENABLE_MOCK_AGENT` env
# var, so it is absent in production. Launches the same `MockACP` and dials the
# same dispatcher as `MockAgent`.
struct MockAgent2 <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
end
function MockAgent2()
    bin, args = mock_bin_args()
    MockAgent2(bin, args, Dict{String,String}(), Dict{String,Any}("form" => true))
end

# ── Per-provider display + protocol identity (dispatch, NOT predicate chains) ─
# `provider_name` is the wire string the worker keys on AND the UI's stable
# identity. `label`/`icon` are the human-facing strings.
provider_name(::ClaudeCodeAgent) = "ClaudeCode"
provider_name(::MiMoAgent)       = "MiMoCode"
provider_name(::OpenCodeAgent)   = "OpenCode"
provider_name(::MockAgent)       = "MockCode"
provider_name(::MockAgent2)      = "MockCode2"

label(::ClaudeCodeAgent) = "Claude Code"
label(::MiMoAgent)       = "MiMo Code"
label(::OpenCodeAgent)   = "OpenCode"
label(::MockAgent)       = "Mock Agent"
label(::MockAgent2)      = "Mock Agent 2"

icon(::ClaudeCodeAgent) = "bt-provider-claude"
icon(::MiMoAgent)       = "bt-provider-mimo"
icon(::OpenCodeAgent)   = "bt-provider-opencode"
icon(::MockAgent)       = "bt-provider-mock"
icon(::MockAgent2)      = "bt-provider-mock"

# Whether a chat should PERSIST this provider's session id for resume across
# server restarts. True only for providers that support claude-style
# `session/load` re-attach: ClaudeCode does, and the mock mimics it (it answers
# `session/load`). MiMo/OpenCode don't, so persisting their id would make the
# next bring-up `session/load` a session that provider never created.
resumable_session(::AgentProvider)  = false
resumable_session(::ClaudeCodeAgent) = true
resumable_session(::MockAgent)       = true
resumable_session(::MockAgent2)      = true

# ── The one provider list ────────────────────────────────────────────────────
# Memoised singletons; the ENV is read exactly once, on first call. The mock is
# offered only when `BT_ENABLE_MOCK_AGENT` is set — absent in production, set by
# the test harness. The dropdown iterates this; the worker resolves through it.
const _PROVIDERS = Ref{Vector{AgentProvider}}()
# Guards the lazy build. WITHOUT it the memo was task-unsafe: the build is
# reached from at least two independent tasks — the chat-bind path
# (`default_provider` → `find_provider`) and the provider-dropdown render
# (`current_providers` in the chat header) — and the FIRST call also triggers
# first-time compilation of the four descriptor constructors. With no lock, two
# tasks could enter the build concurrently and deadlock against each other on
# Julia's codegen lock while first-compiling the same methods, stranding the
# chat-bind for >90 s. Because the memo only writes `_PROVIDERS[]` AFTER a full
# build, a stalled first build is never cached, so EVERY later bind on that
# worker re-enters the build and re-hangs. The lock makes exactly one task build
# (and compile) the list; everyone else waits, then hits the cache.
const _PROVIDERS_LOCK = ReentrantLock()

# Build (NOT memoised) the provider list from the CURRENT process ENV. The mock
# is offered only when `BT_ENABLE_MOCK_AGENT` is set — so the result depends on
# ENV at the moment of the call, which is exactly why the memo below must not be
# populated before the spawner has finished configuring that ENV.
_build_providers() = (ps = AgentProvider[ClaudeCodeAgent(), MiMoAgent(), OpenCodeAgent()];
                      haskey(ENV, "BT_ENABLE_MOCK_AGENT") && append!(ps, (MockAgent(), MockAgent2())); ps)

function current_providers()
    isassigned(_PROVIDERS) && return _PROVIDERS[]
    lock(_PROVIDERS_LOCK) do
        isassigned(_PROVIDERS) && return _PROVIDERS[]   # double-checked
        _PROVIDERS[] = _build_providers()
    end
    return _PROVIDERS[]
end

"""
    refresh_providers!() -> Vector{AgentProvider}

Force-rebuild the memoised provider list from the CURRENT ENV and return it.
`dev_server` calls this once, right after it finishes writing the agent ENV, for
two reasons: (1) it WARMS the list — building + first-compiling the four
descriptor constructors on the uncontended startup path, so the first chat bind
never triggers that build concurrently with the provider-dropdown render (which
under load stalled the bind >90 s and, never being cached, wedged every later
bind on the worker); and (2) it OVERRIDES any list memoised earlier — e.g. before
`BT_ENABLE_MOCK_AGENT` was set — which would otherwise hide the mock provider.
"""
function refresh_providers!()
    lock(_PROVIDERS_LOCK) do
        _PROVIDERS[] = _build_providers()
    end
    return _PROVIDERS[]
end

"""
    find_provider(name) -> BinAgent

The singleton descriptor whose `provider_name` equals `name`. Throws if no such
provider is currently offered (unknown name, or the mock when its env var is
unset) — the same list the dropdown is built from, so the two can't disagree.
"""
function find_provider(name::AbstractString)
    for p in current_providers()
        provider_name(p) == name && return p
    end
    error("unknown provider: $name")
end

end # module
