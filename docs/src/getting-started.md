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

Node and the agent adapters (Claude Code's and Codex's) are installed for you,
in a private Node install, and kept up to date. What stays yours is logging in
to the agents: for Claude Code, run `claude` once and authenticate.

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

Run the server somewhere always reachable, like a home server or a VPS, with a
domain name. The setup script
[`BonitoAgents/assets/install_server.sh`](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/BonitoAgents/assets/install_server.sh)
installs it on Linux:

```bash
bash BonitoAgents/assets/install_server.sh
```

It asks how people reach the server, its domain and the admin account, and
saves the answers before anything can go wrong: a second run offers them again
(`--reconfigure` asks anew). The server only listens on localhost; people log in
through Authelia, which runs next to it as a systemd service: with a password
plus a one-time code from an authenticator (an app, or a password manager), or
with a passkey. At the end the script prints the admin account's password and
authenticator (an `otpauth://` link, or a QR code if `qrencode` is installed).
Once signed in, "Add a passkey" on your account card adds one (Proton Pass, a
security key, ...); from then on it alone signs you in.

**Behind a tunnel** (the default): something in front of the machine brings
HTTPS, e.g. a Cloudflare Tunnel with the public hostname `team.example.com`
pointing at `http://localhost:8038`. Nothing else is needed from the tunnel: the
server asks Authelia about every request itself, serves the login page under the
same name (`https://team.example.com/authelia`), and marks its responses private
so the tunnel's cache keeps nothing. No certificates, DNS records or open ports
on the machine.

**Directly** (`--tls acme`): the script sets up Caddy in front for HTTPS (a
Let's Encrypt certificate), with the login on `auth.team.example.com`. Before it
asks for a certificate it checks that both names resolve to the machine and that
port 80 reaches it, and stops with a message saying what is missing.

To try a direct install out first, `--acme-staging` takes certificates from Let's
Encrypt's staging CA (no rate limits; browsers warn about them), and
`BonitoAgents/test/deploy/smoke.sh https://team.example.com --staging` checks
the result from any machine: the certificate, the login redirect, the public
installer, and that `/w` refuses workers without a credential. On a LAN without
a public domain, `--tls internal` uses Caddy's own certificate authority
instead; every browser and worker machine then has to trust its root
certificate, whose path the installer prints.

Admins manage people from the dashboard: an invite link lets one person create
their own account (they get their password and authenticator on the page it
opens), and the Accounts section adds accounts directly, puts them in groups and
disables them. Members see only their own chats and workers, plus the workers an
owner shared with one of their groups. Everyone can get a new password or a new
authenticator from their account card, and admins from the Accounts table; no
mail is involved anywhere.

Then, for each machine that should run agents, click **Add worker** on the
dashboard and run the command it shows on that machine:

```bash
curl -fsSL https://team.example.com/install.sh | BONITOAGENTS_WORKER_CREDENTIAL='w-...' sh
```

Each worker has its own credential; revoking it on the dashboard disconnects
that machine. The installer puts the worker packages into a shared `@bonito-agents` Julia
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
