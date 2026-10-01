# Workers & Machines

Every machine that should run agents gets a **worker**: a small Julia process
that dials out to your server, keeps a stable identity, and does everything
local, from spawning agents to reading and writing project files to scanning
for existing sessions.

## Adding a machine

Copy the one-liner from the dashboard's home screen and run it on the
machine:

```bash
# Linux / macOS
curl -fsSL http://<your-server>:8038/install.sh | sh

# Windows (PowerShell)
irm http://<your-server>:8038/install.ps1 | iex
```

What it does:

1. checks the prerequisites (`node`, `npm`, `claude`, `claude-agent-acp`),
2. installs the worker packages into a shared `@bonito-agents` Julia
   environment, pinned to the same code revision the server runs so server
   and workers can't drift apart,
3. writes the worker config (server URL + secret) and a stable `worker_id`,
4. starts the worker and, on Linux, installs a systemd user service
   (`bonito-worker`) so it survives reboots.

Re-running the one-liner updates the worker to the server's current revision
and restarts the service.

## Identity and renames

A machine registers under a persistent `worker_id`. The display name defaults
to something like `simon-a1b2` and can be renamed in its dashboard card; the
rename sticks across reconnects because the server remembers it, not the
worker. Projects are attached to the worker id, so reinstalling the worker
keeps every project reachable.

## Reconnects and liveness

Workers reconnect automatically: on a normal disconnect the retry loop
re-dials every few seconds. Half-open "zombie" links, from a laptop suspend or
a Wi-Fi to LAN switch, where neither end sees an error, are caught by
heartbeats. The server pings each worker and force-closes silent links: the
worker flips to *offline* in the UI within a minute, and requests against it
fail fast with a toast instead of hanging. The worker watches for those pings
and re-dials over the current network when they stop, reaping any agent
sessions the server had already abandoned.

## After a worker crash

A worker that crashes in the middle of a chat's turn (killed, out of memory, a
segfault) takes the agent with it. When it is back, each chat whose turn it cut
off gets one automatic message asking the agent to check where things stand and
carry on; nothing else is continued. This never rests on a guess:

- The worker says it crashed. Each run of it has an id in its pidfile, which a
  normal exit removes, and so does everyone who stops it on purpose: updates and
  re-installs, and the systemd unit's `ExecStop` (Julia 1.12.7 cannot be relied
  on to exit cleanly on SIGTERM, so the unit does it before the signal). A new
  run that finds the file of a run that is gone, from the same boot of the
  machine, reports that run as crashed. A reboot, a shutdown or a power loss
  never counts; neither does a dropped connection, which just resumes.
- The server knows which chats were mid-turn: those with a prompt of ours
  delivered and unanswered when the worker's link first went down, and nothing
  queued behind it.
- Nothing happened in the chat since: a message sent, a stop clicked, a restart
  or a closed chat means it is not continued.
- A turn that was itself such a continuation is not continued again, so a turn
  that crashes its worker cannot loop.

What was noted lives in the server's memory: a server restart in between
continues nothing. A worker running outside systemd (macOS, Windows) that is
killed from outside, not stopped through the installer, counts as crashed.

## Files between server and worker

Project trees move with librsync-based directory sync (import, and continuing
a chat on another worker); single files move over a dedicated transfer channel.
The file editor always stats and re-fetches through the worker before showing
content, and *Save* writes back to the worker. The server-side mirror is a
cache, never the source of truth. Oversized or binary files are refused with a
clear message before any transfer starts.

## Continuing a chat on another worker

A chat's ⋯ menu lists every other online worker under *Continue on*. Picking
one opens a new chat on that worker that picks up where this one is; the
original chat stays as it is, on its worker, with whatever it is running. The
agent's own record of the conversation is copied first: for Claude Code the
transcript, the subagent transcripts and the project memory under
`~/.claude/projects/`, rewritten to the new working directory, so the new chat
resumes with the agent's memory. Then the project's files travel through the
server to the other worker's projects root (the push only adds; nothing already
there is removed).

It waits for a turn in flight to end (stop it or wait), so the new chat starts
from a finished answer. If the record can't be carried (a provider without a
movable record, the source offline, a failed transfer) the new chat starts
fresh. With the source worker offline, only a project the server holds a synced
copy of can be continued. The window's progress card says which happened.

## Running Julia on another machine

An agent can evaluate Julia on any other online worker
(`bt_julia_eval(code; worker = "MacBook")`, see
[Julia Tools & Live Apps](@ref)). That traffic needs no new network path:
requests, replies, streamed stdout and interrupts all ride the authenticated
connections the workers already hold open to the server.

```text
chat MCP → local daemon → server → target daemon → eval host
           loopback       existing worker links    loopback
```

Both ends of the chain are loopback, so an agent's MCP process never learns the
server URL or the server secret; it talks to its own machine's worker over a
token scoped to that one chat. The server sits in the middle and enforces the
chat's **Remote julia** switch on every call, which is why flipping it off ends
remote evals immediately, with no restart. If a worker drops, its pending calls
fail with an error instead of hanging, and a reconnect re-establishes the path.

## Managing workers

Each worker card on the dashboard shows its status dot, lets you rename it,
and offers *Rescan* to refresh the discovered-sessions list. The `worker.log`
lives next to the worker config (a Julia scratchspace by default; the exact
path is printed at install time, and `BONITOAGENTS_CONFIG_DIR` overrides it).
Removing a machine is `systemctl --user disable --now bonito-worker` plus
deleting that config dir.
