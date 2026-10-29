# Concepts

```
   browser / phone ──HTTP/WS──▶  dashboard server (Bonito web app)
                                      ▲  ▲
                     one WorkerLink   │  │   control, MCP, evals, files
                     per worker       │  │
                          ┌───────────┘  └───────────┐
                     worker (laptop)             worker (desktop)
                     ├─ an ACP agent per chat    ├─ Claude Code, Codex, Kimi…
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

The worker connection carries separate channels for its clients. A chat may
have several MCP subprocesses, including clients created by agent threads.
They coexist: connecting one never evicts another. Each connection owns its
pending requests and Julia run controls, so closing or interrupting one client
does not disconnect the others. Incoming chat messages wake waits across the
chat's connected clients.

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
pluggable descriptors (see [Agent Providers](@ref)), and a chat can switch to
another provider at any time; the new agent gets the conversation so far. The
same mechanism powers the deterministic mock agent used by the test suite; the
[dashboard walkthrough](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_dashboard.jl)
replays real recorded agent sessions from disk.

## Security

A server set up with `install_server.sh` listens on localhost only. Everyone
reaches it through a login: behind a tunnel the server asks Authelia about
every request itself, and with `--tls acme` Caddy does. An account in the
`admins` group is an admin; everyone else is a member. Members see only their
own chats and workers, plus the workers an owner shared with one of their
groups.

A server started without a login (`bonito-agents server` on localhost, or
`--host 0.0.0.0` on a network you trust) treats whoever reaches it as its
admin. Keep such a server on localhost, a VPN or a Tailscale network.

Each worker joins with its own credential from **Add worker**, and revoking
the credential disconnects that machine. Agents run with the operating-system
permissions of the worker process; the chat's permission prompts and the Yolo
toggle decide how much they may do unattended. A `bt_share` link needs no
account: the link is the permission, with an optional password on top.
