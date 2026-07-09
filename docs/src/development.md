# Development

## The dev rig

```julia
using BonitoAgents
h = dev_server(auto_open = true)   # server + local worker, ephemeral tempdirs
# … hack, click around, iterate (Revise picks up source edits) …
close(h)                            # everything is wiped
```

[`dev_server`](@ref) is the ephemeral sibling of the desktop mode: same
server, same real worker subprocess, but every state directory is a tempdir
that is removed on close. `dev_server(agent = f)` swaps in the scriptable
mock agent — `f(prompt)` returns the protocol events to stream — which is how
the test suite and the walkthrough drive deterministic sessions without an
API key.

## Tests

The suite is built on [ReTestItems](https://github.com/JuliaTesting/ReTestItems.jl)
with two families:

- `unit:*` — headless, no browser;
- `e2e:*` — black-box items that drive a real dev server through a headless
  Electron window (DOM events in, rendered DOM out; assertions never peek at
  server internals).

```bash
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents")'                            # everything
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["unit"])'        # fast
julia --project=BonitoAgents -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["e2e:media"])'   # one item
```

`test_args` entries are OR-ed into a regex over test-item names. The e2e
items share one long-lived dev server per test worker — deliberate, so
cleanup/leak paths soak under accumulation. Tests are never retried: a flaky
test is a bug (multiple production races were found exactly this way).

The mock agent's event DSL (`test/testkit/TestKit.jl`) covers text chunks,
tool calls with diff/terminal content, forms, plans, subagent feeds, live-app
pushes, pacing delays and mid-turn cancellation — most UI behavior can be
scripted in a few lines.

## The walkthrough

[`examples/walkthrough.jl`](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough.jl)
records the tour video with ElectronCall's animated cursor + frame-pump
recorder against a mock-agent dev server:

```bash
julia --project=BonitoAgents/test examples/walkthrough.jl   # → examples/walkthrough.mp4
```

## Building these docs

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
julia --project=docs docs/run.jl     # LiveServer on docs/build
```
