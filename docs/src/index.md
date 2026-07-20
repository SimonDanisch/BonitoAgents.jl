# BonitoAgents

BonitoAgents is a self-hosted dashboard for coding agents. A small worker
process runs on each machine that has code on it; all workers dial out to one
dashboard server; you control every agent session from a single web UI, from
your desk or your phone. Nothing runs in a cloud, and the agents work on your
checkouts with your own Claude subscription.

!!! warning
    Use at your own risk: there are no safeguards (yet) preventing an LLM
    driven through BonitoAgents from wiping your entire PC or leaking all your
    secrets.

The dashboard is the home base: every chat on every machine is a live card with
a thumbnail from its own plots, and you switch between projects straight from the
cards or the sidebar.

```@raw html
<video src="assets/dashboard.mp4" controls autoplay muted loop playsinline
       style="width: 100%; border-radius: 10px; border: 1px solid rgba(128,128,128,0.25);">
</video>
```

And every chat is real: claude-agent-acp sessions driving `bt_julia_eval`. Here
the agent returns a live curve-fitting dashboard, its degree slider is steered
from underfit to overfit with the RMSE updating live, a streaming
cross-validation sweep finds the best degree, and the app is detached into the
workspace and docked beside the chat, still interactive.

```@raw html
<video src="assets/walkthrough.mp4" controls autoplay muted loop playsinline
       style="width: 100%; border-radius: 10px; border: 1px solid rgba(128,128,128,0.25);">
</video>
```

## What you get

- **One dashboard for all machines.** Projects on your laptop, desktop and
  build server appear side by side. Start a refactor on one, review a diff on
  another, answer a permission prompt from the couch.
- **Rich transcripts.** Agent turns stream live: prose, tool calls as pills
  that expand into Monaco diff viewers and terminal output, images with a
  lightbox, plans and todo lists pinned to a taskbar.
- **A real workspace.** A searchable project file tree, a Monaco editor that
  saves back to the worker, and a VSCode-style layout where files, chats and
  live apps drag into tabs, splits and floating windows.
- **Live results.** The built-in `bt_julia_eval` tool is a warm Julia REPL the
  agent shares with you: its output streams live, and whatever it *returns*
  (a plot, a table, a running Bonito app) embeds into the chat as the real
  value, still wired to the worker's session, so sliders and buttons round trip
  to real code.
- **Sessions that survive.** Chats persist on disk and reconnects resume where
  you left off. Existing Claude Code sessions on a worker can be imported and
  resumed. Half-open network links (suspend, a Wi-Fi to LAN switch) are caught
  by heartbeats on both ends and heal automatically.

## Where next

- [Getting Started](@ref): running everything on one machine, then adding more
  with a copy-paste one-liner.
- [Concepts](@ref): how server, workers, projects and agents fit together.
- [The Chat](@ref): what the transcript and workspace can do.
- [Julia Tools & Live Apps](@ref): `bt_julia_eval`, a shared live REPL whose
  results embed as interactive apps, plus `bt_show`.
