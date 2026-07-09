# BonitoAgents

BonitoAgents is a **self-hosted dashboard for coding agents**. A small worker
process runs on each machine that has code on it; all workers dial out to one
dashboard server; you steer every agent session from a single web UI — from
your desk or from your phone. No cloud in the middle: your projects, your
hardware, your Claude subscription.

![The chat: streaming plan, Monaco diff, terminal output and a live app](assets/screenshot-chat.png)

## What you get

- **One dashboard for all machines.** Projects on your laptop, your desktop
  and your build server appear side by side. Start a refactor on one, review
  a diff on another, answer a permission prompt from the couch.
- **Rich transcripts.** Agent turns stream in live: prose, tool calls as
  compact pills that expand into Monaco diff viewers and terminal output,
  images with a lightbox, plans and todo lists pinned to a taskbar.
- **A real workspace.** A searchable project file tree, a Monaco editor with
  save-back-to-the-worker, and a VSCode-style layout: drag any panel — files,
  chats, live apps — into tabs, splits and floating windows.
- **Live results.** Through the built-in Julia MCP tools an agent can hand
  back a *running* Bonito app, embedded into the chat. The computation stays
  in the worker's Julia session, so sliders and buttons round-trip to real
  code.
- **Sessions that survive.** Chats persist on disk and reconnects resume
  where you left off. Existing Claude Code sessions on a worker are
  discovered and can be resumed in the dashboard. Zombie network links
  (suspend, Wi-Fi → LAN switches) are detected by heartbeats on both ends and
  heal automatically.

![Split workspace: chat beside the built-in editor](assets/screenshot-workspace.png)

## Where next

- [Getting Started](@ref) — running everything on one machine in two minutes,
  then adding more machines with a copy-paste one-liner.
- [Concepts](@ref) — how server, workers, projects and agents fit together.
- [The Chat](@ref) — everything the transcript and workspace can do.
- [Julia Tools & Live Apps](@ref) — `julia_eval`, `bt_show`, and live app
  embeds.
