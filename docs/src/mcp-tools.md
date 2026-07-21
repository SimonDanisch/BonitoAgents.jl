# Julia Tools & Live Apps

Every chat exposes MCP tools backed by
[`BonitoMCP`](https://github.com/SimonDanisch/BonitoAgents.jl/tree/main/BonitoMCP):
the agent's window into a persistent Julia session per project, running on the
worker next to the code. `bt_julia_eval` is the heart of it: a warm REPL the
agent shares with you, where the result of an eval isn't a screenshot or a text
dump but the **live value**, rendered into the chat and still wired to the code
that produced it.

## `bt_julia_eval`, a shared live REPL

```
bt_julia_eval(code; env_path?, timeout?, full_output?, max_response_bytes?, julia_cmd?)
```

Each `env_path` runs in its own Julia subprocess (managed via
[Malt.jl](https://github.com/JuliaLang/Malt.jl)); top-level bindings, loaded
modules and compiled methods carry over between calls, so an agent iterating on
a package pays the load cost once instead of per tool call. Revise is
auto-loaded (source edits are picked up without a restart), and an `env_path`
ending in `/test` auto-activates TestEnv so the parent project's test deps are
visible. Always prefer this over `julia -e` through Bash, which spawns a cold
process every time.

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
| `bt_julia_continue` | wait another `timeout` seconds |
| `bt_julia_interrupt` | `SIGINT`; captures the partial output plus the `InterruptException`, session state preserved |
| `bt_julia_restart` | `SIGKILL`; a fresh process, loses all session state |

`bt_julia_list_sessions` lists the live sessions. `timeout` auto-disables for
`Pkg.*` (installs are routinely multi-minute); pass `timeout=0` to disable the
checkpoint entirely.

### The result is the live value

Whatever the eval returns is rendered into the chat as a **live embed**, not a
text repr. A number, an array, a `DataFrame`, an image, and, crucially, a
Bonito `App` or a WGLMakie figure, which stay *interactive*: a slider drag or a
button click round trips to the Julia object still living in the worker's
session. The value is held in the worker and rendered on demand
(serialize-on-mount over a proxy bridge), so the same result survives collapsing
and re-expanding the card, and even a browser reload.

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
collapsible; clicking its header cycles **full → summary → collapsed**. The
summary state is a scrollable ~4-line window onto the content (the scrollbar
belongs to the section, so the summary is a window, never a truncation), which
for streaming output stays pinned to the newest line. The card can also be
widened to the full chat column (the » toggle) when a plot or wide table wants
the room. A completed eval that returned a value auto-expands so you see the
result without a click; one that returned `nothing` stays compact.

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

## `bt_show`, a file into the chat

`bt_show(path)` renders a worker-side file into the transcript: images and
videos inline (click for a lightbox), text files as syntax-highlighted code.
`bt_julia_eval` already auto-saves rich values (Makie / Plots figures, color
matrices) to `<env>/.bonitoAgents/show/` and reports the path, so the usual flow
is: eval a figure, then `bt_show` its path when the user should see the picture
rather than interact with it. The file is fetched from the worker on demand, so
a plot the agent just wrote to `/tmp/plot.png` shows up seconds later.

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
built it. That whole loop, from building the app to steering it to docking it
beside the chat, is what the recorded
[`bt_julia_eval` walkthrough](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_mock.jl)
puts on screen.
