# Getting Started

## Install

The fastest way onto one machine is the installer. It downloads the prebuilt
bundle for your platform (a self-contained Julia + BonitoAgents, with no
separate Julia install needed), puts a `bonito-agents` command on your PATH, and
immediately starts the desktop app: a local dashboard server plus a worker for
this machine, opened in your browser.

Linux / macOS:

```bash
curl -fsSL https://agents.bonito.sh/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://agents.bonito.sh/install.ps1 | iex
```

Start it again any time with `bonito-agents`. **Re-run the same install line to
auto-update** to the newest release; it skips the download when you are already
current. Useful flags: `bonito-agents --port=8038` (fixed port), `--no-window`
(don't open a browser), `--data-dir=PATH` (relocate state). Pass installer
options after `-- `, e.g. `… | sh -s -- --no-run` to install without starting
or `… | sh -s -- --uninstall` to remove it (raw `.tar.gz` bundles are also
attached to
[GitHub releases](https://github.com/SimonDanisch/BonitoAgents.jl/releases)).

Projects, chat history and the machine's worker identity persist across
restarts and updates under the platform data directory
(`~/.local/share/BonitoAgents` on Linux, `~/Library/Application
Support/BonitoAgents` on macOS, `%LOCALAPPDATA%\BonitoAgents` on Windows) and
are never touched by install/update/uninstall.

For Claude Code agents you also need Node 20+, the two npm packages

```bash
npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp
```

and a logged-in `claude` CLI (run `claude` once and authenticate).

## From source

If you would rather run from a checkout (you need
[Julia](https://julialang.org/install/) 1.12+), the desktop entry point does
the same thing, giving you dashboard server + local worker + UI in your browser:

```bash
git clone https://github.com/SimonDanisch/BonitoAgents.jl
cd BonitoAgents.jl
julia --project=BonitoAgentsApp -e 'using Pkg; Pkg.instantiate()'
julia --project=BonitoAgentsApp -m BonitoAgentsApp
```

## One server, many machines

Run the server somewhere always reachable, like a home server or a VPS. After
the installer above, this is the `server` mode of the same command:

```bash
bonito-agents server --host=0.0.0.0 --port=8038
```

(from a source checkout, use
`julia --project=BonitoAgentsApp -m BonitoAgentsApp server --host=0.0.0.0 --port=8038`.)
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

Discover, folder picking and cloning live on each worker's own card, so the
machine is chosen before the folder is. **Copy project** (Settings card) is the
one that crosses machines: it snapshots a project's files onto another worker as
a new project. To carry an existing chat elsewhere instead, with its files *and*
the agent's memory, use that chat's ⋯ menu → *Continue on*.

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
