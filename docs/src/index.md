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

The tour below is real: four claude-agent-acp sessions, a live WGLMakie app
detached into the workspace, files opened from the project tree, and the
dashboard keeping a rich preview of every chat.

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
- **Live results.** Through the built-in Julia MCP tools an agent can hand
  back a running Bonito app embedded in the chat. The computation stays in the
  worker's Julia session, so sliders and buttons round trip to real code.
- **Sessions that survive.** Chats persist on disk and reconnects resume where
  you left off. Existing Claude Code sessions on a worker can be imported and
  resumed. Half-open network links (suspend, a Wi-Fi to LAN switch) are caught
  by heartbeats on both ends and heal automatically.

## Where next

- [Getting Started](@ref): running everything on one machine, then adding more
  with a copy-paste one-liner.
- [Concepts](@ref): how server, workers, projects and agents fit together.
- [The Chat](@ref): what the transcript and workspace can do.
- [Julia Tools & Live Apps](@ref): `julia_eval`, `bt_show`, and live app
  embeds.
