# Julia Tools & Live Apps

Every chat exposes MCP tools backed by
[`BonitoMCP`](https://github.com/SimonDanisch/BonitoAgents.jl/tree/main/BonitoMCP):
the agent's window into a persistent Julia session per project, running on the
worker next to the code. `bt_julia_eval` is the heart of it: a warm REPL the
agent shares with you, where the result of an eval isn't a screenshot or a text
dump but the **live value**, rendered into the chat and still wired to the code
that produced it.

## Agent workflow and discovery

Every chat has a built-in workflow covering worker-side files, previews,
sharing, progress reporting, persistent Julia sessions, background work and
waiting. It is delivered through the MCP initialization `instructions` field
for all providers. The discoverable `bt_help()` tool returns the same briefing
when an agent needs to reread it after resuming or compacting. MCP clients
decide how to surface initialization instructions; `bt_help` remains available
as a tool. Each tool also describes its own arguments and limits.

Add your own server-wide rules in **Settings → Agent instructions**. They are
stored in the server's `AGENTS.md`, composed with the built-in workflow and any
app or development briefing, and read on agent session bring-up. Restart an
existing agent session to receive edits. Claude also receives the briefing via
its native system-prompt append; other providers use the common MCP path. This
does not write or replace the project's own `AGENTS.md` or `CLAUDE.md`.

### Worker file links

An agent can write `[source](./src/app.jl)` in its reply. Clicking it opens a
workspace tab for that file **on the chat's worker**, relative to the chat's
working directory. It is not relative to the browser URL or an earlier shell
`cd`. Absolute worker paths work too. For spaces, use an angle-bracket
destination, such as `[report](<./reports/render notes.md>)`, or percent-encode
the spaces. Check that a file exists before linking it; a link cannot repair an
invented path. Use `bt_show` for an inline preview and `bt_share` for a public
link. Avoid `sandbox:` URLs and paths to the server's internal cache.

## `bt_process`, supervised background commands

Use this for long external commands, independently of the agent provider:

```json
{"action":"start","id":"encode-1","argv":["ffmpeg","-i","input.mov","out.mp4"],"label":"Encode video"}
{"action":"wait","id":"encode-1","seconds":600}
{"action":"output","id":"encode-1","offset":0,"max_bytes":8192}
```

These are separate MCP calls. The **worker** owns the command, its process
group or Windows Job Object, output capture and exit record. Agent turns and
MCP reconnects do not own its lifetime. A launch appears in the existing chat
taskbar, including its label, worker, PID and directory. Expand the row to see
output. Its Stop button requests an interrupt; the same menu offers Terminate
and Force kill. Controls act directly on the worker, without prompting the LLM.

| Action | Meaning |
|---|---|
| `start` | Requires a stable `id` for this attempt and an `argv` array. Optional `cwd`, `label` and `env`. The directory defaults to the chat's worker directory. |
| `list` | This chat's retained jobs on its worker, including completed jobs. |
| `status` | Lifecycle, command, PID, exit code, signal and a bounded output tail. |
| `output` | Read from a byte `offset`; continue with `next_offset`. `max_bytes` is 1–65536. |
| `wait` | Requires `id` and `seconds`, at most 3600. Returns on exit, timeout or an incoming message, with `wait_reason`. It does not stop the job. |
| `interrupt` | Request SIGINT for the process group. Windows does not support this action; use terminate or kill. |
| `terminate` | Request graceful termination, SIGTERM on Unix. |
| `kill` | Force termination of the managed process group or Windows Job Object. |

`argv` is passed as arguments, not interpreted as shell syntax. If a shell is
needed, invoke it explicitly, for example `["sh","-c","make && make test"]`.
Do not add `&`, `nohup` or another detached watcher outside the supervisor.
Start is idempotent: repeating the same `id` returns its existing job rather
than launching another command. Use a **new id** for a new attempt.

A signal request produces `interrupting`, `terminating` or `killing`; the row
stays until the worker confirms exit. A failed control request remains visible.
Completed jobs report `succeeded`, `failed`, `interrupted`, `killed` or `lost`.
The worker continues tracking the group when the original Unix process exits
but leaves children running. Job Objects provide descendant ownership on
Windows. Processes that deliberately escape Unix process groups require stronger
OS containment; this API is not a sandbox for full-access code.

Closing or restarting a chat requests cleanup of its old session's jobs. A
session fence prevents delayed cleanup from killing replacement jobs, and
prevents the old session from launching new work. Disconnection does not imply
exit: the worker re-announces state on reconnect, and pending cleanup is retried.
A worker restart reaps its persisted running groups and records those jobs as
lost. Their retained output remains readable; `output_cursor_reset=true` means
to restart reading from offset zero. The supervisor captures ownership before
allowing a command to execute.

Output is a bounded rolling log, up to 8 MiB per job, with up to 256 job records
per worker and at most 64 active jobs. `output_truncated` reports dropped old
bytes. Environment overrides are not included in returned records. Progress-only
context and `BONITOAGENTS_PROCESS_ID` are supplied to launched programs, so a
coordinator can report progress using the same job id. `bt_progress` measures
work; it does not replace process supervision.

Use `bt_julia_eval(background=true)` and its run controls for ordinary Julia
work. Stopping an agent turn leaves managed background jobs running; use the
job's controls, or restart/close its chat, to end them.

## `bt_progress`, progress in the chat and sidebar

```
bt_progress(action, id; label?, completed?, total?, unit?, detail?, parent?, primary?, status?)
```

Progress belongs to a job, independently of whether the agent is busy. A render
or test batch can keep reporting while the agent waits or works on something
else. The chat shows the job, and its sidebar icon shows progress for the
primary job. Updates change the existing display instead of adding messages.

This is the single progress system for work inside a chat. Built-in file
transfers, sharing and “Continue on worker” report through the same job API as
`bt_progress` and `BonitoProgress`. They share one compact progress row and the
sidebar indicator, including completion, failure, dismissal and reload behavior.
Adapters may translate events from an operation into job updates; they must not
create another progress store, bar or percentage calculation.

From any MCP client, use a stable job id and report actual completed units:

```json
{"action":"start","id":"render","label":"Render frames","total":240,"unit":"frames"}
{"action":"update","id":"render","completed":60,"detail":"Worker 2 finished its batch"}
{"action":"finish","id":"render"}
```

These are three separate tool calls. Use `fail` with an error `detail`, or
`cancel`, when appropriate. An unknown `total` is `null` and shows indeterminate
progress. Set `status="paused"` on an update to retain a paused job. A new
`start` with the same id starts a new generation. Use `primary=false` for
secondary jobs and `parent` to associate child jobs with a parent's id. Do not
derive percentages from token counts, elapsed time or the act of launching a
command. The meter reports the underlying job; ending a meter does not stop a
render, and it does not change YOLO or the agent's busy state.

### Julia code and callbacks

Inside `bt_julia_eval`, `BonitoProgress` is already bound and needs no new
project dependency or `using` statement. For example, where `render_frame` is
your application's rendering function:

```julia
BonitoProgress.progress("Render frames"; id="render", total=240, unit="frames") do job
    for frame in 1:240
        render_frame(frame)
        BonitoProgress.update!(job, frame)
    end
end
```

The do-block finishes on return, reports exceptions as failures and reports an
interrupt as cancellation, then rethrows. If an API accepts a
`(completed, total)` callback, a job handle is itself callable:

```julia
job = BonitoProgress.progress("Render farm"; id="render-farm", unit="frames")
renderfarm!(...; progress=job) # your existing API's callback
BonitoProgress.finish!(job)   # after validating the result
```

With a manually managed handle, call `fail!`, `cancel!` or
`update!(job, completed; total, status="paused")` for other outcomes. Updates
are coalesced to at most five per second. Existing ProgressLogging events in
an eval are forwarded automatically; ProgressMeter is not integrated. The
repository's `examples/renderfarm_progress.jl` shows pause, failure and flush
handling for a render coordinator.

For a separate Julia process on the same worker, call
`bt_progress(action="context")`. It returns `env`, containing progress-only
environment variables, and `julia_client`, a stdlib-only file. Pass `env` into
the process environment and load the helper with `julia -L <julia_client>`;
this is a reporter for an existing external coordinator, not a reason to
replace `bt_julia_eval` for normal Julia work. Before exiting, call
`BonitoProgress.flush_progress(job)` and check its Boolean result. Keep the
context local; it grants progress reporting for this chat and must not appear
in public output. Other languages can call `bt_progress` over MCP; there is
currently no equivalent standalone language SDK.

## `bt_julia_eval`, a shared live REPL

```
bt_julia_eval(code; env_path?, timeout?, background?, worker?, full_output?, max_response_bytes?, julia_cmd?)
```

Each `env_path` runs in its own Julia subprocess (managed via
[Malt.jl](https://github.com/JuliaLang/Malt.jl)); top-level bindings, loaded
modules and compiled methods carry over between calls, so an agent iterating on
a package pays the load cost once instead of per tool call. Revise is loaded
when the session can see it, either in the project or in your global
environment, so source edits are picked up without a restart; it is never
installed into your project on your behalf. An `env_path` ending in `/test`
auto-activates TestEnv so the parent project's test deps are visible. Always
prefer this over `julia -e` through Bash, which spawns a cold process every
time.

Evaluation follows **REPL semantics**, not single-expression splicing: each
top-level statement runs on its own, so a `for` loop may assign to a global
(soft scope) and a function defined in one call can be called later in the same
call without a world-age warning.

### Streaming, not a black box

`timeout` is a **soft checkpoint**, not a hard kill. A call returns within
`timeout` seconds either `completed` (with the result) or still `running`; in
the running case it hands back the stdout captured so far. In the chat that
stdout streams into a small terminal pane under the header, always pinned to the
newest line, so a long build or training loop shows its progress live rather
than freezing the pill. When a call is still running the agent (or you) can:

| next | effect |
|---|---|
| `bt_julia_wait(runs = ["r4"])` | block until the run finishes (see below) |
| `bt_julia_continue(run = "r4")` | wait another `timeout` seconds |
| `bt_julia_interrupt(run = "r4")` | `SIGINT`; captures the partial output plus the `InterruptException`, session state preserved |
| `bt_julia_restart` | `SIGKILL`; a fresh process, loses all session state |

`bt_julia_list_sessions` lists the live sessions and the chat's runs. `timeout`
auto-disables for `Pkg.*` (installs are routinely multi-minute); pass
`timeout=0` to disable the checkpoint entirely.

### Runs: background evals and `bt_julia_wait`

```
bt_julia_eval(code; background = true, env_path?, worker?)
bt_julia_wait(seconds; runs?, until = "all" | "any", max_response_bytes?)
```

Every eval is a **run** with a short id (`r4`), named in its result. A run can
outlive the call that started it: `background = true` returns the id at once,
and a foreground eval that passes its checkpoint is the same run. That is how
one chat runs a test suite on several workers at once: start one background run
per worker (or env), then block on all of them with a single `bt_julia_wait`,
which returns each finished run's output and result (the tail; the whole log
stays on its worker and the result names its path).

The chat follows the run, not the call. Its card stays live, with its output
streaming in, until the run ends. Then it shows ✓ or ✗ with how long the run
took and, for a failure, the error's first line.
While the call is over and the run is not, the run has a row in the task bar
(`r4 · MacBook · BonitoAgents/test`) whose ⊗ stops that run and nothing else.
When a run the agent has not collected finishes and the agent is idle, the chat
tells it in a short app message, so it never needs to poll.

One run per env on a worker at a time: a second eval there is refused and
names the running one. A cancelled turn stops its foreground eval and leaves
background runs running.

### The result is the live value

Whatever the eval returns is rendered into the chat as a **live embed**, not a
text repr. A string (with its line breaks kept), a number, an array, a
`DataFrame`, an image, and, crucially, a Bonito `App` or a WGLMakie figure,
which stay *interactive*: a slider drag or a button click round trips to the
Julia object still living in the worker's session. The value is held in the
worker and rendered on demand (serialize-on-mount over a proxy bridge), so the
same result survives collapsing and re-expanding the card, and even a browser
reload.

Because the value is displayed, it never also gets dumped as text: the **Output
section shows captured stdout only** (and is absent entirely when the code
printed nothing). A returned `App` shows the running app, not
`App(#= opaque closures =#)`. The agent still learns what the result was (a
concise repr rides along for it), but your view is the thing itself.

Live embeds are workspace panels like any other. Detach one from its chat
bubble (the ⤢ button) into a floating window or a tab beside the chat and it
stays alive: the same live DOM node is moved, so the WebGL context and
sub-session are kept, not re-created. Scrolling a live embed out of view parks
it (`display:none`) rather than removing it, so its plot doesn't come back dead;
a bounded LRU caps how many stay live at once.

### The eval card

A `bt_julia_eval` pill expands into a body with **Code** and **Output**
sections and the live result below them. Each section is a three-state
collapsible that opens on a **summary**, grows to the **full** content on the
next click and closes on the one after. The summary is a scrollable ~4-line
window onto the content, not a truncation (the scrollbar belongs to the
section, so nothing is ever clipped away), and for streaming output it stays
pinned to the newest line. The card can also be widened to the full chat column
(the » toggle) when a plot or wide table wants the room. A completed eval that
returned a value auto-expands so you see the result without a click; one that
returned `nothing` stays compact.

### Output discipline, enforced server-side

Prompt rules like "always end with `nothing`" are unreliable, so the tool layer
enforces hygiene instead:

| Situation | Behavior |
|---|---|
| Response over `max_response_bytes` (10 KB default) | truncated with a `[truncated: …]` marker |
| `nothing` return | suppressed, no wasted tokens |
| Container with hundreds of elements | summarized (`Vector{Int} with 500 elements; first 10: …`) |
| A user error | red `ERROR: …` in Output plus the exception rendered as a live result; the tool stays `completed` (an infra failure is a different, `isError` case) |
| `full_output = true` | bypasses truncation and summarisation |

The agent sees what it needs, and a stray `rand(10_000, 10_000)` cannot blow up
the context window.

### Running on another worker

```
bt_julia_eval(code; worker = "MacBook", env_path?, timeout?, …)
bt_sync_folder(src, worker; dst?, direction="push", paths?)
```

Every eval-family tool takes a `worker`: the display name of another online
worker. The call then runs there instead of on the chat's own worker, in that
machine's own sessions (its own `env_path`s and state; `bt_julia_continue`,
`bt_julia_interrupt` and `bt_julia_restart` address them with the same
argument, and a run id reaches its run wherever it runs). Under the hood the chat's MCP asks the server, the server spawns a
BonitoMCP *eval host* on the other worker for this chat (once; it lives as long
as the chat's session), and relays the call. The card in the chat wears a filled
**⇢ MacBook** badge next to the tool name, its live stdout streams in as usual,
and a returned plot or app renders live over that machine's own bridge into the
chat, so live results from both machines stay live side by side. (Two `env_path`s
on the SAME worker still share one bridge: there the newer session's embeds
retire the older one's.)

This is **off by default**. An admin switches it on per chat with *Remote julia*
in the chat's ⋯ menu. The server enforces it at relay time, so switching it on
needs no restart, and switching it off ends the chat's evals on other machines.
While it is off a call with `worker` fails and tells the agent where the switch
is. `bt_julia_list_sessions` lists the other workers (and their live sessions)
so the agent can find the names.

The other machine has its own filesystem. `bt_sync_folder` streams folders
through the server's existing worker connections, transferring only changes
and preserving destination-only files. It needs the same switch.

- `direction="push"` (default): `src` is on this chat's worker; `dst` is on `worker`.
- `direction="pull"`: `src` is on `worker`; `dst` is on this chat's worker.

Both paths are absolute; omitted `dst` defaults to the same path as `src`.
For example, retrieve results from Desktop into this chat's worker:

```julia
bt_sync_folder(src="/data/results", worker="Desktop",
               dst="/work/results", direction="pull")
```

No direct sockets, SSH setup or second chat are needed. Remote Julia evals
do not change this tool's source: direction is relative to the chat's worker.

Folders are recursive: use **one call for the whole tree**, rather than one
call per file. For a selected batch, set `src` to a common root and pass relative
files or subfolders in `paths`. Subfolders are recursive, overlapping selections
are deduplicated, and destination paths retain their structure:

```julia
bt_sync_folder(src="/data/results", worker="Desktop", dst="/work/results",
               direction="pull", paths=["summary.csv", "frames", "logs/render.log"])
```

Omit `paths` for the whole folder. Paths are literal (no glob expansion); missing
or escaping paths fail. Update the server for pull/batch support and the source
worker for selections. Older versions refuse the new operations instead of
accidentally pushing in the wrong direction or sending the entire folder.
Every transfer automatically reports measured file counts and transferred bytes
through the existing chat progress bar and sidebar indicator. Completion is shown
after the destination confirms its writes; failures remain visible. No separate
`bt_progress` call or repeated sync polling is needed.

### Julia values between machines

```julia
r = remote_session("MacBook"; env_path = "/Users/me/proj")
r[:data] = data            # `data` is set in the session there
model = r[:model]          # its `model`, here
y = r(f, x; k = 1)         # f(x; k = 1) runs there, the value comes back
```

Inside the chat's own session, `remote_session` (defined in every session)
reaches the session that `bt_julia_eval(worker = "MacBook", env_path = …)` runs
in, starting it if needed. The chat's session is the one that asks; the other
only answers. Values travel with `Serialization`, streamed in 1 MiB pieces, so
their size is not limited by the websocket layers in between. That also means
both sessions need the same Julia version (checked first; a mismatch is an
error naming both) and the packages that define a value's types loaded. A
function passed to `r(…)` runs there: an anonymous one travels with its code (it
cannot take keyword arguments: Serialization does not carry the hidden function
those compile to), a named one (or `r(:name, …)`) must exist there, and the
globals it reads are the other session's. A failure on the other side comes back as a
`RemoteSessionError` with its message and backtrace, and the connection stays
usable. Needs the chat's *remote julia* switch, like everything above.

The route: the session connects to its worker's relay over loopback TCP, the
server checks the switch, has the chat's eval host on the other worker connect
the session asked for, and pipes the two together; it never reads the values.

## `bt_chat`, opt-in coordination

```julia
bt_chat(action="list")
bt_chat(action="send", project_id="<peer id>", text="The render is ready.")
```

Chat messaging is **off by default**, including after upgrading existing chats.
The user enables **Chat messaging** in the ⋯ menus of **both** chats before
agents can exchange messages. Only opted-in chats owned by the same user appear
in the list. Use this tool when the user has authorized coordination.

The permission is independent of dev mode and takes effect without restarting
the agent. Turning either chat's switch off immediately rejects new sends and
pauses queued peer input that has not been handed over. It remains paused across
reloads and re-enabling; the user can queue it again or remove it. Messages already
handed to an agent remain part of its conversation.

Sending returns `status="queued"`, a message id and a server UTC timestamp.
Acceptance is not confirmation that the receiving agent has received/read it or
finished work. Peer messages follow the existing queue-after-current-message
delivery path, including supported steering and wakeups during `bt_wait` or
managed-process waits. Sender chat/worker identity and send/dispatch timestamps
are attached automatically. The receiving agent can use the same tool to reply.

The legacy `bt_dev_control(op="send_message")` uses the same opt-in checks. Dev
mode does not grant messaging, and stale dev-tool calls are refused by the server
as soon as dev mode is switched off.

## `bt_share`, a link for anyone

```
bt_share(path; title?, password?, env_path?)
```

A link to a file on the chat's worker that anyone can open without an account,
for as long as the worker is online (`https://<server>/s/<token>/`):

- **A markdown file** becomes a page, rendered like the chat renders. The images
  and videos it embeds by relative path come along (`![](clip.mp4)` becomes a
  video); nothing else in its folder is reachable through the link, and scripts
  in its raw HTML do not run.
- **A Julia file whose value is a Bonito app** (or anything `bt_julia_eval`
  would show live) becomes a live page. A *share host* on the worker, one per
  worker, evaluates the file in its project's environment (`env_path`, by
  default the nearest folder above it with a `Project.toml`) and every viewer
  gets their own render, as with a chat's eval result. The file is evaluated
  again when it changes, and once when it is shared, so an error in it reaches
  the agent. Interactive markdown is such an app:
  `using Bonito, Markdown; App() do; s = Bonito.Slider(1:10); DOM.div(md"Pick: $(s)"); end`
  (a plain Julia file: it loads what it uses).
- **Other files** are served directly, including images, videos and documents.
  Only that file is reachable; HTML and SVG are sandboxed without scripts.

You can also click **Share** on a `bt_show` preview or a successful
`bt_julia_eval` result, then open or copy the generated link. A live result is
shared as the value already displayed: its eval code is not run again, and
viewers can interact with the app. That link needs the original Julia session
and result to stay open. Closing the result or restarting its Julia session
ends its availability. To make an app restartable, save it as a Julia file and
share that file with `bt_share`.

The token is the permission; a password can be set on top. Settings lists your
links (an admin sees all): open, copy, set or remove the password, end. Behind a
tunnel the login gate lets a link's page, its websocket and its assets through
and nothing else; behind the Caddy login proxy only the pages are open, so an
app link there needs a logged-in viewer.

## `bt_wait`, pausing a turn

```
bt_wait(seconds; until?, poll?, reason?)
```

The one way an agent can be idle on purpose. A tool call is what pauses a turn,
because the agent blocks on its result, so this is that shape with nothing
inside it: no subprocess, no task-bar entry, no completion notification, because
the result *is* the completion.

It exists because the alternatives are worse. A foreground `sleep` is blocked by
the harness and a backgrounded command returns immediately, so an agent waiting
on a forty-minute render ended its turn, was re-invoked seconds later, saw the
job still running, and started another sleeper to poll with. One session left
over a hundred orphaned sleep processes behind, each firing its own notification
on expiry.

`seconds` is required, even together with `until`, and capped at an hour: an
unbounded wait on an event that may never arrive is a wedged chat. `until` is a
shell condition, re-checked every `poll` seconds (5 by default) and returning
the moment it exits 0, so `bt_wait(600; until = "test -f out/done.flag")` costs
only as long as the job does. Reaching the bound is a normal result, not an
error: the agent gets a plain "not yet" and decides, one round trip per hour
instead of one per eight seconds.

## `bt_show`, a file into the chat

`bt_show(path)` renders a worker-side file into the transcript, as whatever the
file is: images and video inline (click for a lightbox), audio with a player,
markdown rendered, CSV as a sortable table, notebooks with their outputs, 3D
models (`.obj`/`.stl`/`.ply`/`.off`/`.glb`/`.gltf`) in an interactive view
(glTF and OBJ with their textures and materials), PDF in the browser's own viewer, HTML in
a sandboxed frame, source as syntax-highlighted code, and opaque bytes as a hex
dump. These are the same renderers you get when
you open the file as a tab, so a file looks the same whichever way you reached
it.

`bt_show(path; title = "Loss after 200 epochs")` names what the file shows. The
card wears that title, with the file's name and size beside it, and is named
after the file without one. Hovering the title shows the file's full path, and
clicking it opens the file in a tab. A picture or video shown bare in the chat
keeps the title as its caption.

`bt_julia_eval` already auto-saves rich values (Makie / Plots figures, color
matrices) to `<env>/.bonitoAgents/show/` and reports the path, so the usual flow
is: eval a figure, then `bt_show` its path when the user should see the picture
rather than interact with it. The file is fetched from the worker on demand, and
re-fetched exactly when the worker's copy changed, so re-rendering a plot to the
same `/tmp/plot.png` shows the NEW picture, not the one from the first `bt_show`.

Media URLs refer to the worker's disk path and survive closing or reloading a
chat, even when the output was never viewed. Serving a file does not require a
live Julia evaluation session. Keep the source file on disk and the worker
connected; `bt_show` is a view of that file, not an archived snapshot. Updated
workers support byte-range reads for seeking; older workers transfer the file
to the server first.

## Live apps, from one returned value

There is no separate "show app" tool: an interactive app is just a value
`bt_julia_eval` returns.

```julia
using WGLMakie, Bonito
App() do
    rho = Slider(10:0.5:60)
    fig = Figure()
    ax = Axis3(fig[1, 1])
    density = map(rho) do r
        lorenz_visit_density(r)   # recomputed in the worker on every drag
    end
    surface!(ax, density)
    DOM.div(rho, fig)
end
```

Returned from an eval, this renders running in the chat; dragging the slider
recomputes the attractor in the worker and morphs the surface in your browser.
Detach it beside the chat and keep steering it while you read the code that
built it. That whole loop, from the agent building the app to steering it to
docking it beside its source file, is the second video on the
[home page](index.md), recorded against a real agent session.
