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

## The model, as built

**One main stream.** The session's main thread is a single, continuous
`Channel{Message}` on the `Client`, alive for as long as the ACP session is.
The agent talks on it inside a prompt and between prompts; both are the same
voice, so both go to the same coalescer and the same renderer.

**A prompt is a span, not a container.** `prompt!` sends the frame and returns a
`PromptSpan` — an id, a response channel, and an end marker. `wait_turn!` blocks
on the response for the stopReason. The turn's *content* never comes back
through it.

**A boundary is a marker on the stream.** `StreamFlush` travels the stream like
a message. The coalescer seals its state when it reaches one (trailing text
bubble closed, tools the agent never resolved force-failed) and forwards it; the
consumer signals `done` once everything ahead of it is rendered. The dispatcher
puts a span's marker on the stream at the exact frame its response arrives, so a
turn ends where the wire says it does.

**A subagent owns its updates.** `parentToolUseId` names it, the dispatcher
delivers to `on_owner_update` before anything else is consulted, and its owner —
the parent `TaskToolMsg` — keeps its whole history and renders itself.

**"Orphan" is not a category.** An update with no prompt open is the main thread
talking. There is nowhere for it to fall through to.

### Where the design above was wrong

Two claims in the original draft did not survive contact with the code.

**"Oldest-first routing is the handoff contract and has to survive."** It did
not have to. That rule only existed to split one stream into per-request
buckets the protocol never separated. With a single main stream there is nothing
to split: the agent's words arrive in wire order and are rendered in wire order,
and *which prompt is credited with them* is a question nobody has to answer. The
handoff itself still happens — prompt 1 resolves while prompt 2 streams — and it
now needs no modelling at all.

**"`is_agent_work` disappears, because metadata is addressed to the session, not
to a working owner."** Wrong. `available_commands_update` is genuinely the main
thread with no owner tag, so the distinction between the agent *doing* something
and the agent *reporting on itself* is real and has to live somewhere. It stayed,
and grew a second half: `is_agent_work(::SessionUpdate)` for liveness on the
wire, `is_agent_work(::Message)` for the renderer's busy flag.

## What this deleted

- `Connection.on_orphan_update` and the orphan branch
- `ChatModel.between_turn` and its whole lazy pipeline —
  `ensure_between_turn_sink!`, `between_turn_consumer!`, `teardown_between_turn!`,
  `finish_between_turn!`, `handle_orphan_update!`. It was a second renderer built
  because orphan updates had nowhere to go, and it disagreed with the first (#23)
- `TurnState.on_subagent`, and the per-turn `TurnState` — one persistent state
  per stream now, with `close` as a boundary rather than an end
- the per-prompt update channel (`prompt_updates`); `session/load` still captures
  the stream, because a replay genuinely is that request's result
- `route_subagent_activity!` reaching through the turn into the parent
- the shared 50-entry ring as a *data* bound. Per-subagent history makes it a
  display choice (`TASK_FEED_WIRE_LIMIT`)

## Liveness and cancel

- **liveness**: `active_prompts` says whether we asked for something;
  `unprompted_work` says whether the agent is saying something. They are
  different questions, and reading only the first is why stop was a no-op for
  the whole auto-wake window.
- **cancel**: gates the main thread only. A subagent's updates return before
  `cancelling` is consulted, so stopping a turn cannot silence background work
  the user never cancelled.
- **the cancel verdict**: read off the response's `stopReason`, not off
  `conn.cancelling`. That latch is dropped the moment the cancelled prompt
  settles, which is strictly before end-of-turn cleanup runs — so asking it there
  always said "not cancelled".

## What did not get easier

Honest accounting — these were in the old code for reasons, and they are still
here:

- **Head-of-line blocking.** The dispatcher must not park on a slow consumer, or
  a cancelled turn's response sits behind a token backlog. `deliver_update!`
  still backpressures with a `cancelling` bail, and the dispatcher still drops
  the main thread the moment cancel goes out.
- **Teardown ordering.** `close(Client)` closes the connection first (so no
  further update can be delivered), then the stream. `start_main_consumer!`
  keeps `(task, client)` together so the old renderer is stopped through the very
  stream it drains, rather than by hoping it has finished.
- **Busy latches after an auto-wake.** There is no idle signal on the wire —
  `session_state_changed` does not appear in either capture — so un-prompted work
  has no end event, and `busy` stays true until the next turn clears it. That is
  unchanged from before, not fixed by this.
- **Premature cancel is still a doom loop.** The warning in `handle_command!`
  about force-closing mid-turn leaving an orphaned `tool_use` still applies.

## Why this was tractable

There was a corpus to refactor against:

- `AgentClientProtocol/test/fixtures/real_stop_orphan_wire.jsonl` — real capture:
  metadata after `end_turn` that must NOT count as work, then a `tool_call` that
  must
- `BonitoAgents/test/fixtures/bg_subagent_wire.jsonl` — real capture of
  background-subagent activity flowing past `end_turn`
- `orphan_cancel_test.jl` — cancel during un-prompted work; a subagent streaming
  while the main thread's cancel latch is set; A8 idle no-op
- `e2e:queued_messages`, `e2e:chat_cancel`, `e2e:cancel_escalation`,
  `e2e:leak_cycle`, `e2e:subagent_feed`

**Treated as the specification.** Six files named the internals being removed and
necessarily changed:

    AgentClientProtocol/test/runtests.jl
    AgentClientProtocol/test/orphan_cancel_test.jl
    AgentClientProtocol/test/mocks/acp_mock_agent.jl
    BonitoAgents/test/unit/between_turn_test.jl   → unit/main_stream_test.jl
    BonitoAgents/test/unit/subagent_feed_test.jl
    BonitoAgents/test/e2e/subagent_feed.jl

Everything else — the behavioural e2e items including `chat_cancel`,
`cancel_escalation`, `chat_streaming_sustained`, `chat_remount`, `leak_cycle`,
`queued_messages`, `yolo_mode` — describes what the user experiences, and passes
unchanged.
