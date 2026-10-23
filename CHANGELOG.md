# Changelog

What changed in each BonitoAgents release. The guides are at
[agents.bonito.sh](https://agents.bonito.sh), and
[A Day with BonitoAgents](https://agents.bonito.sh/story.html) shows how the
pieces fit together.

## Unreleased

v0.1.0 was a good chat for Claude Code on your own machines. This release turns
BonitoAgents into a self-hosted workspace for **any** coding agent, on **every**
machine you own, for a whole team, with everything the agents make rendered
live.

### Highlights

- **Bring any agent.** Codex and Kimi Code join Claude Code, OpenCode and MiMo.
  Switch a chat's agent in its header at any time: the next turn runs under the
  new agent, which gets the conversation so far. The BonitoAgents tools render
  as the same cards whichever agent calls them.
- **Every machine, one connection each.** Workers keep one resumable,
  multiplexed link to the server that survives sleep and network switches. From
  one chat, an agent can run Julia on another machine, move Julia values between
  machines and sync folders. **Continue on** opens a chat on another worker with
  the project's files and the agent's memory.
- **Teams and the open internet.** `install_server.sh` sets up a server with a
  passkey login (Authelia), behind a tunnel or with Caddy and Let's Encrypt.
  Admins invite people, put them in groups and share workers with groups.
- **Share with a link.** Reports, files and live apps open in any browser, with
  an optional password; Settings lists every link.
- **Everything it makes, in place.** A 3D viewer with textures, notebooks,
  tables, video that behaves on phones, markdown with its pictures, and code
  highlighting for 90 languages.
- **Server apps.** Apps are Julia packages with their own chat pane and tools
  for every agent; the bundled To-do app keeps one list for the whole server.
- **Review the agent's diff** line by line, ask about a change right away, or
  bundle notes into one instruction.

### Agents and providers

- Codex through the managed `codex-acp` adapter. **Discover** finds Codex
  sessions on a worker, and Codex chats resume after a restart.
- Kimi Code provider. Kimi, OpenCode and Codex tool calls are normalised, so
  `bt_julia_eval`, `bt_show` and the other tools look the same for every agent.
- Switching providers is transactional: the choice is kept once the new agent's
  session is up, otherwise the chat goes back to the previous agent and says why.
  The new agent receives the conversation so far.
- Managed adapters: workers install Node and the Claude Code and Codex adapters
  into a private prefix, at the versions the server declares, and update them
  while no chat runs. A Node mirror can be configured.
- Provider failures reported at the end of a turn (Codex's usage limit, for
  example) show as a **Provider error** notice in the provider's own words.
- **Yolo mode** leaves only on purpose: the agent says it is done, then confirms
  it. A failed, refused or repeating turn, or several turns without a tool, stop
  the loop and switch Yolo off.
- **Stop** spares background subagents, and the agent is told about tasks a
  stop interrupted.
- Message queues are explicit: queue for when the agent is done, after the
  current message, or interrupt and send.

### Machines and workers

- WorkerLink: one resumable, multiplexed connection per worker. MCP traffic and
  eval bridges ride it through the worker's relay, so no extra ports or paths
  are needed.
- Run Julia on another worker from the same chat (`bt_julia_eval(...; worker =
  "name")`), switched on per chat by an admin with **Remote julia**.
- `remote_session` moves Julia values between machines; `bt_sync_folder`
  streams folders between workers through the link.
- **Continue on** another worker: a new chat there with the project's files and
  the agent's own record of the conversation.
- A worker that crashed mid-turn tells exactly the chats it cut off to carry on
  when it is back.
- Background Julia runs: `bt_julia_eval(...; background = true)`,
  `bt_julia_wait`, run rows in the chat and continue cards that lead back to
  their eval.
- Workers update themselves once no chat runs on them, or right away with
  **Update now**, and their cards show the progress. A reinstall keeps the
  machine's credential.
- Every process a chat starts, on every worker, is recorded and ended with the
  chat.

### Files, media and apps

- The 3D viewer reads the original files with three.js, textures included.
- Media on phones: no flicker while scrolling, no download again when enlarged,
  buttons that are visible on touch screens.
- Worker files stream as links; markdown shows its pictures; links to markdown
  files open in the workspace.
- Code views are static and highlighted in a background worker, with Monaco's
  grammars for 90 languages. A 10,000-line result opens without freezing the
  page and stays searchable and copyable.
- Server apps with tiles on the dashboard, and the To-do app.
- `bt_share`: links for a markdown report with its pictures and videos, any
  file in its viewer, or a Julia file's live app with one copy per visitor.
  Optional password; listed and ended in Settings.
- **Review changes**: the project's git diff as a workspace tab, compared with
  any branch, tag or commit, with **Ask** and **Feedback**.

### Login, teams and servers

- `install_server.sh` installs Caddy and Authelia, asks its questions once and
  remembers the answers, and checks DNS and ports before it asks for a
  certificate.
- Run behind a tunnel: the server asks Authelia about every request itself, so
  no certificates, DNS records or open ports are needed on the machine.
- Passkey-first sign-up; a password plus an authenticator code for whoever
  cannot use a passkey. No mail server needed.
- Accounts, invites and groups. Members see their own chats and the workers
  shared with their groups; admin-only menus stay hidden from them.
- Login sessions live in a private, persistent Valkey store, so logins survive
  restarts and one device's login no longer ends another device's.
- All tabs of a browser share one login: when it ends they wait, and one login
  in any tab brings them all back.
- Updating keeps the running server serving until its one restart near the end,
  and Authelia restarts only when something it runs changed.
- Without a login: `bonito-agents server` for this machine only, or
  `--host 0.0.0.0` for a network you trust. Uninstalling keeps the data.

### Chat and workspace

- The transcript opens at its newest messages and loads older ones as you
  scroll, keeping a bounded number of rows in the page; the reading position
  is anchored to content.
- Switching chats and workspace tabs keeps their layout and scroll positions
  instead of rebuilding them.
- A mobile composer and a phone sidebar; a resizable sidebar in recency order.
- A tab whose server session is gone reloads itself, or asks first when a draft
  would be lost.
- Readable file search hits; colour-matrix eval results as real PNGs.
- **Export as Markdown** in the chat's ⋯ menu downloads the whole chat as one
  readable `.md`, every tool call with its full output and diffs. It is also a
  BonitoBook notebook: each Julia eval is a cell you can run again (thanks
  @sbordt).

### Developer tools

- **Debug BonitoAgents** opens an agent on a BonitoAgents checkout on the worker
  you choose. Dev mode adds tools for the running system: server and worker
  state, logs from every machine, browser tabs and their consoles, timings and
  memory.

### Fixed

- A Codex chat in Yolo mode no longer re-prompts an account that hit its usage
  limit. One chat sent 10,294 auto-continues in 2.5 hours before this fix,
  because the failure arrived as a normal turn end and the compaction step
  counted as work.
- Stop stops. A background run or task that ends after you pressed Stop (or
  restarted the chat) no longer starts a new turn with its note; the note waits
  in the queue and goes to the agent with your next message.
- Logging in on one device no longer logs out another. Authelia's in-memory
  session store could overwrite one browser's session with another's.
- An error page with a long stack trace no longer stalls the server while it
  compiles a renderer for that length.
- Logging a rendering error no longer prints a whole live chat.
- Many fixes to scrolling, streaming, reconnects, worker links and tests that
  were flaky on CI.

### Upgrading

- **Desktop app:** run the install line again.
- **Server installed with `install_server.sh`:** run it again. It adds the
  Valkey session store; each device logs in once more after this update. The
  server no longer starts without that store, and says to run the installer.
- **Workers:** they update themselves when no chat runs, or use **Update now** on
  the worker's card. A worker too old to update itself shows **reinstall**: run
  the command from **Add worker** again, without the credential.
- **Codex:** log in on each worker that should run it (`codex login`, or set
  `CODEX_API_KEY` / `OPENAI_API_KEY` for the worker).

## v0.1.0

The first release: a dashboard server and workers on your machines, Claude Code
chats (with MiMo and OpenCode as alternatives) and a persistent Julia session
per project, media and live Bonito apps in the transcript, a file tree with a
Monaco editor, and desktop app bundles for Linux, macOS and Windows.
