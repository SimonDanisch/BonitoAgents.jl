# e2e coverage map

These suites drive the *real* stack (dev server + worker + ACP over stdio,
only the `claude-agent-acp` binary swapped for the mock) through a headless
Electron window via `ElectronCall.Testing`. They assert against the rendered
DOM only — no internal-API calls.

They replaced the legacy `../electron/` harness (now **removed** in full), which
booted `unified_app(state)` directly (an internal API) and drove a hand-rolled
`MockTransport` ChatModel. Every behaviour that harness covered now lives in a
suite here or a headless `../unit/` testitem; the sections below record where each
one landed, plus the few that can't be reproduced in a headless window.

## Runner guarantees (`run_all.jl`)

- ONE dev server + browser + mock agent for ALL suites (a soak; state accumulates
  by design). Each `run_suite(server)` swaps the shared agent callback and drives
  the one DOM page.
- **No-JS-errors gate**: after every suite the runner samples the error sink
  (`window.onerror` + `unhandledrejection`, installed in `open_browser`) and
  asserts it empty, attributed to that suite, then clears it. Driving the real DOM
  is only worth it if we also notice when the DOM throws.
- **Un-hangable**: every bridge round-trip (`eval_js`, `js_errors`,
  `clear_js_errors`) is watchdog-bounded and throws a typed `BridgeTimeout`;
  `wait_for` treats a busy poll as "not yet" and retries within its own budget. A
  pegged renderer can never hang the run.
- **Resilient**: a suite that fails is recorded and the soak CONTINUES — the leak
  audit still runs, and the failure is re-surfaced as a final failing testset.
- **Leak audit** at the end asserts server-side bounds (models / pollers /
  mock subprocs / worker-ws / pending) and logs the counts.

## Known product bug surfaced by the soak

`streaming_flood.jl` runs EARLY (2nd) on purpose. A large message burst paints in
~1–2s on the first chats but the renderer WEDGES by ~chat #3 once many messages are
mounted (cost ≈ mounted × streamed — a client-side cross-chat accumulation, not a
deadlock and not server-side). Running the flood early isolates its real target
(the `deliver_update!` deadlock regression) from this separate, still-open bug.

Closing an INACTIVE app tab loses the embed. A bt_show_app docked as a tab can be
closed fine when it's the ACTIVE tab (embed returns to its bubble), but closing it
while it's an INACTIVE tab destroys the live embed — `render()` in
BonitoWidgets.js prunes the dropped panel (and the adopted embed with it) before
the restore glue rescues it. `app_tabs.jl` always activates a tab before closing
it, so it covers the working path; the inactive-close fix is still open.

## Suites

| File                  | Covers                                                                 |
|-----------------------|------------------------------------------------------------------------|
| `workflows.jl`        | dashboard, new-project folder picker, chat reply, edit tool + diff expand, bash tool, thinking, agent switch |
| `chat_features.jl`    | streaming accumulation, markdown (h1/ul/pre/strong/a), responsive layout (480/1280), multi-chat switching |
| `chat_close_rename.jl`| homebar ✕ closes a chat (leaves the list, back to dashboard, model torn down, `dismissed` persisted); closing one leaves the others; header rename is consistent in homebar + header and persists across a chat switch; a fresh chat binds its claude session id (the "name reverts to first message" root fix); reopening a closed chat restores it under its title |
| `embedded_app.jl`     | `bt_show_app` dial-back eval bridge + embedded frame render            |
| `leak_cycle.jl`       | open a 500-msg flooded chat + N churn chats, close ALL from the homebar ✕, then assert the server's bounded resources return to baseline — ChatModels evicted from the cache, background pollers gone, mock subprocesses reaped, pending RPCs drained, process RSS not ballooning. (A WeakRef-after-GC "still alive" count is logged but NOT asserted: Julia's conservative C-stack GC makes it non-deterministic noise, not a leak signal.) |
| `app_scroll.jl`       | moving a bt_show_app between bubble/float/tab must NOT scroll the chat (workspace render() re-parents panels → reset scrollTop=0 → bubble virtualized → live embed detached → "Reload live app" + dead re-detach). Asserts scroll held on dock, no jump-to-top on close, app stays live (Julia round-trip, never the reload placeholder), and re-detach works across 6 cycles |
| `app_stress.jl`       | bt_show_app moved bubble↔float 100×, chat-switch round-trips, asserting the SAME live node survives every move via a preserved counter; no orphan nodes, no JS errors |
| `app_interactive.jl`  | TWO live bt_show_apps at once; clicking each runs its Julia `map` in the worker (output = 7×clicks / 100+clicks, never computed in JS) and the DOM reflects the round-tripped value; the two apps stay independent |
| `app_multi.jl`        | THREE live apps: detach all into their own windows at once, drive EACH while floating (each its own Julia round-trip, others frozen), switch chats and back (all three windows + state survive), then close the windows one-by-one (each embed returns to its OWN bubble, others stay floating/live) |
| `app_tabs.jl`         | THREE apps docked into ONE window as TABS (via the float's ⤢ dock button): switch between tabs (active app visible, others hidden), each stays LIVE as a tab (Julia round-trip), then close the tabs (active-tab close → embed back to its bubble). KNOWN BUG (see below): closing an INACTIVE app tab loses the embed — the suite always activates a tab before closing it (the working + natural path) |
| `scroll_persist.jl`   | new content follows to bottom (followMode), overflow, history survives a browser reconnect |
| `file_tree.jl`        | per-chat sidebar file tree: ▸ toggle reveals + lazy-loads the worker project root (dirs first), expanding a dir lazy-loads children, the search box fuzzy-filters the project file index (`.git/` excluded), clicking a file opens a Monaco panel; the editor open-guard toasts (and opens NO panel) on a binary/oversize/folder/missing target |
| `worker_lifecycle.jl` | worker online on dashboard, killed process → offline                   |
| `cross_worker.jl`     | a second worker registers (2 online), kill → 1                         |
| `todo_taskbar.jl`     | live todo as a pinned panel, plan update mutates it in place (done/active), turn end finalizes to one bubble + drops the pin |
| `tool_rendering.jl`   | tool kinds: multi-edit diff stack, search rows, bt_julia_eval stdout/result sections, read-as-code, move/fetch header summaries, execute status pill pending→in_progress→completed |
| `lens.jl`             | lens search bar: vocabulary, autocomplete, apply filter (only matching messages visible), clear, save chip + persist + delete |
| `errors.jl`           | an error reply renders an inline `[error: …]` bubble; busy clears after the failed turn |

## Retired from `../electron/` (behaviour now covered above)

`test_layout.jl`, `test_mobile.jl`, `test_responsive_pane.jl` → `chat_features.jl`
(responsive); `test_chat_input.jl`, `test_chat_messages.jl` → `workflows.jl`;
`test_chat_streaming.jl`, `test_markdown.jl` → `chat_features.jl`;
`test_dashboard.jl` → `workflows.jl`/`worker_lifecycle.jl`; `test_persistence.jl`
→ `scroll_persist.jl`; `test_worker_handshake.jl`, `test_worker_disconnect.jl`
→ `worker_lifecycle.jl`; `test_todo_taskbar.jl` → `todo_taskbar.jl`;
`test_tool_variants.jl`, `test_tool_kinds_extra.jl` → `tool_rendering.jl`;
`test_lens.jl` (the UI test) → `lens.jl` (the root `test/test_lens.jl` lens-core
unit test stays — it is headless, not a UI test).

## Former `../electron/` backlog — now ported (tier removed)

- `test_streamed_tool_input.jl` → `streamed_tool_input_test.jl` (partial `rawInput`).
- `test_chat_errors.jl` → inline `[error: …]` in `errors.jl`; the transport-DEATH
  path (agent dies → `session_alive` false) is asserted by `cancel_escalation_test.jl`.
- `test_virtual_scroll.jl` → `virtual_scroll_test.jl`; `test_keyed_list.jl` →
  `keyed_list_test.jl`; `test_chat_remount.jl` → `chat_remount_test.jl`;
  `test_chat_controls.jl` → `chat_controls_test.jl`; `test_auto_prompt.jl` →
  `auto_prompt_test.jl`; `test_folder_threads.jl` → `folder_threads_test.jl`;
  `test_chat_show*.jl` → `chat_show_test.jl` / `chat_show_extras_test.jl`;
  `test_chat_background_tab.jl` → `background_tab_test.jl`; `test_layout_fixes.jl` →
  `layout_fixes_test.jl`; `test_resume_no_jserrors.jl` → `resume_no_jserrors_test.jl`.
- `test_follow_pill.jl` → `follow_pill_test.jl`; `test_scroll_chase.jl` →
  `scroll_chase_test.jl` (black-box, driving the real scroller — the legacy tests
  poked internal state; the ports keep the load-bearing invariant black-box).
- `test_chat_attach.jl` → `chat_attach_test.jl` (synthetic ClipboardEvent, no OS dialog).
- `test_chat_cancel.jl` → `chat_cancel_test.jl` / `cancel_escalation_test.jl`.
- `test_worker_move.jl` → `worker_move_test.jl`; `test_cross_worker_sync_ui.jl` →
  `cross_worker_sync_ui_test.jl`; the backend reconcile (`same_name_siblings` /
  `compare_projects` / `sync_across_workers!`) → headless `../unit/cross_worker_sync_test.jl`.
- `test_remotesync.jl` → headless `../unit/remotesync_test.jl`.
- `test_chat_stress.jl` → the real-`serve()` render path is exercised by every
  dev_server suite (`smoke_test.jl`, `chat_features.jl`, `workflows.jl`).

## Headless limitations (intentional gaps, NOT missing ports)

- The exhaustive scroll-stress *matrix* (former `test_scroll_stress.jl` — keyboard ×
  streaming × thoughts × tools × attach × user-scroll combinations): its
  load-bearing invariants live in `scroll_chase_test.jl`, but the full matrix needs
  real hardware wheel input on a VISIBLE window — a headless `show=false` window
  ignores synthetic `wheel`/`scrollTop` and even `webContents.sendInputEvent`
  mouseWheel (verified three ways; see `scroll_persist.jl`'s header). `profile_scroll.jl`
  (the old profiling harness) went with the tier.
