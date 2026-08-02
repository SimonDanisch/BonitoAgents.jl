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

"the oldest in-flight streaming request" — the handoff contract. Everything the
protocol does not say, this line guesses. And when it cannot guess, the update is
either diverted (`on_orphan_update`) or dropped (`cancelling`).

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

## Suggested order

1. Introduce owners alongside the router; dispatch by identity where present,
   fall back to the current path. Nothing is deleted yet, everything still green.
2. Move subagents onto their own owner + renderer. This alone kills the shared
   ring buffer and `route_subagent_activity!`.
3. Move the auto-wake stream onto the main-thread owner. `between_turn` and the
   orphan branch go.
4. Re-express liveness and cancel per owner. `orphan_work`, the `cancelling`
   gate, and `is_agent_work` retire.
5. Delete the fallback path and the handoff heuristic.

Each step is independently shippable and independently revertible, which matters
because this is the layer everything else sits on.
