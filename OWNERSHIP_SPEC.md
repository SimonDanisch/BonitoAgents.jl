# Addressed updates, not routed ones

Design for replacing the update router in `AgentClientProtocol.Connection` with
ownership: every `session/update` is delivered to the thing it belongs to, and
that thing owns its own state and rendering.

## The problem

`session/update` carries no request id. The dispatcher therefore infers which
turn an update belongs to:

```julia
ch = isempty(conn.active_turns) ? nothing : last(first(conn.active_turns))
```

"the oldest in-flight streaming request". And when it cannot infer, the update is
either diverted (`on_orphan_update`) or dropped (`cancelling`).

**Correction to an earlier draft of this document.** It called that line a guess
at structure the protocol does not have. That is wrong, and the field's own
docstring says so: oldest-first matches claude-agent-acp's *handoff contract* —
a second `session/prompt` sent while one is running gets injected into the live
turn, and the SDK then resolves the FIRST prompt with `end_turn` and hands the
stream to the second. The rule models real upstream behaviour.

What is still wrong is narrower, and worth stating precisely rather than
sweeping: the routing table is used to answer questions it was never built to
answer (is the agent working? should this be cancelled? whose history is this?),
and its fallback is to discard. The handoff contract itself has to survive any
replacement — two concurrent prompts, the first resolving into the second, is a
supported state and not an edge case.

A second claim in that docstring needs settling before anything is built on it:

> with a live background task the SDK never goes idle, so the active prompt
> never resolves on its own — the next prompt is what releases it.

**Resolved: the docstring overstates.** It generalises a pathology into a rule.
claude-agent-acp's own source (`acp-agent.js`) treats `session_state_changed:
idle` as "its authoritative turn-over signal", and its 30 s force-cancel grace is
documented as

> armed and cleared, never fired, on healthy cancels. It only trips when the SDK
> is genuinely wedged (e.g. a `TaskOutput { block: true }` poll against a hung
> background task — issue #680) and never yields.

So a hung background task is an upstream anomaly with its own backstop, not the
normal shape of background work. Healthy background work resolves the turn —
which is what `fixtures/real_stop_orphan_wire.jsonl` shows directly: frame 26
resolves `end_turn` while `sleep 20` is still running, and the work arrives
afterwards at frames 27-29.

Consequences for this design:

- "a turn is a span over the main thread" is well-defined; a span ends when the
  prompt resolves, and outstanding background work does not hold it open
- the `cancelling`-clears-on-settle fix does fire in the case it was written for
- the wedge case is already handled above us, so this layer does not need to
  model it — but it must not ASSUME a turn always settles promptly either, which
  is why per-owner state cannot be keyed on span lifetime alone

Four bugs found in one session, all the same cause:

| symptom | what was actually wrong |
| --- | --- |
| stop did nothing while the agent worked | `cancel!` asked `active_turns` "is anything working". That is a routing table, not liveness. |
| background work went silent after a stop | `cancelling`, scoped to one turn, gated a stream that turn did not own. |
| every chat read "working" from bind | metadata counted as work, because the orphan path had no notion of who sent it. |
| a subagent's first 100+ steps vanished | one shared 50-entry ring buffer instead of per-subagent state. |

Each was fixed individually. The fixes are right, but they are four patches on
one wrong idea: **ownership is inferred instead of addressed.**

## The wire already carries identity

This is what makes the alternative real rather than aspirational. Updates name
their owner today:

- `_meta.claudeCode.parentToolUseId` — which subagent. Already parsed; already
  wrapped as `SubagentUpdate`.
- `toolCallId` — which tool call.
- `sessionId` — which session.

The router reads `parentToolUseId` only *after* deciding turn-ownership, to
divert the update into the parent's feed. Dispatching on it first removes the
guess entirely.

## The model

**Owners, not turns.** Two kinds:

- the session's **main thread**
- one per **subagent**, keyed by `parentToolUseId`

An owner has an inbox, its own state, and renders itself. The dispatcher becomes
a demultiplexer: read the identity, deliver. No heuristic, no discard.

**A turn is a span, not an owner.** `active_turns` stops being a router and goes
back to plain JSON-RPC id correlation: match a `stopReason` response to the
request that asked for it. That needs no inference. The "oldest in-flight /
handoff" logic exists only to split one stream into per-request buckets the
protocol never separated, and it goes away.

**"Orphan" stops being a category.** An update with no open turn but a
`parentToolUseId` belongs to that subagent. One with neither is the main thread
speaking outside a request — the auto-wake after backgrounded work. Both have
owners. Neither is exceptional.

## What this deletes

- the orphan branch and `on_orphan_update`
- the `cancelling` gate on it (and the latch-lifetime bug it caused)
- `ChatModel.between_turn` — today a second copy of the turn renderer, built
  solely because orphan updates had nowhere to go (#23 in the issue history)
- `Connection.orphan_work` — liveness becomes "does any owner have work in
  flight", which each owner knows about itself
- `route_subagent_activity!` reaching into the parent `TaskToolMsg`
- the shared 50-entry ring as a *data* bound; per-subagent history makes it a
  display choice

## Background work does not touch the main loop

A subagent runs in the background. Its updates should never reach the main
message loop, and today they do: `route_subagent_activity!` mutates the parent
`TaskToolMsg`, and the between-turn sink re-renders through the same `process!`
the live turn uses.

As one message type owning its own state, a subagent receives its updates,
maintains its own progress, and renders itself. The main loop does not see them.
That is also what makes cancel meaningful per-owner: stopping the main thread
does not touch a subagent's stream, and stopping a subagent does not touch the
main thread.

## Liveness and cancel fall out

Both were bolted on because the router could not answer them:

- **liveness**: an owner knows whether it has work in flight. The session is
  working if any owner is. No `orphan_work` flag, no `is_agent_work`
  classification of metadata — metadata is addressed to the session, not to a
  working owner, so it never looked like work in the first place.
- **cancel**: targets an owner. Cancelling the main thread cannot silence a
  subagent, which is the bug that made background work disappear after a stop.

## What does not get easier

Honest accounting — these constraints are in the current code for reasons, and
they need re-satisfying in the new shape rather than assuming they evaporate:

- **Head-of-line blocking.** The single dispatcher must not park on a slow
  consumer, or a cancelled turn's response sits behind a token backlog. Per-owner
  inboxes make this *better* (a slow subagent renderer no longer blocks the main
  thread) but each `put!` still needs to be bounded and non-blocking.
- **Teardown ordering.** Closing an owner has to reap its state without racing an
  in-flight delivery — the same discipline `detach_subsession!` and
  `stop_session!` already encode.
- **Premature cancel is a doom loop.** The warning in `handle_command!` about
  force-closing mid-turn leaving an orphaned `tool_use` that wedges every future
  resume still applies per owner.
- **The auto-wake owner is not obvious.** An untagged update with no open turn is
  the main thread, but only by elimination. If a future agent emits untagged
  updates for something else, that assumption breaks quietly — it should be an
  explicit fallback with a log, not a silent default.

## Why this is tractable now

There is a corpus to refactor against, which there was not before:

- `AgentClientProtocol/test/fixtures/real_stop_orphan_wire.jsonl` — real capture:
  metadata after `end_turn` that must NOT arm, then a `tool_call` that must
- `BonitoAgents/test/fixtures/bg_subagent_wire.jsonl` — real capture of
  background-subagent activity flowing past `end_turn`
- `orphan_cancel_test.jl` — cancel during un-prompted work; cancel does not
  silence later background work; A8 idle no-op
- `e2e:queued_messages`, `e2e:chat_cancel`, `e2e:cancel_escalation`,
  `e2e:leak_cycle`

**Treat these as the specification.** The refactor should pass them unchanged.
Any test that has to be edited to make the new design work is a behaviour change
that needs arguing for on its own, not folded into a refactor.

## Done in one pass, not staged

An earlier draft staged this over five steps, starting with owners running
*alongside* the router behind a fallback. That intermediate is a state nobody
wants to ship: both code paths live at once, so it carries more total complexity
than either endpoint and every behaviour has two implementations to keep
agreeing. The value is in deleting the router, and a stage that keeps it is
mostly ceremony.

So: one coherent change, then test the whole application hard.

### Blast radius

Four source files, and the weight is not evenly spread:

| file | lines |
| --- | --- |
| `BonitoAgents/src/chat.jl` | 7455 |
| `AgentClientProtocol/src/connection.jl` | 609 |
| `AgentClientProtocol/src/messages.jl` | 582 |
| `AgentClientProtocol/src/client.jl` | 326 |

### Which tests may change, and which may not

This is the part that keeps "tests as specification" meaningful without a staged
rollout. Six files name the internals being removed, so they necessarily change:

    AgentClientProtocol/test/orphan_cancel_test.jl
    AgentClientProtocol/test/runtests.jl
    BonitoAgents/test/e2e/subagent_feed.jl
    BonitoAgents/test/unit/between_turn_test.jl
    BonitoAgents/test/unit/subagent_feed_test.jl
    BonitoAgents/test/unit/session_config_test.jl

Everything else — roughly thirty behavioural e2e items including `chat_cancel`,
`cancel_escalation`, `chat_streaming_sustained`, `chat_remount`, `leak_cycle`,
`queued_messages`, `yolo_mode` — never mentions them and **must pass unchanged**.
Those describe what the user experiences; the six above describe how it is
currently built.

If one of the thirty has to be edited, that is a behaviour change and needs
arguing on its own terms, not absorbing into the refactor.

### Test plan for the single pass

1. `AgentClientProtocol` suite, including both real captured wires.
2. `BonitoWorker` suite (`Pkg.test`, real-agent integration included).
3. Full `BonitoAgents` suite — all test items, not a subset. The interlocks that
   matter (taskbar, persistence, virtual scroll, remount) are not in the files
   this refactor touches, which is exactly why they are worth running.
4. Real-agent run: background subagent, stop mid auto-wake, confirm the
   transcript freezes and the subagent's own history is intact.
5. Browser check of a long subagent run — the shared 50-entry ring is being
   replaced by per-subagent history, so the visible failure mode (steps
   disappearing from the middle of a long run) needs eyes on it, not just a
   passing assertion.
