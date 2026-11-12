# Changelog

What changed in each BonitoAgents release. The guides are at
[agents.bonito.sh](https://agents.bonito.sh), and
[A Day with BonitoAgents](https://agents.bonito.sh/stable/story.html) shows how the
pieces fit together.

## Unreleased

### Fixed

- A `bt_process` wait shows its job while it waits: the command, where it runs
  and its output, which updates as the job writes. The card used to say
  "(loading…)" until the wait returned, for up to an hour.
- A background command's ending is no longer sent to the agent again when its
  own `bt_process` wait or status call already returned it. That note came
  after the turn and started a new turn just to repeat it.
- An app's chat that was continued on another worker is found by its key
  (`app_chat(server, app, key)` takes the newest), so an app's links to it
  follow the move.

## v0.2.2

### Fixed

- A chat is free again once Claude's reply is over, also while a background
  agent it started runs. Claude's adapter holds the prompt open until that agent
  ends, so the chat looked busy and messages queued "for when done" waited for
  the background agent, sometimes for an hour.
- A background agent that Claude runs again with SendMessage is back in the task
  bar until it ends, also one from before a server restart.

## v0.2.1

Build your own apps without leaving the chat. An agent writes the app package,
shows you its views live in the conversation, and loads it into your running
server once you approve.

### Added

- `bt_load_app` loads an app package into the running server, from the chat
  that wrote it, without a restart. Every load waits for an admin to approve it
  on a card in the chat, and the agent can't answer that card. Its tile then
  appears on the open dashboards, and chats started from then on get its tools.
  It works from the server's own machine: in the desktop app, and on any server
  that can write its Julia environment.
- The dashboard's Apps section follows the server's apps, so a new app's tile
  shows up without a reload.

### Changed

- The README and the documentation lead with building your own apps. The Apps
  guide, now **Build Your Own Apps**, starts with a prompt to paste into a chat.
- At startup the server runs only the apps of packages marked as plugins, not
  every app some loaded package registered.

### Fixed

- An app returned into the chat failed with a `MethodError` when it showed
  changing state, an Observable holding DOM. It renders now, so an agent
  building an app can show the app's views in the chat.
- A Windows bundle unpacked by hand starts: its launcher creates the app's data
  folder, which v0.2.0 left to the installer.
- The README's links into the documentation pointed at pages that don't exist.

## v0.2.0

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
  the loop and switch Yolo off. Losing the agent connection pauses the loop and
  keeps Yolo on, with the connection error shown in the chat.
- **Stop** spares background subagents, and the agent is told about tasks a
  stop interrupted. Pending cancellation is visible after reload too, with a
  **Force stop** action for an agent that does not respond. The next message
  reconnects without needing the chat's Restart action.
- Message queues are explicit: queue for when the agent is done, after the
  current message, or interrupt and send.
- Passwords for `sudo` and `ssh` are typed into the chat. `bt_sudo` runs a
  command as root, on the worker or, with `ssh`, on a server through a
  connection that `bt_ssh` opened. That connection's control socket also lets
  later ssh, scp and rsync calls log in without asking. Each question sudo or ssh asks shows as
  a card naming the command, and also appears after a reload. The answer goes
  from the card through the worker to sudo or ssh, never to the agent.

### Machines and workers

- WorkerLink: one resumable, multiplexed connection per worker. MCP traffic and
  eval bridges ride it through the worker's relay, so no extra ports or paths
  are needed.
- Run Julia on another worker from the same chat (`bt_julia_eval(...; worker =
  "name")`), switched on per chat by an admin with **Remote julia**.
- `remote_session` moves Julia values between machines; `bt_sync_folder`
  streams folders between workers through the link. Use `direction="pull"`
  to retrieve results or `paths` to batch selected files and recursive folders
  in one call. Transfers automatically report progress in the chat and sidebar.
- Successful progress jobs show “Completed”, then clear from the chat and
  sidebar after five seconds and stay hidden after reload. Running jobs at
  100% remain visible until completion is confirmed; failures wait for dismissal.
- Peer coordination uses `bt_chat` and a separate **Chat messaging** switch,
  off by default in both chats. Dev mode never grants messaging. The server
  immediately enforces permission revocation, including stale dev-tool calls;
  queued peer input is paused until explicitly retried.
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
- `bt_show` takes a `title` for what the file shows. The card wears it, with
  the file's name and size beside it, the full path on hover, and a click on it
  opens the file. A picture shown bare keeps it as its caption.
- Re-showing an overwritten image requests fresh pixels even when Read or
  another preview already displayed that path. The browser can no longer reuse
  the first decoded image without contacting the worker-file route.
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

- **Delete a chat for good.** From the chat's ⋯ menu or its card in the recent
  chats overview: removes the transcript and shared links, with options to delete
  the agent's saved session and wipe shared project memory. Project files stay.
- **Faster page loads.** A worker's list of past sessions is built when you open
  it, not with every page. A page with hundreds of past sessions, on a phone
  especially, no longer waits for rows it isn't showing.
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
- A `bt_process` card now says what the call did and how it went, such as
  "Wait for Build docs · failed · exit 3", with a red pill when the job failed.
  Opening it shows the command, folder, worker and output.

### Developer tools

- **Debug BonitoAgents** opens an agent on a BonitoAgents checkout on the worker
  you choose. Dev mode adds tools for the running system: server and worker
  state, logs from every machine, browser tabs and their consoles, timings and
  memory.

### Fixed

- The desktop app starts on macOS and on a fresh Windows install. macOS killed
  v0.1.0's bundled Julia at launch, and a first Windows install exited before
  it served anything. CI now installs and starts every bundle, on every
  platform, before it is released.
- Queuing a message during a reply no longer leaves the chat permanently busy
  when an agent advertises a separate steering API. Overlapping prompts require
  explicit prompt-queueing support; otherwise messages wait for the current turn.
- A Codex chat in Yolo mode no longer re-prompts an account that hit its usage
  limit. One chat sent 10,294 auto-continues in 2.5 hours before this fix,
  because the failure arrived as a normal turn end and the compaction step
  counted as work.
- A Claude chat no longer stays busy after Claude compacts it on its own.
  claude-agent-acp 0.101 compacts a chat that has been idle for 54 minutes, and
  nothing marks where that compaction ends, so the chat showed as working until
  you force-stopped it. A compaction now never counts as the agent working.
- Stop stops. A background run or task that ends after you pressed Stop (or
  restarted the chat) no longer starts a new turn with its note; the note waits
  in the queue and goes to the agent with your next message.
- Logging in on one device no longer logs out another. Authelia's in-memory
  session store could overwrite one browser's session with another's.
- An error page with a long stack trace no longer stalls the server while it
  compiles a renderer for that length.
- Logging a rendering error no longer prints a whole live chat.
- A worker that loses its ID file restores its identity from its config. If both
  are gone it reports an error and doesn't register as a different worker.
- Shared pages show the BonitoAgents icon in the browser tab.
- JSON results from `bt_progress` and the dev tools show as JSON. As Markdown their
  lines ran together, and `--` and `_` turned into formatting.
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
- **From source:** BonitoAgents now uses the registered Bonito 5.3 instead of a
  git branch.

## v0.1.0

The first release: a dashboard server and workers on your machines, Claude Code
chats (with MiMo and OpenCode as alternatives) and a persistent Julia session
per project, media and live Bonito apps in the transcript, a file tree with a
Monaco editor, and desktop app bundles for Linux, macOS and Windows.
