# A Day with BonitoAgents

You're fixing a rendering bug. The GPU and test scenes are on your desktop;
you're working from a laptop. The goal: a tested patch, results you can inspect,
and a demo another maintainer can try.

## Run where the hardware is

Open the dashboard, choose the desktop's checkout and start a chat with an ACP
agent such as Claude Code or Codex. It runs beside the GPU and data. Each
machine has a worker connecting to your self-hosted server; you drive them from
one browser.

**Discover** imports existing Claude Code and Codex terminal sessions with their
history. `bt_sync_folder` transfers a folder or a selection of files between
workers.

[Getting Started](@ref) · [Workers & Machines](@ref)

## Make the agent show its work

The agent says it's fixed. Ask for a before/after render and a benchmark.

With `bt_show`, images, videos, meshes and tables open in the conversation.
Scrub through the video, rotate the model, inspect the benchmark CSV. Open the
source and results in workspace tabs beside the chat while you iterate.

These viewers work with files from any language. Your renderer can be Julia,
C++, Python or Rust.

```@raw html
<img src="assets/screenshot-media.png" alt="Agent output shown in the workspace: a plot, video, 3D model, notebook and metrics table"
     style="display: block; width: 100%; margin: 16px auto; border-radius: 10px; border: 1px solid rgba(128,128,128,0.25);">
```

[The Chat](@ref)

## Switch agents, keep the task

Codex hits its usage limit halfway through the fix. Pick Claude Code in the
chat's header and continue. BonitoAgents supplies the conversation so far; the
new agent works on the same files with the same BonitoAgents tools.

Your project is an ordinary git checkout. Transcripts live on your server as
markdown, and agents use your own subscriptions or API keys.

[Agent Providers](@ref)

## Turn the experiment into a live app

The fix depends on a threshold. Ask the agent to build a Bonito app with a
slider and a live plot. It returns the app into the chat; dragging the slider
reruns the computation on the worker. Detach it beside the source while you
adjust the implementation.

Persistent Julia sessions keep packages, data and compiled code warm between
calls. With **Remote julia** enabled, the agent can also run code on another
worker and bring the result into this chat.

[Julia Tools & Live Apps](@ref)

## Share the app or video

Another maintainer should be able to inspect the result too. Click **Share** on
a preview, or ask the agent to use `bt_share`.

Send the comparison video: they can watch it in their browser. Share a markdown
report and its images and videos come along. Or share the Bonito app itself:
they open the link, move the slider and explore the same experiment, with the
computation running on your worker. Each visitor gets their own app view.

With the default tunnel setup, recipients need a browser and the link, without
a BonitoAgents account. The worker stays online to serve the file or app. Links
can have passwords, and you can revoke them from Settings.

For a demo that can restart, have the agent save the app as a Julia file and
share that file. You can also share a live result directly from the chat while
its Julia session stays open.

```@raw html
<img src="assets/screenshot-share-phone.png" alt="A shared Bonito app running on a phone, with an interactive plot and slider"
     style="display: block; width: 300px; max-width: 100%; margin: 16px auto; border-radius: 10px; border: 1px solid rgba(128,128,128,0.25);">
```

A maintainer finds a parameter combination you missed. Send that case back to
the agent and keep iterating.

[Julia Tools & Live Apps](@ref)

## Review the patch and finish the run

**Review changes** opens the git diff, including new files. Use **Ask** on a
line to send a question with its code context, or collect several review notes
with **Feedback** and send them together.

Start the final test suite or render as tracked background work. Running jobs
have taskbar controls; progress reports appear in the chat and sidebar. Check
from your phone, answer a permission prompt or send a correction while the
worker continues.

Enable **Yolo** when you want the agent to continue through follow-up tasks with
your reminders attached. Usage limits and repeated answers without work stop
the loop. Closing the browser leaves the worker running.

Once the tests pass, the patch, benchmark results and working demo are ready
for review.

[Reviewing changes](@ref) · [Staying in control](@ref)
