# Shared by the MCP handshake, bt_help, and the server's session briefing.
const AGENT_WORKFLOW = """
# Working in BonitoAgents
You work in a chat attached to a project directory on a worker. Files and code
run on that worker, which may be a different machine from the browser or server.
Call `bt_help` for this workflow again after resuming or compacting a chat.

## Files and results
Use Markdown links such as `[source](./src/app.jl)` or
`[report](</absolute/worker/path/report with spaces.md>)`. Relative links resolve
from this chat's working directory, not from the browser URL or an earlier
shell `cd`. Verify that the file exists on this worker before linking it.
Use an absolute worker path for files outside that directory. Do not invent
dashboard URLs, server cache paths, sandbox:/ links or file:// URLs.
`bt_show(path; title=...)` embeds a file preview in this chat. `bt_share(path)`
creates a link for other people; ordinary file links are workspace navigation,
not public shares. Return a Bonito app or a plot from `bt_julia_eval` to show a
live result; no separate display tool is needed.

## Measurable progress
For long jobs such as renders, tests or batches, report actual completed work
with `bt_progress`: start once with a stable job id, update completed/total,
then finish, fail or cancel. This updates the chat and sidebar without adding
conversation messages. Unknown totals use indeterminate progress; never infer
percentages from tokens, elapsed time or merely launching a tool.
Inside `bt_julia_eval`, `BonitoProgress` is already available without adding a
project dependency:
```julia
BonitoProgress.progress("Render frames"; id="render", total=100, unit="frames") do job
    for frame in 1:100
        render_frame(frame)
        BonitoProgress.update!(job, frame)
    end
end
```
The do-block finishes on success and reports failure/cancellation on exceptions.
For an existing `(completed, total)` callback, pass a job from
`BonitoProgress.progress(...)`, then call `finish!`, `fail!` or `cancel!` yourself.
Use `primary=false` for secondary jobs and `status="paused"` for paused work.
ProgressLogging events are forwarded automatically; ProgressMeter is not an
integration. Other languages can call `bt_progress` through MCP. For a separate
Julia process, `bt_progress(action="context")` returns environment variables and
a stdlib-only `julia_client` file to load with Julia's `-L` option. Keep the
context local to the worker and call `BonitoProgress.flush_progress(job)` before
that process exits. Progress reports work; it does not launch, cancel or wait
for the underlying computation, and it does not change YOLO or agent busy state.

## Running, waiting and messages
Use `bt_julia_eval` with this project's absolute `env_path` for Julia work;
sessions retain variables, packages and compiled methods, and Revise picks up
source edits. For long work use `background=true`, keep the returned run id and
collect it with `bt_julia_wait(runs=[...], seconds=...)`. Use the agent's native
tracked command/background tools for other languages, when available.
Wait with `bt_wait(seconds=..., reason=...)`, optionally with an `until` shell
condition, rather than starting sleep/poll watcher tasks. Incoming messages can
wake a wait; read them and then continue the original work as appropriate.
Cross-chat messages are delivered according to their requested queue mode;
sending one is not evidence that the other agent has read it or finished work.
Only contact another chat when the user authorized coordination. Use the
available tools' descriptions for arguments and capability limits; remote Julia
and development controls are granted per chat, never assumed.
"""

workflow_instructions() = get(ENV, "BONITOAGENTS_INSTRUCTIONS", AGENT_WORKFLOW)

register!("bt_help", """
BonitoAgents workflow guide. Read at the start of work, or after resuming, to
discover progress reporting (bt_progress and the Julia BonitoProgress API),
worker-relative Markdown file links, previews and public sharing, persistent
Julia, background runs, waiting and cross-chat coordination. Returns the current
chat's base instructions, including configured server and app guidance.
""", Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
    _ -> Dict("content" => [Dict("type" => "text", "text" => workflow_instructions())]))
