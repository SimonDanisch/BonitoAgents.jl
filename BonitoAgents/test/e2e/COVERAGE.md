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
- **No-JS-errors gate**: a suite samples the error sink (`window.onerror` +
  `unhandledrejection`, installed in `open_browser`) and asserts it empty.
  Driving the real DOM is only worth it if we also notice when the DOM throws.
  ⚠ **It is NOT attributed, and NOT cleared between items.** The old `run_all.jl`
  cleared after every suite; under ReTestItems nothing does, and only a handful
  of items call `clear_js_errors` themselves (`overview`, `chat_controls`,
  `layout_fixes`, `subagent_feed`, `resume_no_jserrors`). So on the shared
  server `isempty(js_errors(s))` means "nothing threw since the last item that
  happened to clear", not "this item was clean" — a failure can have been
  produced by any item since. Before reading a red gate as "this suite broke
  it", re-run that item ALONE; that is what separated a pre-existing Monaco
  resize loop from an unrelated diff here.
- **Un-hangable**: every bridge round-trip (`eval_js`, `js_errors`,
  `clear_js_errors`) is watchdog-bounded and throws a typed `BridgeTimeout`;
  `wait_for` treats a busy poll as "not yet" and retries within its own budget. A
  pegged renderer can never hang the run.
- **Resilient**: a suite that fails is recorded and the soak CONTINUES — the leak
  audit still runs, and the failure is re-surfaced as a final failing testset.
- **Leak audit** at the end asserts server-side bounds (models / pollers /
  mock subprocs / worker-ws / pending) and logs the counts.
- **Eval-bridge isolation per chat**: the server registers one eval bridge per
  PROJECT (`state.eval_workers[project_id]`), while the MCP eval-session pool is
  keyed by env_path, is process-global, and never dials twice. In one test
  process that meant the SECOND chat to eval in a given env inherited the first
  chat's dial: no bridge was ever registered for it, so its live embeds rendered
  from their snapshot but had no browser↔worker route — they looked right and
  were dead. `new_chat` now re-points the dial-back when the project id changes
  (the worker stays warm), which is what production gets for free by giving each
  chat its own MCP process. Symptom if this regresses: an eval-embed suite
  passes ALONE and fails when another eval suite ran first, its liveness
  assertions timing out while the embed's DOM is present. Reproducer:
  `test_args=["e2e:app_reload", "e2e:app_scroll"]`.
- **A clean environment for spawned workers**: `Pkg.test` runs us under
  `JULIA_LOAD_PATH="@:<testdir>"`, which is missing `@stdlib`, and every process
  we spawn inherits it — so an eval worker could not load a single stdlib
  (`using Markdown` → "Package Markdown not found in current path") even though
  its committed env correctly expects stdlibs to come from `@stdlib`. The same
  path also silently switched evals to FILE scope, because the worker's REPL
  soft-scope transform failed to resolve and fell back to `identity`; a
  top-level `for` assigning a global then died with "UndefVarError: acc not
  defined in local scope", which reads as a bug in the test's own code.
  Fixed at the source in `BonitoMCP.worker_env()` (a spawned worker gets Julia's
  DEFAULT load path when one was inherited) plus `Base.require` for REPL, and
  `TestKit.__init__` clears the variable so the whole spawned tree is clean.
  `unit:eval_worker_env` pins all of it headlessly. Symptom if this regresses:
  an eval case fails on `using <any stdlib>`, or a REPL-semantics case fails,
  under `Pkg.test` while the same env works from a shell.
- **Eval projects are COMMITTED, never built at runtime** (`test/evalenv`,
  `test/altenv`; warmed up in runtests.jl). A project assembled with
  `mktempdir` fails two ways at once: with no Bonito declared it resolves
  whatever the machine's global `@v#.#` env holds — a registered Bonito v4 has
  no `proxy_send`, the bridge gate (`MIN_BRIDGE_BONITO`) correctly refuses, and
  every live embed renders "(result not live — worker gone and no snapshot)" on
  that machine only — and it pays a cold precompile on first touch, so the same
  assertions time out on a cold depot and pass on a warm one. Both were observed
  here. Symptom if this regresses: an eval assertion that passes for you and
  fails for someone else, or passes on a re-run.

## Agent subprocesses ORPHAN when a worker is killed

The worker spawns its agent with `open(Cmd(…), "r+")` (BonitoWorker.jl:914) — a
plain child in the worker's own process group. A SIGKILLed worker does not take
that child with it, so every test that kills a worker (`worker_lifecycle` does it
on purpose) leaves a `MockACP` process behind, and they ACCUMULATE across runs.
Measured on 2026-08-18: **3 orphans per full suite run** (0 before → 3 after, on a
clean box), which had reached 55 live orphans — the oldest 41 hours — over a few
days of running the suite.

They are individually small and completely silent, and the way you find out is a
*phantom failure*: with the box near 80% memory, `e2e:worker_lifecycle` took 27s
instead of its usual 7s and timed out waiting for "0 workers online". Killing the
orphans and re-running the same item on a quiet box: 5.8s, green. So before
believing a timing-shaped e2e failure, check `pgrep -cf "[M]ock[A]CP"` — and get a
quiet-box baseline before blaming the diff.

In production the same mechanism orphans the real `claude-agent-acp` process
whenever a worker dies abnormally. Fixing it properly means giving the agent its
own process group and killing the group on worker exit, plus reaping strays at
worker startup — NOT yet done.

## ⟳ on a file that vanished shows the old text as if it were current

`fetch_show_file` falls back to the last mirrored copy whenever the transfer
fails — the right call for a worker that briefly went away, and indistinguishable
from a fresh read for the user. Delete a file on the worker, press ⟳, and the
button flashes "reloaded" over the bytes it fetched minutes ago. The server logs
`show: transfer failed; showing the last mirrored copy`; the UI says nothing.

Reporting it in the panel status is what you would reach for, and it does not
work: writing `fe.status` from the reload path throws in the browser ("Cannot set
properties of null"), because the binding that observable feeds is not live
there. Fixing this properly means giving the panel a status channel that survives
the reload path — NOT yet done.

(Distinguishing "deleted" from "worker unreachable" needs care too:
`worker_file_stamp` returns `nothing` for both.)

## Known product bug surfaced by the soak

`streaming_flood.jl` runs EARLY (2nd) on purpose. A large message burst paints in
~1–2s on the first chats but the renderer WEDGES by ~chat #3 once many messages are
mounted (cost ≈ mounted × streamed — a client-side cross-chat accumulation, not a
deadlock and not server-side). Running the flood early isolates its real target
(the `deliver_update!` deadlock regression) from this separate, still-open bug.

## A failed page load used to desync the Electron command stream (FIXED)

Symptom, seen twice in `e2e:file_view` before it was understood: an
`AssertionError: Invalid response format from Electron` in one testset, and then
a later assertion failing against a value from a completely different query —
`@test isempty(TK.js_errors(server))` evaluating as `isempty(1066)`, where 1066
was a Monaco layout width.

Cause: `connection` is a strict request/response stream (`req_response_js` writes
one command and reads one line, under `app.comm_lock`), but ElectronCall's
`did-fail-load` was a plain `.on` handler that wrote an `{error: …}` line onto
that stream every time a load failed — unprompted, for the life of the window.
That line is read as the reply to whatever command is in flight; it has no
"status" key, so the caller dies on the assert, and **from that moment the stream
is off by one**: every later request receives the previous request's answer, for
the rest of the session. Aborted loads are ordinary (a swapped iframe src, a
cancelled navigation), which is why this surfaced in the one suite that mounts a
PDF frame, a video and swapped `src`s — and why it looked like random nonsense.

Fixed in `ElectronCall/src/main.js`: the window-creation command is answered
exactly once, by whichever load event lands first; every later `did-fail-load`
goes to the notification socket. Pinned by "A failed load must not desync the
command stream" in ElectronCall's own `test/runtests.jl`, which reproduces it
deterministically with an iframe on a blocked port (ERR_UNSAFE_PORT, no network
needed) and then checks five distinguishable answers come back to their own
calls. Against the unfixed file that test yields
`["AssertionError: Invalid response format …", 100, 200, 300, 400]` — the
off-by-one, exactly.

Worth remembering as a debugging shape: **an assertion failing against a value
that cannot possibly come from its own query is not noise.** Four plausible
mechanisms were proposed and disproved before the real one (abandoned request
under timeout, a competing reader, JSON newline escaping, a tight polling loop);
what found it was reading every writer of the socket, not more theorising.

## The SECOND WebGL context in a window is dead on arrival

Open two `.obj` files at once and the second tab's viewer shows
`3D viewer failed: vertex shader compile failed:` — an empty info log, and
`gl.isContextLost()` is FALSE. The first panel's viewer, with the identical
`VERT_SRC` constant, compiled fine seconds earlier in the same window. Same
source, live context, no log: the context was handed out but cannot compile,
which is what a browser at its per-page WebGL budget does rather than formally
losing the context.

How far it reaches is NOT established. Chromium allows ~16 contexts per page,
so two should be nowhere near the budget — but this suite runs on Xvfb software
GL, where the ceiling can be far lower, and nobody has yet opened two `.obj`
tabs on a machine with a real GPU. So treat "every user with two 3D tabs" as
unproven and "headless/software GL" as measured. Either way the viewer taking a
fresh context per panel is what makes it fragile; the fix is to share one, or
to drop the context of panels that are not visible and re-acquire on show —
a design call, NOT yet made.

Measured 2026-08-19 on a quiet box: `e2e:file_view` hits it on `one.obj` (the
second `.obj` the suite opens), and it predates the diff that found it — a
control run with the working tree stashed hit the same assertion.

It took three layers off to see this, all of which are now gone:
`wait_for` reports a plain timeout for a dead viewer and a slow decode alike;
the failure lands on whichever assertion happens to be polling, so it moved
between the two `.obj` cases and read as "the mesh viewer is flaky"; and
`meshview.js` had been writing the real reason into `.bt-mesh-status` the whole
time with nobody reading it. `mesh_status_reaches` in `file_view.jl` now prints
that status line on failure (and tolerates a stalled bridge the way `wait_for`
does, but COUNTS the stalls instead of swallowing them), and `compile()` names
the shader and whether the context was lost — an empty log alone reads as a
GLSL bug and sends you into the wrong file.



`e2e:bt_eval` is INTERMITTENTLY red (roughly every other full run as of
2026-08-17), always on the same rendering — a tool body reading
"(result not live — worker gone and no snapshot)" where the value belongs. It
moves between testsets (`test_bt_eval_e2e.jl:105`, the simple `1 + 41` case, and
`:494`, the two-`env_path` case), so a green run proves nothing; repeat before
concluding anything. Two contributing causes are known and documented at their
sites in `remote_app.jl`: (a) the eval-bridge registry holds ONE bridge per
project while eval sessions are pooled per `env_path`, so a chat evaluating in
two envs has its first bridge evicted by its second, and (b) `RemoteRef`'s
static snapshot is always empty, so a slow or lost live mount has nothing to
fall back to and shows the not-live note instead of the value. Fixing (b)
requires reworking the "LIVE fragment" assertions, which currently rely on the
absence of a snapshot to detect deadness.

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
| `attach_mobile.jl`    | the composer at PHONE width (390×780, its own server + window since `open_browser` sizes at open time and the shared one is 1280): the mobile media block is actually active, the attach button keeps a ≥40px tap target and stays fully on screen, neither the input row nor the input area overflows sideways, the textarea keeps >50% of the row, tapping the button drives the hidden file input, a picked image queues a thumbnail without pushing the composer off screen, and focus lands back in the textarea |
| `chat_close_rename.jl`| homebar ✕ closes a chat (leaves the list, back to dashboard, model torn down, `dismissed` persisted); closing one leaves the others; header rename is consistent in homebar + header and persists across a chat switch; a fresh chat binds its claude session id (the "name reverts to first message" root fix); reopening a closed chat restores it under its title |
| `header_collapse.jl`  | narrow-pane header: below the container breakpoint ONE ⋯ toggle replaces the action cluster + env line + lens bar; checking it (glyph → ✕) expands them all in flow as a full-width stack under the toggle (controls stretch + center); unchecking collapses; a checked toggle never leaks into the wide layout |
| `app_reload.jl`       | a live eval-result app (RemoteRef embed) survives a real browser page reload twice: remount is fully self-contained (fresh instance at 0, click round-trips through the eval bridge), and a history-replayed Edit pill stays expandable |
| `eval_embed_park.jl`  | a live eval-result embed gets bt_show_app's output handling: the completed card is flagged `live_embed` → `data-bt-app` + ⤢ detach; scrolling it out of the virtual-scroll window PARKS it display:none (connected, alive — a counter clicked to 13 survives, never re-rendered) not removed; ⤢ detach adopts the same live node into a workspace panel and close restores it, live throughout |
| `embedded_app.jl`     | `bt_show_app` dial-back eval bridge + embedded frame render            |
| `leak_cycle.jl`       | open a 500-msg flooded chat + N churn chats, close ALL from the homebar ✕, then assert the server's bounded resources return to baseline — ChatModels evicted from the cache, background pollers gone, mock subprocesses reaped, pending RPCs drained, process RSS not ballooning. (A WeakRef-after-GC "still alive" count is logged but NOT asserted: Julia's conservative C-stack GC makes it non-deterministic noise, not a leak signal.) |
| `app_scroll.jl`       | moving a live EVAL EMBED between bubble/float/tab must NOT scroll the chat. Asserts scroll held on dock and on close, the app stays live (Julia round-trip, never the "Reload live app" placeholder), and re-detach works across seven cycles |
| `app_stress.jl`       | bt_show_app moved bubble↔float 100×, chat-switch round-trips, asserting the SAME live node survives every move via a preserved counter; no orphan nodes, no JS errors |
| `app_interactive.jl`  | TWO live bt_show_apps at once; clicking each runs its Julia `map` in the worker (output = 7×clicks / 100+clicks, never computed in JS) and the DOM reflects the round-tripped value; the two apps stay independent |
| _(missing)_ `app_multi.jl` | NOT PORTED. Deleted with `bt_show_app`; the behaviour still exists via eval embeds (several live apps detached at once, driven independently, surviving a chat switch, closed one-by-one) but nothing covers it. `app_scroll.jl` covers the single-app case. |
| `app_tabs.jl`         | THREE apps docked into ONE window as TABS (via the float's ⤢ dock button): switch between tabs (active app visible, others hidden), each stays LIVE as a tab (Julia round-trip), then close the tabs (active-tab close → embed back to its bubble). KNOWN BUG (see below): closing an INACTIVE app tab loses the embed — the suite always activates a tab before closing it (the working + natural path) |
| `scroll_persist.jl`   | new content follows to bottom (followMode), overflow, history survives a browser reconnect |
| `file_tree.jl`        | per-chat sidebar file tree: ▸ toggle reveals + lazy-loads the worker project root (dirs first), expanding a dir lazy-loads children, the search box fuzzy-filters the project file index (`.git/` excluded), clicking a file opens a Monaco panel, clicking a BINARY file opens a hex view; the open-guard toasts (and opens NO panel) only for what no viewer can show (oversize / folder / missing / unreachable worker) |
| `file_view.jl`        | the rich file viewer: png (image stage + reported pixel size, no editor), md (rendered by default, Source toggle holding the real text, Save writes the WORKER file and the preview follows), csv (sortable table of the right shape), obj (server-side parse → BTMESH1 blob → WebGL viewer reporting the decoded triangle/vertex counts, in singular for one triangle), .bin (hex dump, never Monaco), mp4 (video stage, centred, a 1600px-tall clip FITTED so its controls stay on screen) and a tall png held to the same rule, pdf (the frame is pointed at its file from inside the document — see Headless limitations); every panel header names the WORKER path, and renders it in reading order rather than letting `direction: rtl` move the leading `/` to the end; and the editor re-lays-out when its panel changes width (Monaco's own `automaticLayout` is off — it calls `layout()` from inside its ResizeObserver's delivery cycle, which is what made this suite's no-JS-errors gate fail on "ResizeObserver loop completed with undelivered notifications"; the replacement defers to the next frame, and the test pins that it still follows the panel in BOTH directions) |
| `review.jl`           | change-review tab: the Review button opens the project's git diff incl. UNTRACKED files (marked added) with both sides' line numbers; Ask sends the question to the chat immediately with its code context; Feedback batches into the tray (counted on the Send button), sends ONE numbered instruction and only then clears; shift-click covers a BLOCK and the range + every line in it reach the agent; chips drop; ⟳ re-reads the tree; ⤢ opens the file itself |
| `review_scope.jl`     | the review diff is SCOPED to the project's folder: a package inside a bigger checkout lists its own change and its own untracked file, NOT a sibling's; rows drop the shared prefix while `data-file` stays relative to the PROJECT (the agent's cwd — a root-relative path would send it to `pkg/pkg/…`); the header names the folder, not the repository above it. Its own dev_server AND its own single chat: two review panels in one window cannot be told apart by `querySelector` (answers about the first) nor by "which is visible" (an inactive panel still has an `offsetParent`) |
| `debug_chat.jl`       | "Debug BonitoAgents": the dashboard button opens the chat AND navigates to it, rooted at this server's own checkout; the same button in a chat header goes to the same place; pressing it again reuses the one chat |
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
- `test_chat_attach.jl` → `chat_attach_test.jl` (synthetic ClipboardEvent, no OS
  dialog; also covers the attach button, the `change`-driven picker path and the
  10-image queue cap).
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

- **Drags that rely on POINTER CAPTURE.** `webContents.sendInputEvent` mouse
  moves do not honour `setPointerCapture`, so a handler that captures on
  `pointerdown` and then reads `pointermove` (BonitoWidgets' split gutter does
  exactly this) only sees the moves that happen to land on the element itself.
  A 300px synthetic drag of the 9px gutter moved the split by 8px, which reads
  exactly like "resize is broken". It is not: dispatching the same
  `PointerEvent`s directly at the gutter moves it 298px. Before filing a
  drag-shaped bug, dispatch the events at the element and see whether the
  handler was ever the problem. (Tab-drag-to-split does work through
  `sendInputEvent` — it does not use capture.)

- **The native FILE DIALOG.** Clicking the composer's attach button opens an
  OS-modal picker that nothing in-page can dismiss, so a real click would hang
  the run forever. `chat_attach_test.jl` stubs the hidden input's own `.click`
  and counts calls: the delegated button handler, the `change` listener and
  `_attachAddBlob` all still run for real, and the File that reaches them is a
  genuine browser `File` assigned through `input.files = dataTransfer.files`.
  What is NOT covered is the picker's own behaviour — whether `accept="image/*"`
  really surfaces the camera sheet is the browser's contract, not ours.

- **Keys that insert TEXT.** `sendInputEvent({type:'keyDown'})` alone does not
  type anything: the browser inserts on the `char` event. Testing Shift+Enter
  with keyDown only shows "the composer refuses newlines" when the composer is
  fine. Send keyDown → char → keyUp for anything that should produce a
  character.

- **Whether a PDF actually PAINTS.** Chromium renders a PDF through an
  out-of-process viewer, and a live one is indistinguishable in the DOM from a
  dead one: both frames navigate, and both contain an `<embed
  type="application/pdf" src="about:blank">`. That is not a curiosity — it is how
  a real bug hid here. An `<iframe src=…>` that arrived already-sourced through
  Bonito's node insertion never got a live view, so every PDF tab was the
  viewer's dark backdrop and nothing else, while every DOM assertion passed.
  Found by screenshotting, fixed by assigning `src` from inside the document
  (`initFrame`, assets/fileview.js). `file_view.jl` therefore asserts the
  PLUMBING (`data-frame-src` → `src`, with `data-fv-ready`); a regression in the
  paint itself needs an eyeball on a screenshot.
