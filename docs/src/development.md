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
removed on close. `dev_server(proxy = BonitoAgents.DevProxy(...))` puts the
real Authelia login in front, with Caddy or, with the proxy's `tunnel = true`,
the server's own login gate, and keeps the logins in Valkey as an install does.
`BonitoAgents.fetch_proxy_binaries` downloads Caddy, Authelia and Valkey once
and checks them against their published checksums. `dev_server(network = true)` runs it the way a
server on a trusted network runs.

The test kit (`BonitoAgents/test/testkit/TestKit.jl`) wraps it for scripted
sessions: its `dev_server(agent = f)` swaps in the mock agent, where
`f(prompt)` returns the protocol events to stream, and `tunnel = true` or
`proxy = true` puts the login in front. That is how the test suite and the
walkthrough drive deterministic sessions without an API key.

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

`test_args` entries are OR-ed into a regex over test-item names. An extra
`i/n` argument runs the i-th of n shards of that selection, which is how CI
fans the e2e items out:

```bash
julia --project=BonitoAgents/test BonitoAgents/test/runtests.jl '^e2e:' 3/8     # CI's shard 3
```

The shard list is built from the `@testitem` names in the source, so CI cannot
drift from the suite. The hand-written job-per-suite matrix it replaced had
drifted: one entry no item answered to (a red job every run) and nine items
nothing ever ran. Eight shard jobs also cost about a tenth of the runner time,
because a job's fixed cost (checkout, apt, a 730 MB depot restore) dwarfs the
sub-minute item it used to run.

Budgets are per ITEM (`testitem_timeout` in `runtests.jl`), not per job: a
wedged item fails itself and the worker respawns with a fresh dev server.
Compilation happens in its own CI step (`.github/scripts/warmup.jl` imports
each env's deps in a fresh process), so no test ever waits on a DOM while the
machine is busy compiling.

The e2e items share one long-lived dev server per test worker, which is
deliberate so cleanup and leak paths soak under accumulation. Tests are never
retried: a flaky test is a bug, and several production races were found exactly
this way.

The mock agent's event DSL (`test/testkit/TestKit.jl`) covers text chunks,
tool calls with diff and terminal content, forms, plans, subagent feeds,
live-app pushes, pacing delays and mid-turn cancellation, so most UI behavior
can be scripted in a few lines. Its MCP simulator runs in-process, which is
enough for UI work but never exercises a process launch; pass
`real_process = true` when that is the thing under test. The worker relay that
carries remote Julia has two items of its own: `unit:mcp_relay` (a real MCP
subprocess started without any server coordinates, plus cancellation,
disconnects, routing and queue bounds) and `e2e:remote_eval` (real worker
daemons and MCP processes end to end).

## Debugging BonitoAgents itself

The Settings page has a **Debug BonitoAgents** row with a worker picker, and
every chat's ⋯ menu has a *Debug BonitoAgents* item (which uses that chat's
worker). Both open a chat whose working directory is a BonitoAgents source
checkout **on that worker**, so the agent can read the source, edit it, and open
a PR the ordinary way.

The worker provides the checkout. A worker that already runs from one (a dev
install, the test suite) answers with it. An ordinary install clones the
repository into its environment (`<env>/dev/BonitoAgents`, at the revision this
server was installed from) and `Pkg.develop`s the monorepo packages from it:
`dev --local`, done for you. The first press on such a worker therefore takes a
few minutes (clone + precompile); afterwards a restart of that worker
runs what the agent edited, and re-running the installer puts the environment
back on the pinned revision.

That chat additionally gets `bt_dev_*` MCP tools that read the **live process**,
which is the part the filesystem can't tell you:

| Tool | What it answers |
|------|-----------------|
| `bt_dev_inspect` | live workers, projects, chats and eval bridges, plus `section="worker"`: what a worker says about ITSELF (its agent processes, their sockets). When that disagrees with what the server believes, the disagreement is the bug. |
| `bt_dev_logs` | logs from any machine in the fleet. `source="server"` or `source="<worker>"` reads that process's log FILE, which survives restarts and holds what no logger sees (unhandled task errors, fatal signal dumps); `source="all"` reads everyone at once. The default `"ring"` is the server's in-memory `@info`/`@warn`/`@error` records, filterable by level and substring. |
| `bt_dev_memory` | RSS, GC live bytes, open file descriptors against their limit, and every registry that has historically grown without bound, with an optional GC and a deep `summarysize` pass. For a leak: take a reading, exercise the suspect path, read again with `gc = true`, compare what grew. It sees the server process only; processes on a worker have to be counted on that machine. |
| `bt_dev_control` | drive the server as a user would: open, close, rename or restart a chat, send a message, rescan a worker, or continue a chat on another machine. |

The tools are attached by a persisted per-project `dev_mode` flag. *Debug
BonitoAgents* sets it; an admin can grant it to any chat by hand with the
**Dev mode** item in that chat's ⋯ menu (behind a confirm, since the tools drive
the whole server; the ⋯ trigger turns red while it is on). A chat that got it
that way is told the source is not in front of it. Pointing an ordinary chat at
the checkout grants nothing.

ACP adapters can advertise `agentCapabilities._meta.promptReceipts = true`.
The client then sends a fresh `_meta.bonitoPromptId` with each `session/prompt`;
after consuming that prompt, the adapter sends `_bonito/prompt_received` with
`sessionId` and `messageId` equal to that token. The shared outbox persists the
message until that receipt, and pauses an unconfirmed attempt after cancellation
or connection loss. The logs distinguish `message awaiting agent receipt` from
`message sent to agent`. Claude's temporary worker shim exposes its existing
insertion event; adapters without receipts cannot use overlapping prompts.
Its capability shim also advertises the existing steering
`idleBehavior: "promptRequired"` option. The shared client uses this or
`activeOnly: true` to steer into live work while retaining ownership of the
fallback prompt if the running turn ends. An ordinary queued prompt does not
have that delivery priority.

## Recording the homepage demo

The homepage follows one curve-fitting task: explore a live app, check the
calculation, then dock the app beside the conversation. The conversation is
scripted with MockACP; Julia execution, streaming output, plots and browser
interactions are real. It uses no agent credits.

Run [the recorder](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_mock.jl)
in the development environment, with ElectronCall's testing helpers available:

```bash
julia --project examples/walkthrough_mock.jl
```

Set `BT_WALKTHROUGH_EVAL_ENV` to an existing project with WGLMakie, Bonito,
Statistics and LinearAlgebra. The recorder writes `examples/workflow-raw.mp4`;
setup and compilation happen before the camera starts. Use a fresh Julia
process for a new take so a previous recording's live app cannot be reused.

The published clip is `docs/src/assets/workflow.mp4`. Keep pauses long enough
to understand the result, and cut waiting or repeated navigation. Publish it
with a representative `workflow-poster.jpg` and English captions in
`workflow.vtt`. Update the chapter times in `index.md` to match the edit.
The page uses native video controls and does not autoplay.

The older `walkthrough.jl` and `walkthrough_dashboard.jl` replay a separate
persistent rig with real agent sessions. They remain available for longer
tours, but are not embedded on the homepage.

## Building these docs

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
julia --project=docs docs/run.jl     # LiveServer on docs/build
```
