# Julia Tools & Live Apps

Every chat exposes MCP tools backed by
[`BonitoMCP`](https://github.com/SimonDanisch/BonitoAgents.jl/tree/main/BonitoMCP):
the agent's window into a persistent Julia session per project, running on the
worker next to the code.

## `julia_eval`, a warm persistent session

```
julia_eval(code; env_path?, full_output?, max_response_bytes?)
```

State carries over between calls: `using`-loaded packages, variables and
compiled methods stay warm, and Revise picks up source edits, so an agent
iterating on a package pays the load cost once rather than per tool call.
Sessions are keyed by project environment; `julia_restart` drops one and
`julia_list_sessions` lists them.

### Output discipline, enforced server-side

Prompt rules like "always end with `nothing`" are unreliable, so the tool
layer enforces hygiene instead:

| Situation | Behavior |
|---|---|
| Response over `max_response_bytes` (10 KB default) | truncated with a `[truncated: …]` marker |
| Return value is an image or figure | returned as a PNG image block, not a text repr |
| Container with hundreds of elements | summarized (`Vector{Int} with 500 elements; first 10: …`) |
| `full_output = true` | bypasses all of the above |

The agent sees what it needs, and a stray `rand(10_000, 10_000)` cannot blow
up the context window.

## `bt_show`, media into the chat

`bt_show(path)` renders a worker-side file into the transcript: images and
videos inline (click for lightbox), text files as syntax-highlighted code.
The file is fetched from the worker on demand, so a plot an agent just wrote
to `/tmp/plot.png` shows up in the conversation seconds later.

## `bt_show_app`, live interactive apps

`bt_show_app(code)` evaluates a Bonito `App` in the worker's eval session and
embeds it running into the chat. The UI ships to your browser, and every
interaction (a slider drag, a button click) round trips to the Julia code in
the worker: WGLMakie figures, custom dashboards, anything Bonito can render.

Embeds are workspace panels like any other. Detach one from its chat bubble
into a floating window or a tab next to the chat and it stays alive: the WebGL
context and sub-session are kept rather than re-created. A bounded LRU caps the
number of live embeds; parked apps resume when re-activated.

In the [walkthrough](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough.jl)
the mock agent hands back a Game-of-Life preview whose generation slider steps
the simulation in Julia, which is `bt_show_app` in one line of agent tooling.
