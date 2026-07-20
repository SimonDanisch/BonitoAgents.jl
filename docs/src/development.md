# Development

## The dev rig

```julia
using BonitoAgents
h = dev_server(auto_open = true)   # server + local worker, ephemeral tempdirs
# hack, click around, iterate (Revise picks up source edits)
close(h)                            # everything is wiped
```

[`dev_server`](@ref) is the ephemeral sibling of the desktop mode: the same
server and real worker subprocess, but every state directory is a tempdir
removed on close. `dev_server(agent = f)` swaps in the scriptable mock agent,
where `f(prompt)` returns the protocol events to stream. That is how the test
suite and the walkthrough drive deterministic sessions without an API key.

## Tests

The suite is built on [ReTestItems](https://github.com/JuliaTesting/ReTestItems.jl)
with two families:

- `unit:*`, headless, no browser;
- `e2e:*`, black-box items that drive a real dev server through a headless
  Electron window (DOM events in, rendered DOM out; assertions never peek at
  server internals).

```bash
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents")'                            # everything
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["unit"])'        # fast
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["e2e:media"])'   # one item
```

`test_args` entries are OR-ed into a regex over test-item names. The e2e items
share one long-lived dev server per test worker, which is deliberate so
cleanup and leak paths soak under accumulation. Tests are never retried: a
flaky test is a bug, and several production races were found exactly this way.

The mock agent's event DSL (`test/testkit/TestKit.jl`) covers text chunks,
tool calls with diff and terminal content, forms, plans, subagent feeds,
live-app pushes, pacing delays and mid-turn cancellation, so most UI behavior
can be scripted in a few lines.

## The walkthrough videos

Two recorders under [`examples/`](https://github.com/SimonDanisch/BonitoAgents.jl/tree/main/examples)
drive a real Electron window with ElectronCall's animated cursor and frame-pump
recorder, using only trusted input (`ECT.real_click`, `ECT.wheel`) so the clip
shows exactly what a user does. They write the two videos embedded on the home
page:

- [`walkthrough_dashboard.jl`](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_dashboard.jl)
  → `walkthrough_dashboard.mp4`: the multi-project dashboard tour (open a project
  from its card, switch projects from the sidebar, back to Home). Replays the
  persistent rig (`BT_WALKTHROUGH_RIG`), so it uses no tokens and never prompts
  the agent.
- [`walkthrough_mock.jl`](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_mock.jl)
  → `walkthrough.mp4`: the focused `bt_julia_eval` demo (curve-fitting dashboard,
  degree-slider sweep, streaming cross-validation, three-state collapse,
  detach/dock/steer). Self-contained: a `MockACP` agent scripts the
  conversation while the REAL `bt_julia_eval` runs the code.

```bash
# run in an env that dev's ElectronCall with the trusted-input helpers:
julia --project examples/walkthrough_mock.jl        # → examples/walkthrough.mp4
julia --project examples/walkthrough_dashboard.jl   # → examples/walkthrough_dashboard.mp4
```

## Building these docs

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
julia --project=docs docs/run.jl     # LiveServer on docs/build
```
