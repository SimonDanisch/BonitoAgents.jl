# Getting Started

## Requirements

- [Julia](https://julialang.org/install/) 1.12 or newer on every machine.
- For Claude Code agents: Node 20+, the two npm packages

  ```bash
  npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp
  ```

  and a logged-in `claude` CLI (run `claude` once and authenticate).

## Everything on one machine

The desktop entry point starts the dashboard server plus a worker for the
local machine in one process, and opens the UI in your browser:

```bash
git clone https://github.com/SimonDanisch/BonitoAgents.jl
cd BonitoAgents.jl
julia --project=BonitoAgentsApp -e 'using Pkg; Pkg.instantiate()'
julia --project=BonitoAgentsApp -m BonitoAgentsApp
```

Projects, chat history and the machine's worker identity persist across
restarts under the platform data directory (`~/.local/share/BonitoAgents` on
Linux, `~/Library/Application Support/BonitoAgents` on macOS,
`%LOCALAPPDATA%\BonitoAgents` on Windows).

Flags: `--port=8038` for a fixed port, `--no-window` to skip opening the
browser, `--data-dir=PATH` to relocate the state. Prebuilt bundles (snap /
dmg / msix) are attached to
[GitHub releases](https://github.com/SimonDanisch/BonitoAgents.jl/releases).

## One server, many machines

Run the server somewhere always reachable, like a home server or a VPS:

```bash
julia --project=BonitoAgentsApp -m BonitoAgentsApp server --host=0.0.0.0 --port=8038
```

For a permanent install there is a systemd setup script,
[`BonitoAgents/assets/install_server.sh`](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/BonitoAgents/assets/install_server.sh),
which installs the server as a service, generates the worker secret, and
prints the worker one-liner.

Then, on each machine that should run agents, paste the one-liner from the
dashboard's home screen:

```bash
curl -fsSL http://<your-server>:8038/install.sh | sh
```

It installs the worker packages into a shared `@bonito-agents` Julia
environment, registers the machine under a stable identity, and (on Linux)
sets up a systemd user service so the worker survives reboots. The machine
appears in the dashboard seconds later. Re-run the same one-liner to update;
it always installs the code revision the server is running.

## Your first project

From the dashboard home:

- **Discover**: the worker scans for existing Claude Code sessions on that
  machine. Any folder you have used `claude` in shows up and can be imported
  with its conversation history.
- **Pick a folder**: browse the worker's filesystem and turn any directory
  into a project.
- **From GitHub**: clone a repository straight onto a worker.

Opening a project starts (or resumes) its agent lazily on the first message.
The provider dropdown in the chat header selects which agent runs, Claude
Code by default. See [Agent Providers](@ref).

## Your first chat

Type into the composer and send. The agent's turn streams into the
transcript: prose as it is generated, each tool call as a pill that expands
into a diff viewer or terminal output, questions as forms you answer inline.
While an agent works you can open project files from the sidebar tree, edit
them in Monaco, and arrange everything in tabs and splits. See
[The Chat](@ref).
