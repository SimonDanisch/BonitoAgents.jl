# BonitoAgents Feature List

The full feature inventory, grouped by area. The README summarizes; this file
enumerates.

## Multi-machine orchestration

- One dashboard server and any number of **workers** that dial out to it (only
  the server needs a reachable address).
- Stable worker identity across reinstalls, reboots, and IP/hostname changes;
  UI renames persist server-side.
- Copy-paste **worker install one-liner** (Linux/macOS `install.sh`, Windows
  `install.ps1`) served by the dashboard itself: prereq checks (node, npm,
  claude, claude-agent-acp), a shared `@bonito-agents` Julia env pinned to the
  server's code revision, and a systemd user service on Linux. Re-run to
  update.
- **Link liveness**: a server-to-worker heartbeat kills half-open "zombie"
  sockets (suspend, a Wi-Fi to LAN switch) and flips the worker offline within
  a minute; the worker watches for the server's pings, re-dials over the
  current network, and reaps agent sessions the server abandoned. Requests
  against an unreachable worker fail fast with a toast instead of hanging.
- librsync-based directory sync for project import and moves between workers;
  single-file transfers over a dedicated channel.

## Projects & sessions

- Create projects by **Discover** (scan a worker for existing Claude Code
  session folders and import with conversation history), **folder picker**
  (any directory on the worker), or **From GitHub** (clone onto a worker).
- Chat history persists server-side per project; reopening renders instantly
  from disk. Claude-side history is reconciled on open and after compaction
  (message-order invariant, no duplicates).
- **Lazy agent binding**: opening a chat costs nothing; the agent process
  starts on the first message. A bounded LRU reaps idle agents, and the next
  turn re-binds with the same session context.
- Browser sessions survive disconnects (phone pocketed, laptop lid closed);
  the tab reconnects to the same session with observables intact.
- Multiple chats and tabs open at once; state broadcasts to every connected
  view.

## Agents & providers

- Pluggable **ACP providers**: Claude Code (default), MiMo, OpenCode, plus a
  deterministic scriptable **mock agent** for demos and tests (no API key).
- Per-chat provider dropdown, resolved on the worker (binaries checked where
  they run); switching providers takes effect on the next turn.
- Session **resume**: continue an existing Claude Code session from the
  dashboard, history included.
- **Permission prompts** (ACP elicitations) render as inline forms. **Yolo
  mode** auto-continues "shall I go on?" pauses and tells the agent how to
  bail out deliberately.
- Reliable **stop**: cancel escalates (cancel, re-cancel, force-close) so even
  a hung agent yields.
- **Compact** button: agent-side conversation summarization with clean
  transcript reconciliation afterwards.

## The transcript

- Live **streaming** of prose (CommonMark and syntax highlighting), tool
  calls, thoughts, and plans.
- **Tool pills** expand in place: Monaco diff viewers for edits, scrollable
  terminal output for shell commands, match lists for searches, and code
  preview plus stdout/result/error sections for `julia_eval` calls (with a
  timeout badge and per-tool stop button).
- **Todo and plan lists** the agent maintains are pinned to the taskbar with
  live status (pending, in progress, completed) while the turn runs.
- **Subagent activity feeds** inside the parent Task pill, including output
  arriving between turns from background subagents (pinned to the taskbar with
  a staleness badge).
- **Background tasks** (long test runs, builds) stay pinned across turns with
  live line counts, monitored until their writer exits, with per-task stop.
- Inline **images and videos** with hover copy/download and a click
  **lightbox**; code blocks with hover copy/download.
- **Virtualized transcript**: only the visible window is in the DOM, history
  backfills lazily in the background (paused for hidden panes), and the reading
  position is content-anchored, so geometry churn, tab switches and reconnects
  never move what you are reading. Follow-mode chases streaming output;
  scrolling up disengages it with a "move to bottom" control.
- **Search lens** over the transcript: type filters (`/` picker) and fuzzy
  text, with saved lenses.
- Messages typed during agent restarts and reconnects are queued, never
  dropped.

## Files & workspace

- Sidebar **project file tree**: lazy directory loading, fuzzy full-index
  search (VSCode-style), download affordances.
- **Monaco file editor** that saves back to the worker (`Ctrl+S`). Opening
  always fetches the file fresh from the worker; re-activating an open panel
  live-updates a clean buffer and never clobbers unsaved edits. A pre-open
  guard refuses folders, binaries and oversized files with a clear toast.
- File paths in tool pills are clickable and open in the editor.
- **VSCode-style workspace** (BonitoWidgets): chat, editors and app embeds as
  panels that drag into tab groups, split, float, and dock back.

## Julia tools (BonitoMCP)

- `julia_eval`: a persistent Malt session per project env, where packages,
  variables and compiled methods stay warm and Revise picks up edits.
- **Output discipline enforced at the tool layer**: truncation with markers,
  large-container summarization, color matrices and figures returned as
  images, and a `full_output` bypass.
- `bt_show`: render worker-side files (images, video, text) into the chat.
- `bt_show_app`: embed a running Bonito app into the chat, with interactions
  round-tripping to Julia in the worker's eval session. Embeds detach into
  tabs or floating windows and stay alive (WebGL context and sub-session kept,
  bounded by an LRU with park/resume).

## Deployment

- **Desktop**: `julia -m BonitoAgentsApp` runs the server and a local worker in
  one process with a persistent platform data dir; AppBundler bundles (snap,
  dmg, msix) are built by CI for every push and `v*` tag.
- **Server**: `bonitoagents server` mode or the systemd installer
  (`install_server.sh`), with persisted worker secret and public-URL handling.
- Worker installs always match the server's running code revision (branch,
  sha, or the version's `v` tag for git-less release deployments);
  `BONITOAGENTS_INSTALL_REV` overrides for ops.
- Shared-secret worker auth; the dashboard is designed to sit on localhost, a
  VPN, or behind reverse-proxy auth.

## Development & QA

- `dev_server()`: the whole stack (server, real worker subprocess, mock agent)
  against ephemeral tempdirs, wiped on close.
- Scriptable mock-agent event DSL (text, tools with diffs, todos, forms,
  subagent feeds, live apps, real `julia_eval`, pacing, cancellation).
- Black-box e2e suite driving a real dev server through headless Electron
  (DOM in, rendered DOM out; no server introspection; retries forbidden), plus
  fast headless unit items.
- Recorded walkthrough (`examples/walkthrough.jl`) with an animated cursor.
- Bonito-based documentation site (`docs/`).
