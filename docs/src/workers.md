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

## Files between server and worker

Project trees move with librsync-based directory sync (import, and project
move between workers); single files move over a dedicated transfer channel.
The file editor always stats and re-fetches through the worker before showing
content, and *Save* writes back to the worker. The server-side mirror is a
cache, never the source of truth. Oversized or binary files are refused with a
clear message before any transfer starts.

## Managing workers

Each worker card on the dashboard shows its status dot, lets you rename it,
and offers *Rescan* to refresh the discovered-sessions list. The `worker.log`
lives next to the worker config (a Julia scratchspace by default; the exact
path is printed at install time, and `BONITOAGENTS_CONFIG_DIR` overrides it).
Removing a machine is `systemctl --user disable --now bonito-worker` plus
deleting that config dir.
