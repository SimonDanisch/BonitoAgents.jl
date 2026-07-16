# RemoteRef — final design (2026-07-15, after full Bonito source read)

Goal: eval results render across the worker bridge with EXACTLY normal session
semantics (`browser ↔ blackbox ↔ julia`, local or remote — no difference), as
a composable value: `DOM.div(Collapsable(RemoteRef(...)))`. Fail-proof (every
failure degrades to a visible static state, nothing can hang), efficient
(nothing renders until something is shown), minimal (reuses stock protocol;
net-negative line count).

## Facts the design rests on (all verified in source; see Bonito/ARCHITECTURE.md)

1. `update_session_dom!(parent, node_uuid, app)` creates a FRESH sub and
   delivers html + init messages as ONE atomic `UpdateSession` message; the JS
   handler polls `dom_node_selector` (`on_node_available`, 30s) — mounting
   into late DOM is safe. (session.jl / Sessions.js)
2. The page GC (`track_deleted_sessions`) closes any INITIALIZED sub whose DOM
   node leaves the document → `CloseSession` → routed to the worker by prefix.
   Therefore: page-visible sessions die on collapse; a value HOLDER must never
   be page-visible, and every mount must be a disposable render-sub.
3. The session tree is the registry: a holder `Session(parent)` with
   `current_app[]` set is findable via `get_session(parent, id)`, costs no
   render, and dies with the worker's bridge parent. No result ids, no Dicts.
4. Deletion is Julia-first (`close_session` → Julia → `free_session` evaljs);
   ownership close must go through the worker, never free JS-side directly.
5. Glyph batches ride the bridge root as ordered evaljs during render, so they
   precede the UpdateSession on the wire; the atlas pull heals any gap.
   Cross-mount object sharing is covered by `dedup_cached_objects(::Session{<:
   ProxyConnection}) = false` (fragments self-contained) — that patch is
   LOAD-BEARING here.

## The three pieces

### 1. Worker (BonitoMCP/RemoteProxy.jl, ~20 lines)

Eval completion (`format_value` path):
```julia
function remote_ref(@nospecialize(value))
    parent = get_parent_session()
    holder = Bonito.Session(parent)                # page-invisible value holder
    holder.current_app[] = Bonito.App(display_value(bound_for_render(value)))
    return holder.id                               # "prefix/uuid" descriptor
end
```
No render at eval time. Holder lifetime = worker session (phase 2: explicit
eviction when the chat prunes the message).

One new ctrl op next to "close"/"asset_read" (existing channel, no protocol
invention):
```julia
elseif op == "mount"
    holder = Bonito.get_session(b.parent, String(msg["sub"]))
    holder === nothing && error("result gone (worker restarted / evicted)")
    sub = Bonito.update_session_dom!(holder, String(msg["node"]), holder.current_app[])
    send_control(d, Dict("op" => "reply", "id" => id, "val" => sub.id))
```
Serialize-on-mount; fresh render-sub per mount (fact 2); atomic delivery
(fact 1).

### 2. Host (BonitoAgents/remote_app.jl, ~40 lines)

```julia
struct RemoteRef
    bridge::Union{Nothing, EvalBridge}  # THIS worker incarnation (prefix pins validity)
    session_id::String                  # worker-side holder id
    snapshot::String                    # static html fallback; "" = none
end
```

`jsrender(session, r::RemoteRef)` — static-first, live-upgrade:
- Placeholder div containing `HTML(r.snapshot)` (or an explicit "not live"
  note), `node_id = uuid(session, node)`. This is what the user sees for a
  dead bridge, a slow worker, an evicted holder, or a lost reply — the SAME
  degraded state for every failure, zero spinner logic, zero hangs.
- Bridge live → `attach_bridge_host!(root_session(session), eb)` then async:
  `render_sub = call_ctrl(eb, "mount"; sub = r.session_id, node = node_id)`;
  the arriving UpdateSession REPLACES the placeholder content.
- Ownership (race-free version of "the local session holds the proxy sub"):
  each mount owns ITS OWN render-sub — `on(session.on_close)` sends the
  existing `"close"` ctrl for `render_sub`. The holder is never touched by
  mount lifecycles, so collapse → re-expand (new local session, new mount,
  new render-sub) can never be killed by a stale close; page GC closing an
  unmounted render-sub (fact 2) is correct, not a bug.

### 3. Chat + eval handler (net deletions)

- `format_value`: final content block = descriptor JSON `{"remote_ref": id}`
  (position-keyed by the typed JuliaEvalCall render — no string sniffing);
  model-facing text blocks unchanged.
- `JuliaEvalCall` jsrender: `RemoteRef(eval_bridge_for(state, project_id),
  id, snapshot)` into the existing `wrap_for_detach` slot.
- DELETE: `EvalResultPlaceholder` + inlined-html mounting,
  `swap_mount!`/`take_mounts!`/`eb.mounts` bookkeeping (superseded by
  per-mount ownership), `render_eval_html`'s live role (phase 2 repurposes it
  as the offline snapshot renderer).

## Phase 2 (only after the battery is green)

- Snapshot: offline static render (`export_static`-style, NoConnection — no
  bridge side effects) at eval time → `r.snapshot`; history and dead-worker
  states become real renders instead of empty.
- Holder eviction wired to chat message pruning.
- Re-evaluate the relay park/flush machinery: with pull-based mounts it should
  almost never fire — keep as a LOUD safety net or reduce.

## Failure matrix (nothing hangs, everything visible)

| failure | behavior |
|---|---|
| worker dead / restarted (bridge nothing or ws down) | snapshot + note, no round trip attempted |
| holder evicted / unknown | ctrl "mount" errors fast → snapshot stays |
| slow worker / big render | snapshot visible until UpdateSession lands; node polling tolerates DOM races |
| lost reply / dropped frame | snapshot stays; next expand retries with a fresh mount |
| collapse/expand loops | independent mounts; old render-subs die via page GC or local on_close (Julia-first) |
| page reload | history renders snapshot; expand remounts live if worker alive |
| missing glyphs/objects/assets | GlyphSync pull + dedup-off + latest-wins asset registration |

## Verification battery (unchanged, must all pass)

1. owner-eval never expanded, reuser expanded → full render, zero warns
2. collapse → re-expand → fresh mount renders (repeatedly)
3. worker restart between evals → new evals render; old show snapshot/note
4. page reload → snapshots render; live remount works
5. plain-page 12-figure stress + 6x throttle + export_static stay green
6. interactive result (counter) stays live over the bridge
Then: committed e2e tests for 1–4, full BonitoAgents + WGLMakie suites, runic
format, CHANGELOG.
