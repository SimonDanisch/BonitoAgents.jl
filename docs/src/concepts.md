# Concepts

```
   browser / phone ──HTTP/WS──▶  dashboard server (Bonito web app)
                                      ▲  ▲
                     control WS +     │  │
                     file transfer    │  │
                          ┌───────────┘  └───────────┐
                     worker (laptop)             worker (desktop)
                     ├─ claude-code agent (ACP)  ├─ agent per project
                     ├─ persistent Julia MCP     ├─ …
                     └─ your project checkouts   └─ your project checkouts
```

## Server

The server is one Julia process running a [Bonito](https://github.com/SimonDanisch/Bonito.jl)
web app. It owns:

- the **dashboard UI** every browser talks to,
- **chat history** (persisted per project, replayed into reopened views),
- the **project registry** (which project lives on which worker, at which
  path),
- a **server-side mirror** of project files, populated on demand: the file
  editor always re-fetches from the worker before showing content, so you
  never edit a stale copy.

Browsers can come and go: a tab that disconnects (phone in the pocket, laptop
lid closed) can reconnect to the same session for a generous window and finds
its state intact.

## Workers

A worker is a small Julia process on each machine with code on it. Workers
**dial out** to the server over a WebSocket control channel, so only the
server needs a reachable address. Per machine the worker:

- registers under a **stable identity** (survives reinstalls and reboots),
- spawns **one agent process per project** on demand and relays its protocol
  stream,
- answers filesystem requests: directory listings, file stats and transfers,
  the searchable project file index, and librsync-based directory sync for
  project import/move,
- discovers existing Claude Code sessions for the Discover view.

### Link liveness

Laptops suspend and switch networks, which can leave a TCP connection
half-open: both ends think it is ESTABLISHED while nothing flows. The server
pings every worker and kills the transport of any worker that goes silent past
a deadline, marking it offline in the UI and failing pending requests fast.
The worker watches for the server's pings and re-dials over the current
network when they stop. Sessions abandoned by a link loss are reaped on the
worker so no agent processes leak.

## Projects

A project is a directory on a worker plus its chat. Ways to create one:

- **Discover** an existing Claude Code session folder (imports history),
- **pick any folder** on the worker,
- **clone from GitHub** onto the worker.

Chats bind their agent **lazily**: opening a project renders instantly from
persisted history; the agent process starts on your first message and is
reaped again when idle capacity is needed (a bounded LRU keeps the number of
live agent processes in check).

## Agents

Agents speak the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP). The worker spawns the agent binary per project; the server bridges the
protocol stream into the chat model that drives the UI. Providers are
pluggable descriptors (see [Agent Providers](@ref)). The same mechanism powers
the deterministic mock agent used by the test suite; the
[dashboard walkthrough](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_dashboard.jl)
replays real recorded agent sessions from disk.

## Security

Workers authenticate with a shared secret, generated at install time and
embedded in the worker one-liner. The dashboard has no user accounts, so treat
it like any internal tool: keep it on localhost, a VPN/Tailscale network, or
behind reverse-proxy auth. Agents run with the OS permissions of the worker
process; the chat's permission prompts and the Yolo toggle decide how much
they may do unattended.
