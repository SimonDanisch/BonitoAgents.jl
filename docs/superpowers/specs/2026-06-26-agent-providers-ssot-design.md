# Agent providers — one source of truth, one spawn path, one transport

Date: 2026-06-26
Status: approved design, pre-implementation
Repo: `dev/BonitoAgents`

## Problem

A provider (Claude Code, MiMo, OpenCode, Mock) is currently defined in **two
places** that drift independently:

- **Server** — `BonitoAgents/src/agents.jl`: one `mutable struct … <: BinAgent`
  per provider, each constructor hard-coding `bin`/`args`/`env`/`elicitation`
  (e.g. `MiMoAgent` carries `["acp"]`, `ClaudeCodeAgent` carries the `CLAUDE_*`
  env), plus `provider_name`/`label`/`icon` dispatch methods and the
  `AGENT_KINDS` tuple.
- **Worker** — `BonitoWorker/src/BonitoWorker.jl` `handle_open_session`: a
  parallel `if provider == "MiMoCode" … elseif "OpenCode" … elseif "ClaudeCode"`
  chain re-deriving the **same** bin/args/env data, with **no `MockCode` case**
  (it hits `else`, warns, and falls back to the worker's default `agent_bin`).

Adding or changing a provider means editing both. The mock "works" in tests only
by accident — the test worker's default `agent_bin` already points at the mock,
so the missing `MockCode` branch is never noticed.

On top of that, the server carries **two live ways to run an agent** that do the
same job:

- `start!(::BinAgent)` — spawn a local subprocess, talk ACP over its stdio pipe
  via `ACP.SubprocessTransport`.
- `start!(::WorkerAgent)` — ask a worker to spawn the binary; the worker
  byte-relays the subprocess stdio over a WebSocket; the server talks ACP over
  `WorkerTransport` (the dialed-back WS).

The local path is **dead in production**: the only real chat entry point, the
dashboard (`dashboard.jl:408`), always builds a `WorkerAgent`. The
`agent === nothing → ClaudeCodeAgent` default in `ChatModel` (`chat.jl:182`) has
no production caller. Both `dev.jl` and the installed app spawn a local worker at
boot, so a worker is always present.

## Goals

- **One definition per provider.** Bin/args/env/elicitation/label/icon/enabled
  live in exactly one place, consumed by both server and worker.
- **One spawn path.** The worker is the only thing that ever spawns an agent
  process. The server always drives ACP over the worker WebSocket.
- **One transport.** `WorkerTransport` (WS) is the only concrete ACP transport.
  `ACP.SubprocessTransport` is deleted.
- **The mock is a real provider, selected like a user would** — chosen from the
  provider dropdown, spawned by the worker like any other agent. No `agent_bin`
  override, no `LocalTransport`/`MockTransport`, no special-case open-session
  path. It is hidden in production and revealed by an env var.

## Non-goals

- Changing the ACP wire protocol, the worker control-WS / `/worker-acp` dial-back
  handshake, or the dashboard→chat UX.
- Moving the ACP *protocol* logic (`Connection`, `reader_loop`, JSON-RPC
  dispatch) anywhere — it stays in `AgentClientProtocol`, untouched.
- Remote-worker provisioning, auth, or multi-worker scheduling.
- Reworking how `BONITOAGENTS_SERVER_URL` reaches the agent's MCP children. It's
  injected into the spawned agent's env today (`BonitoWorker.jl:819-837`) because
  that's the only channel that inherits through "third-party agent → its MCP
  grandchildren". It's ugly but pre-existing; a tidier version (put it only in the
  per-server `env` of the `mcpServers` payload) is a separate change, not this one.

## Architecture

```
        ┌─────────────────────────────────────────────┐
        │  AgentProviders  (new, dependency-light)     │   ← single source of truth
        │  • the agent structs (ClaudeCodeAgent, …)    │
        │    — plain data, bin/args/env baked at        │
        │      construction by plain resolver funcs     │
        │  • dispatch: provider_name/label/icon(a)     │
        │  • current_providers() — the one list,        │
        │    mock pushed iff ENV says so, memoized       │
        └───────────────┬──────────────────┬───────────┘
                        │                  │
            BonitoAgents (server)     BonitoWorker
            picks one, drives ACP     find_provider(name) →
            over WS                   spawn from .bin/.args/.env
```

This is just the existing `agents.jl` shape (plain structs + multiple dispatch),
moved into a shared package so the worker can use the same types. No spec object,
no functions-as-struct-fields. `bin`/`args`/`env` are resolved at construction by
ordinary functions (`claude_bin()` etc.) that run wherever the agent is
constructed — so `Sys.which(...)` still runs worker-side when the worker builds
the agent. The agent structs reference only `ACP` types (`Handler`/`MCPServer`),
and `ACP` is `Base64`+`JSON` (the worker already has `JSON`), so this stays light.

### The provider list — immutable singletons

Deleting `start!(::BinAgent)` removes the only thing that forced a per-session
instance: the live `client::ACP.Client` field (two chats on one provider would
clobber each other's client). With it gone, `BinAgent` carries no live state —
it's an immutable provider *descriptor*: `{bin, args, env, elicitation}` plus its
`provider_name`/`label`/`icon` dispatch. (`cwd`/`handler`/`mcp` also drop — they
belonged to the local path; per-session context now lives on `WorkerAgent`.)

So the providers are singletons, built once. The per-provider data lives in
exactly one place — the struct's constructor — and the single list is memoized,
reading `ENV` once:

```julia
const _PROVIDERS = Ref{Vector{AgentProvider}}()

function current_providers()
    isassigned(_PROVIDERS) && return _PROVIDERS[]
    providers = AgentProvider[ClaudeCodeAgent(), MiMoAgent(), OpenCodeAgent()]
    haskey(ENV, "BT_ENABLE_MOCK_AGENT") && push!(providers, MockAgent())
    return _PROVIDERS[] = providers
end
```

The dropdown iterates `current_providers()`. The mock is in the list only when
`BT_ENABLE_MOCK_AGENT` is set — absent in production, set by the test harness.

The descriptor's `env` holds only provider-specific extras (`CLAUDE_*`, the
mock's scenario), **not** a snapshot of the whole process `ENV` (the current
`envdict(extra)` does the latter — wrong for an immutable singleton). The live
`ENV` is merged in at spawn time by the worker, which already does this.

## Server changes (`BonitoAgents`)

1. **Delete the local-spawn path first** — it's what unlocks the singletons.
   Remove `start!(::BinAgent)` and all live use of `ACP.SubprocessTransport`.
   `BinAgent` then has no live `client`/`cwd`/`handler`/`mcp` state, so it shrinks
   to the immutable descriptor.
2. **Move the descriptors to `AgentProviders`.** The
   `ClaudeCodeAgent`/`MiMoAgent`/`OpenCodeAgent`/`MockAgent` structs (now
   descriptor-shaped) and their `provider_name`/`label`/`icon` dispatch move into
   the shared package. `AGENT_KINDS` → `current_providers()`. `WorkerAgent` holds
   a reference to the singleton descriptor instead of a `Type{<:BinAgent}` it has
   to call (`provider_name(a.provider)` instead of `provider_name(a.kind())`).
3. **Delete the dead default.** `ChatModel` no longer defaults to a local
   `ClaudeCodeAgent`; constructing a chat requires an agent (the dashboard
   already passes one). A chat cannot exist without a worker — make that explicit
   rather than faked.

## Worker changes (`BonitoWorker`)

Replace the `if/elseif` chains for bin, args, and env in `handle_open_session`
with a lookup of the singleton descriptor in `current_providers()`. The provider
arrives as a name string because the `open_session` command is JSON over the
control WS — a Julia type can't cross that boundary.

```julia
function find_provider(name)                # in AgentProviders
    for p in current_providers()
        provider_name(p) == name && return p
    end
    error("unknown provider: $name")
end
```

The worker call site becomes:

```julia
p    = find_provider(get(cmd, "provider", "ClaudeCode"))  # the singleton; throws on unknown
proc = open(Cmd(`$(p.bin) $(p.args)`; env = merge(env, p.env), dir = cwd), "r+")
```

The descriptor's constructor is the source of truth for `bin`/`args`/`env`; `cwd`
goes to `Cmd`'s `dir`, not the descriptor. Because `find_provider` walks
`current_providers()`, an unknown provider — or `MockCode` when
`BT_ENABLE_MOCK_AGENT` isn't set — isn't found and throws (reported through the
existing `report_open_session_failed` path), instead of silently falling back to
a default binary.

The worker still merges live `ENV` and the per-session runtime context the
spawned agent's MCP children need (notably `BONITOAGENTS_SERVER_URL` for the
eval-bridge dial-back) on top of `p.env`. That env plumbing is pre-existing and
**out of scope** here — see the non-goals note.

`BonitoWorker` gains a dependency on `AgentProviders` (data-light, no bloat) and
loses its hand-rolled bin resolvers.

## Transport unification (`AgentClientProtocol`)

- Delete `SubprocessTransport`. `AgentClientProtocol` keeps the abstract
  `Transport` interface (`send`/`recv`/`close`/`transport_eof`) and all protocol
  logic, with **no concrete transport**.
- The single concrete transport is the WS one (today `WorkerTransport` in
  `BonitoAgents/src/transport.jl`). It moves to a layer ACP's own tests can
  reach. **Decision: move the WS transport into `AgentClientProtocol`**, adding an
  `HTTP` dependency there. Rationale: it keeps "the protocol + its one transport"
  in one package, lets ACP's tests drive the real transport, and avoids inventing
  a third package solely to host a transport. (`HTTP` is already transitively
  present throughout the stack.) `BonitoAgents` re-exports / uses it unchanged.

## MockACP

- New package `test/MockACP` (own minimal `Project.toml`: `JSON`, `Sockets`)
  holding the current `mock_claude_agent_acp.jl` logic behind a Julia `@main`
  entry point. Registered in `test/Project.toml` `[deps]` + `[sources = {path =
  "MockACP"}]`, so it resolves against the already-instantiated **test env** — no
  separate `mocks/Manifest.toml`, precompiled once with the test env, no
  per-spawn recompile. (Julia only loads MockACP's own closure — `JSON`/`Sockets`
  — not the rest of the test manifest, so the big env costs nothing at spawn.)
- The `MockAgent` struct's constructor (in the shared package) bakes:
  - `bin` → the Julia executable.
  - `args` → `["--startup-file=no", "--project=<test env>", "-m", "MockACP"]`,
    where `<test env>` is the `BonitoAgents/test` project path (carried via an
    env var so the worker knows it, the way `BT_MOCK_PROJECT` does today).
  - `env` → scenario + dispatcher coordinates (`BT_MOCK_ACP_SCENARIO`,
    `BT_MOCK_ACP_DISPATCHER`), read from the worker's inherited env — the same
    mechanism by which `ClaudeCodeAgent` threads `CLAUDE_*`.
- It enters the dropdown only via `current_providers()` (the `BT_ENABLE_MOCK_AGENT`
  check), so no production menu shows it.
- The bash wrapper (`mock_claude_agent_acp`) and the separate `mocks/` env are
  deleted; the launch command is `MockAgent().bin` + `.args`.

## Testing strategy

- **The harness selects the mock like a user.** `TestKit.dev_server` stops
  passing `agent_bin`/`agent_env`. Instead it sets `BT_ENABLE_MOCK_AGENT` (+ the
  dispatcher coords) in the worker's environment, then drives the UI:
  `switch_agent(s, "Mock Agent")` picks the mock from the dropdown, and the
  worker spawns MockACP like any other agent. One path, exercised exactly as
  production runs it.
- **ACP protocol invariants** run in `AgentClientProtocol/test` against a real
  mock agent over the real WS transport (no `SubprocessTransport`). This revises
  the earlier `TEST_MIGRATION_AUDIT.md` line that kept `SubprocessTransport` for
  ACP tests — that transport is gone.
- **Provider list unit tests** (new): `current_providers()` excludes the mock
  without `BT_ENABLE_MOCK_AGENT` and includes it with; each provider's
  constructed `bin`/`args`/`env` are as expected; the ENV is read once (memoized).
- **Worker resolution test**: `handle_open_session` maps the provider name to the
  type and spawns from the constructed agent (no `if/elseif`), and an unknown
  provider produces a clear `report_open_session_failed`, not a silent fallback.

## Migration / rollout order

1. Land `AgentProviders` (the moved agent types + dispatch + `current_providers()`)
   with unit tests (no consumers yet).
2. Switch `BonitoWorker.handle_open_session` to the `current_providers()` lookup.
3. Switch `BonitoAgents` to the shared types; delete `start!(::BinAgent)`, the
   dead local default, and `AGENT_KINDS`.
4. Move the WS transport into ACP; delete `SubprocessTransport`.
5. Convert the mock to `MockACP`; add it to `current_providers()` behind the env
   check; rewire `TestKit` to select it via the dropdown.
6. Delete the bash wrapper + `mocks/` env + any `LocalTransport`/`MockTransport`
   remnants. Update `TEST_MIGRATION_AUDIT.md`.

Each step keeps the suite green before the next.

## Risks

- **Startup ordering.** Making "a worker must be registered" a hard precondition
  means chat creation must wait for the local worker to register rather than
  silently spawning in-process. Mitigation: the local worker spawns at boot;
  chat open waits on worker registration with a bounded timeout and a clear
  error.
- **ACP gains an `HTTP` dependency.** Heavier than Base64+JSON, but `HTTP` is
  already in the resolved stack everywhere; no new external surface.
- **MockACP env in production.** The `BT_ENABLE_MOCK_AGENT` check in
  `current_providers()` is the single guard. Tests assert the
  provider is absent without `BT_ENABLE_MOCK_AGENT`, so a regression that leaks
  it into production fails a test.
