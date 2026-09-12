# Per-page proxy roots — design (2026-07-23)

## Implementation plan (resolved 2026-07-23, after a full bridge + Bonito read)

The three open decisions are resolved and the internals verified. Concrete plan:

**Transport — prefix-tagged DATA frames (both directions), shared CTRL.**
DATA frame becomes `[TAG_DATA][UInt8 prefix_len][prefix bytes][payload]`; CTRL
frames (asset add/remove, control ops) stay bare (shared, per-worker). A page
prefix is a uuid (≤255) so one length byte suffices.

**Worker (`RemoteProxy.jl`):**
- `RemoteBridge` keeps `parent` as the worker-global **value registry** (holders
  stay page-invisible subs, never rendered) and gains
  `page_roots::Dict{String,Session}` + a lock.
- `PageDriver(bridge::BridgeDriver, prefix::String)`: `proxy_send` tags with
  `prefix` (`send_frame_prefixed`); `proxy_asset_add/remove` DELEGATE to the base
  `BridgeDriver` (assets stay shared → cross-page asset dedup, per-page object
  dedup). New `send_frame_prefixed(d, prefix, bytes)` builds the enveloped DATA
  frame through the same pending/flush path as `send_frame`.
- `open_page_root!(b, browser_id) -> prefix`: mint `prefix=uuid4()`, build
  `Session(ProxyConnection(prefix, PageDriver(b.driver, prefix)); id=prefix,
  asset_server = b.parent.asset_server, compression_enabled=…)`, mark
  `connection_ready`, store in `page_roots[prefix]`. KEY: it's a ROOT session, so
  Bonito auto-spawns its inbox reader (types.jl) — browser→worker dispatch is
  free.
- `close_page_root!(b, prefix)`: `close(page_roots[prefix])`, `delete!`.
- `serve_bridge`: for a DATA frame, read the prefix envelope → `put!(page_roots[
  prefix].inbox, payload)` (its own reader runs `process_message`). CTRL
  unchanged.
- `handle_control`: add ops `open_root` (→ reply prefix), `close_root`; `mount`
  gains `root=prefix` and renders `update_session_dom!(page_roots[prefix], node,
  holder.current_app[])` — a sub of the PAGE-ROOT (per-page cache), not the holder.

**Host (`remote_app.jl` / Bonito `proxy.jl`):**
- `EvalBridge.root_conn::Ref` → `page_conns::Dict{prefix => browser connection}`
  (+ its lock). `relay_frame!`: DATA → read prefix → enqueue for `page_conns[
  prefix]`; the `outbound` channel carries `(prefix, payload)` and `relay_writer`
  routes/parks per prefix.
- Inbound: register one `RemoteSession(prefix, PageForwardDriver(eb, prefix))`
  per page-root so `route_to_remote` matches `prefix/…` and `proxy_forward` tags
  the forwarded frame with `prefix` (symmetric to `PageDriver`).
- `attach_bridge_host!` → `ensure_page_root!(root, eb)`: on a browser tab's first
  RemoteRef mount, `call_ctrl(eb, "open_root")`, bind `page_conns[prefix]=
  connection(root)`, register the inbound route, and `on(root.on_close)` →
  `close_root` + drop `page_conns[prefix]` + `free_session(prefix)`. `RemoteRef`
  jsrender then `mount(root=prefix, …)`.

**Bonito (`connection/proxy.jl`):** DELETE
`dedup_cached_objects(::Session{<:ProxyConnection}) = false` — LAST, once the
above lands (it's load-bearing until then).

**Order + gating:** worker page-root machinery → host per-page routing → delete
dedup → run the eval e2e (render_error, bt_eval_types, eval_embed_park,
app_reload, tool_rendering) + a NEW two-tab e2e (both live simultaneously — the
regression the single `root_conn` can't pass). Commit only when green.

---

Goal: make the worker behave like a **normal Bonito server over the proxy
transport** — one root session per browser page (§0's invariant restored),
eval values held in a worker-global registry routed by unique id, page-roots
created/torn down with the browser page. This retires the singleton bridge
parent and everything it forced: `dedup_cached_objects=false`, cross-page
owner-sets, the self-contained-fragment tax, and the single-`root_conn`
one-tab-per-project limitation.

This is a re-plumb, not a rewrite: every piece maps onto an existing Bonito
primitive (`embed_app`, `use_parent_session` page-session mode, the
deferred-render idiom, `route_to_remote`). See Bonito/ARCHITECTURE.md §0, §2,
§7-§9.

## The problem, precisely

Today (RemoteProxy.jl + remote_app.jl) there is ONE `BRIDGE` singleton per
worker: one proxied root `parent` (`get_parent_session`), one `BridgeDriver`
over one dial-back socket. Every eval result is a holder subsession of that one
parent, and every mount renders a sub of the holder — so the render root is the
singleton parent. That one root fans out across MANY browser pages (chat cards,
tabs, reloads) for the whole worker lifetime.

That violates ARCHITECTURE §0: "serialized ⇒ delivered to the owning page, in
order" only holds when a root has exactly ONE frontend over ONE ordered
connection. Our bridge parent has N. Consequences we've been paying for:

- `dedup_cached_objects(::Session{<:ProxyConnection}) = false`
  (Bonito `connection/proxy.jl:142`): a `TrackingOnly` ref would dangle on a
  page that never received the first owner's frame, so every fragment ships
  full objects.
- `CachedEntry.owners` sets do **cross-page** refcounting on the per-worker
  root — the fragile seam behind app_reload / WGL-reliability / owner-set bugs.
- Host relay `EvalBridge.root_conn` (remote_app.jl:35) is a SINGLE slot; the
  last tab to `attach_bridge_host!` (line 635) overwrites it. Two browser pages
  on one project clobber each other's relay target. The comment at
  remote_app.jl:630-634 records that not-rebinding was itself a pinned hang.

§0 sanctions exactly two ways out for independently-mounted fragments:
self-contained payloads (what we do now) or **per-page cache scope** (this
spec). We switch to per-page scope, the branch where dedup just works.

## Facts the design rests on (verified in source)

1. `ProxyConnection{D}` namespaces EVERYTHING under `prefix` — object cache
   keys, dom uuids, session ids (`proxied_session_id`). The prefix IS the
   routing table; `route_to_remote(session, data)` (proxy.jl:195) forwards any
   inbound frame whose route id equals `prefix` or starts with `prefix/`. So N
   independent proxied roots multiplex over ONE socket with zero routing
   changes — only who mints each prefix changes. (ARCHITECTURE §9)
2. `embed_app(host, app)` (proxy.jl:268) is the ownership reference: per-embed
   proxied root (own prefix = own cache scope), `register_remote!` on the host,
   and `on(host.on_close)`: `unregister_remote!` → `free_session` in the browser
   → `close(worker session)`. Our design is this, lifted from per-embed to
   per-page.
3. The session's `(connection, asset_server)` pair IS the target (§8). A
   session can carry its own per-root object cache while pointing its
   `asset_server` field at a SHARED asset server — the two subsystems are
   independent. This is what lets object dedup go per-page while assets stay
   worker-global.
4. Proxied assets are content-hash keyed and refcounted on the host
   `ChildAssetServer`; 0→1 ships `proxy_asset_add`, 1→0 `proxy_asset_remove`
   (§9). Refcounting across page-roots is well-defined: serve until the last
   page releases.
5. Deferred-render idiom (§2): `sub = Session(parent); sub.current_app[] = app;
   render nothing;` then render on request via `update_session_dom!` /
   `update_subsession_dom!`. This is the value registry + mount, already blessed.
6. `update_session_dom!(parent, node_uuid, app)` creates a FRESH sub and
   delivers html+init as ONE atomic `UpdateSession`; the JS handler polls the
   node (`on_node_available`, 30s) so a reply racing the DOM mount is safe.

## The model

Three worker-side objects, cleanly separated by lifetime:

| object | lifetime | scope | role |
|---|---|---|---|
| **BridgeDriver** (1) | worker process | worker | the one dial-back socket; frame relay |
| **value registry** (1) | worker process | worker | parked eval values, keyed by unique id |
| **page-root** (N) | one browser page | one page | the §0-compliant render root for that page |

Today the singleton `parent` conflates registry + render-root. Split them:

- The **registry** is a worker-global, page-invisible holder store keyed by
  unique id (keep "the session tree is the registry" idiom: a dedicated
  registry root whose subs are value holders with `current_app[]` set and
  nothing rendered — they never cache anything, never ship). A value can be
  mounted into many page-roots; each mount is its own render-sub. This is the
  Bonito `Server` model: an `App` registered once by id, served to N browsers,
  each getting its own session-scoped render.
- A **page-root** is a `ProxyConnection` root with a FRESH prefix, one per
  browser page, over the shared driver. Its object cache is its own (per-page
  scope). Its `asset_server` points at the ONE shared worker asset server
  (fact 3). Eval mounts are subs of it (`force_subsession!` mode). It is
  created lazily on the page's first embed and closed when the page closes.

## Routing: browser page ⇄ worker page-root

Do NOT reuse the browser root id as the worker prefix (the browser page's own
objects live under that id — namespace clash). Mint a fresh worker prefix and
keep a host-side 1:1 binding.

Host `EvalBridge` change: replace the single `root_conn::Ref` with a map
`page_roots :: Dict{worker_prefix => browser_root_connection}` (guarded by a
lock). Worker→browser frames tagged `P/…` are written to `page_roots[P]`. The
`attached_roots` attach-once set and the single-slot rebind dance
(remote_app.jl:629-664) collapse into: one entry per page-root, added on
open_root, removed on the browser root's `on_close`.

Two new control ops on the existing channel (siblings of `mount`/`close`/
`asset_read`, RemoteProxy.jl `handle_control`) — no protocol invention:

- `open_root` (host→worker): host sends when a page first needs an embed and
  has no page-root yet. Worker creates a `ProxyConnection` (fresh prefix P) +
  page-root Session over the shared driver + shared asset server; replies P.
  Host binds `page_roots[P] = connection(browser_root)`, `register_remote!(
  browser_root, RemoteSession(P, eb))`, and wires `on(browser_root.on_close)`
  → `close_root`.
- `close_root` (host→worker): worker `close`s page-root P (frees its per-page
  cache + all its render-subs; asset releases refcount the shared server).
  Host unregisters the route, drops `page_roots[P]`, `free_session(P)` in the
  browser.

`mount` gains the target page-root: `mount(root=P, sub=value_id, node=node_id)`
→ worker renders `registry[value_id].current_app[]` as a sub of page-root P
via `update_session_dom!`, replies the render-sub id. The render-sub's cache
entries land under P (per-page), so a second embed on the SAME page that shares
an object gets a real `TrackingOnly` (dedup works); a different page renders
its own copy (no cross-page dangle).

The dial-back **socket stays per-worker**. Handshake identity becomes a stable
per-worker id (not a render prefix). On reconnect the host `EvalBridge` and the
worker page-roots both survive (sessions aren't tied to the socket, same as
today's BRIDGE surviving a ws drop); the ws is swapped and every `page_roots`
entry keeps routing. Page-roots are re-announced/re-bound on reconnect (edge in
the lifecycle table).

## Assets: the one thing that stays shared

Object graph is page-local; static assets are not. This is NOT a new/parallel
asset server — it reuses Bonito's existing two-tier proxy asset layer
(`asset-serving/proxy.jl`), which already shares a registry across a proxied
tree. The only change is the registry's **owning scope: per-root → per-worker.**

- `ProxyAssetRegistry` (proxy.jl:44) is the shared store: `entries::Dict{key =>
  (refcount, asset)}` + driver. `ProxyAssetServer` (proxy.jl:52) is a per-session
  VIEW over it: just the shared registry + this session's own `keys::Set`.
  `Base.similar` (proxy.jl:61) shares the registry, forks the key set — the
  comment literally calls it "exactly the HTTPAssetServer↔ChildAssetServer
  relationship."
- Today `RemoteBridge` builds `ProxyAssetServer(driver)` on the singleton parent,
  which mints a FRESH registry (proxy.jl:57). Change: the worker/bridge holds ONE
  `ProxyAssetRegistry(driver)`, and each page-root is created with
  `asset_server = ProxyAssetServer(SHARED_REGISTRY)` (≡ `similar(bridge_view)`).
  Each page-root reaches the shared registry through its normal `asset_server`
  FIELD — not a side object.

Why the split is automatic and free:
- Object cache (`session_objects`/`owners`) is ROOT state → per-page-root by
  construction → per-page object dedup, cross-page full copies. (This is what
  deleting `dedup_cached_objects=false` restores.)
- Asset registry is reached via the `asset_server` field → anchoring it at
  worker scope makes it span page-roots. Key K referenced by page P1 → one
  `proxy_asset_add`; P2 referencing K → refcount 2, no re-ship (`url`,
  proxy.jl:95).
- Teardown already correct: `close_root` → `close(page-root)` → `close` of its
  `ProxyAssetServer` view (proxy.jl:117) decrefs ONLY that view's keys (1→0
  fires `proxy_asset_remove` on the last page's release). The shared registry is
  held by the worker bridge, survives page-root closes, dies with the worker.
- Host stays ONE `ChildAssetServer` per worker (`eb.asset_host`): sees clean net
  0→1/1→0, serves `/assets/<key>` globally to every page.

Result: the WGL bundle's bytes ship once and serve every page (cross-page asset
dedup) while object dedup is per-page — "page-local object graph, globally
cached assets," how the web already works. `dedup_cached_objects`'s override is
DELETED; the shared asset refcount is the only cross-page ledger left, and it's
the existing, correct-to-share one.

## What changes / deletes

- Bonito `connection/proxy.jl:142`: DELETE the
  `dedup_cached_objects(::Session{<:ProxyConnection}) = false` override.
- RemoteProxy.jl: `get_parent_session` singleton + `force_subsession!(true)`
  global → registry root + per-`mount` page-root targeting; add `open_root`/
  `close_root` control ops; `remote_ref` parks into the registry (unchanged in
  spirit).
- remote_app.jl: `EvalBridge.root_conn`/`attached_roots` single-slot wiring →
  `page_roots` map; `attach_bridge_host!` → open_root/close_root binding;
  handshake carries a worker id, not a render prefix.
- RemoteRef `jsrender` (remote_app.jl:694+): on mount, ensure the page has a
  page-root (open_root if absent), then `mount(root=P, …)`. Per-mount
  render-sub ownership (`on(session.on_close)` → close the render-sub) is
  UNCHANGED — still correct, still Julia-first.
- The static-first snapshot / failure-degradation behavior from the RemoteRef
  spec (2026-07-15) is UNCHANGED: every failure still degrades to the visible
  static state.

## Lifecycle table (the edges to get right)

| event | worker | host | browser |
|---|---|---|---|
| page first embed | create page-root P (lazy) | bind `page_roots[P]`, register route | mount replaces placeholder |
| 2nd embed, same page | render sub of P (shared cache → TrackingOnly ok) | — | live |
| same value, 2nd page | create page-root P2, render own sub (own cache) | bind P2 | independent live copy |
| collapse embed | render-sub closed (Julia-first) | — | `free_session(render-sub)` |
| re-expand | fresh render-sub of P | — | fresh mount |
| page reload | page-root P torn down + P' created fresh (empty cache → full ship) | drop P, bind P' | dedup-on works, no dangle |
| page close | `close_root` → free P + subs; asset refcounts drop | unregister, drop `page_roots[P]` | `free_session(P)` |
| last mounting page of a value closes | value STAYS in registry (worker-lifetime) | — | re-openable later |
| ws dial-back reconnect | page-roots survive; re-announce | swap ws, re-bind `page_roots` routes | frames resume |
| worker restart | registry + all page-roots gone | different worker id → hard-replace bridge | RemoteRefs show snapshot/note |

Open decisions to confirm before coding:
1. Registry as a dedicated page-invisible root (keeps "tree is registry") vs a
   plain `Dict{String,App}`. Recommend the registry root — matches the idiom,
   `get_session` still finds holders, `probe_render_error` (#47) runs on a
   throwaway sub of it.
2. `open_root` initiated by host on first mount (recommended: host owns the
   browser page + its connection + `on_close`) vs worker-driven. Host-driven.
3. Reconnect re-announce: worker replays live page-root prefixes on the new
   socket, or host re-sends `open_root` for each bound page. Recommend worker
   replay (it owns the live set).

## Failure matrix (nothing hangs, everything visible — superset of RemoteRef's)

| failure | behavior |
|---|---|
| worker dead / restarted | snapshot + note; no round trip (worker id mismatch) |
| value evicted / unknown | `mount` errors fast → snapshot stays |
| page-root open fails | snapshot stays; next expand retries open_root |
| two tabs, one project | independent page-roots, independent relay targets — no clobber (the current single-`root_conn` bug is gone) |
| page reload | page-root recreated fresh → dedup-on, full re-ship, live remount |
| slow/big render | snapshot until UpdateSession lands; node polling tolerates DOM races |
| lost frame | snapshot stays; next expand remounts |
| missing assets across pages | shared content-hash asset server serves all pages; per-page object cache never cross-references |

## Verification battery

1. Two browser pages on the SAME project, each with a live embed → both
   interactive simultaneously (the regression the current `root_conn` can't
   pass). Independent page-roots, independent relay.
2. Same value mounted on two pages → independent live copies; closing one
   page's tab leaves the other live and the value re-mountable.
3. `dedup_cached_objects` deleted: two embeds on one page sharing an object →
   second gets `TrackingOnly`, zero "Key not found in GLOBAL_OBJECT_CACHE"
   warns; a different page renders its own full copy.
4. Page reload → page-root torn down + recreated; live remount works; no
   dangling refs, no cross-page owner-set leak.
5. Page close → worker page-root + render-subs freed (no session leak); value
   survives in registry.
6. WGLMakie 12-figure stress across two pages + 6× throttle stays green;
   plain-page `export_static` unaffected.
7. ws reconnect mid-session → page-roots re-bind, frames resume, no double-open.

Then: committed e2e items (two-tab, reload, dedup-on, page-close-free), full
BonitoAgents + WGLMakie suites, runic format, CHANGELOG. Update app_reload.jl's
mechanism comment (behavior identical, mechanism now per-page scope not
self-contained fragments).
