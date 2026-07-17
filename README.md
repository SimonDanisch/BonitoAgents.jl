<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="BonitoAgents/assets/logo/bonitoagents-dark.svg">
    <img src="BonitoAgents/assets/logo/bonitoagents-light.svg" alt="BonitoAgents" width="160">
  </picture>
</p>

<h1 align="center">BonitoAgents</h1>

<p align="center">
  A self-hosted dashboard for running coding agents on your own machines.
</p>

> [!WARNING]
> Use at your own risk: there are no safeguards (yet) preventing an LLM driven
> through BonitoAgents from wiping your entire PC or leaking all your secrets.

<p align="center">
  <img src="BonitoAgents/assets/screenshot-chat.png" alt="Chat with a streamed Monaco diff from a real refactor" width="850">
</p>

A small worker process runs on every machine that has code on it. All workers
connect out to one dashboard server, and you control every agent session from
a single web UI, from any browser including your phone. Nothing runs in a
cloud; the agents work directly on your checkouts with your Claude
subscription.

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

Agents are pluggable [ACP](https://agentclientprotocol.com) providers:
Claude Code by default, with MiMo and OpenCode adapters included
([`AgentProviders/`](AgentProviders/)).

## Features

- Chats stream in live, with Monaco diff viewers for edits, terminal output
  for shell commands, inline images, and the agent's todo list pinned while
  it works.
- A file tree and Monaco editor per project. Files open fresh from the
  worker and save back to it. Panels (chats, editors, app embeds) arrange
  into tabs, splits and floating windows.
- Agents get MCP tools backed by a persistent Julia session per project:
  `julia_eval` with warm state and disciplined output, `bt_show` for media,
  and `bt_show_app` to embed a running Bonito app whose interactions round
  trip to Julia on the worker.
- Chats persist on disk, browser reconnects resume where you left off, and
  existing Claude Code sessions on a worker can be imported with their
  history.
- Dropped or half-open worker connections (suspend, network switch) are
  detected by heartbeats on both ends and heal automatically.

The full inventory lives in [`FEATURES.md`](FEATURES.md).

## Quick start

Requirements: [Julia](https://julialang.org/install/) 1.12+. For Claude Code
agents also Node 20+,
`npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp`,
and a logged-in `claude`.

### Everything on this machine

```bash
git clone https://github.com/SimonDanisch/BonitoAgents.jl
cd BonitoAgents.jl
julia --project=BonitoAgentsApp -e 'using Pkg; Pkg.instantiate()'
julia --project=BonitoAgentsApp -m BonitoAgentsApp
```

This starts the dashboard server plus a worker for the local machine and
opens the UI in your browser. State persists across restarts under the
platform data dir (`~/.local/share/BonitoAgents` on Linux). Flags:
`--port=8038`, `--no-window`, `--data-dir=PATH`. Prebuilt bundles (snap /
dmg / msix) are attached to
[releases](https://github.com/SimonDanisch/BonitoAgents.jl/releases).

### One server, many machines

Run the server somewhere always reachable:

```bash
julia --project=BonitoAgentsApp -m BonitoAgentsApp server --host=0.0.0.0 --port=8038
```

or install it as a systemd service with
[`BonitoAgents/assets/install_server.sh`](BonitoAgents/assets/install_server.sh).
Then, on each machine that should run agents, paste the one-liner from the
dashboard's home screen:

```bash
curl -fsSL http://<your-server>:8038/install.sh | sh
```

It installs the worker pinned to the server's code revision, registers the
machine under a stable identity, and sets up a systemd user service on
Linux. Re-run it any time to update.

## Tour

<p align="center">
  <img src="BonitoAgents/assets/screenshot-workspace.png" alt="Chat beside the built-in editor in a split workspace" width="850">
</p>

[`examples/walkthrough.jl`](examples/walkthrough.jl) records a scripted tour
([`examples/walkthrough.mp4`](examples/walkthrough.mp4)) against a
deterministic mock agent, so it needs no API key:

```bash
julia --project=BonitoAgents/test examples/walkthrough.jl
```

## Documentation

Getting started, concepts, deployment and API docs live in [`docs/`](docs/):

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
julia --project=docs docs/run.jl        # serve the built site locally
```

## Development

```bash
julia --project=BonitoAgents -e 'using BonitoAgents; BonitoAgents.wait!(dev_server(auto_open = true))'
```

`dev_server()` boots the same stack against throwaway tempdirs. The test
suite drives it through headless Electron:

```bash
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents")'                          # everything
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["unit"])'      # fast, no browser
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["e2e:media"])' # one suite
```

## Security model

Workers authenticate to the server with a shared secret from the install
one-liner. The dashboard has no user accounts, so keep it on localhost, a
VPN, or behind reverse-proxy auth. Agents run with the permissions of the
worker process; the chat's permission prompts and the Yolo toggle decide how
much they may do unattended.
