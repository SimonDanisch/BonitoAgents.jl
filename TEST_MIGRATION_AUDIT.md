# Test architecture migration — audit

Goal: delete all fake transports (`LocalTransport`, `BonitoAgents.MockTransport`, the ACP
channel-`MockTransport`) and the no-transport `ChatModel` default. Replace with ONE reactive
mock ACP **agent** (Dict/callback, Malt-shipped) behind a **real** transport. App tests driven
type→send→watch-DOM over a long-lived `dev_server(url)` (also runnable against the packaged
binary). ACP protocol invariants stay in `AgentClientProtocol/test` over a real
`SubprocessTransport`. Server is NOT reset between tests (stateful soak) → final leak audit.

## Buckets (BonitoAgents/test, non-electron)

### PURE-UNIT — but most lean on MockTransport as a fixture (decision needed)
| file | fixture today | true-pure? |
|---|---|---|
| test_lens.jl, test_meaningful_title.jl | none | YES — keep verbatim |
| test_persistence.jl, test_show_tool.jl, test_edit_tool_compact.jl, runtests.jl | none | YES — keep |
| test_eval_bridge.jl | none (EvalBridge unit) | YES — keep |
| test_tool_messages.jl, test_render_extras.jl, test_thinking.jl, test_summary_msg.jl, test_queued_messages.jl, test_tool_content_cache.jl, test_sidebar_open_chats.jl, test_bonito_app_lifecycle.jl, test_tool_close_total.jl, test_refresh_broken_titles.jl, test_worker_state.jl | MockTransport / direct ChatModel+ServerState poke | NO — test pure-ish logic but stand up a ChatModel to do it |

→ **Decision:** the bottom group must either (a) extract the pure function and test it directly
(true unit, no fixture), or (b) become DOM-e2e. Lean (a) for rendering/parsing/coalescing
logic; (b) only where the assertion is genuinely about chat-pipeline behavior.

### DOM-E2E — promote to UI-driven over dev_server
test_restart.jl, test_restart_real_transport.jl, test_session_config.jl, test_streamed_rawinput.jl,
test_concurrent_turns.jl, test_acp_log.jl, test_review_fixes.jl, test_bg_poller.jl,
test_cancel_stress.jl, test_clean_cancel.jl, test_cancel_escalation.jl, test_mcp_ctrl.jl,
test_chat_remote_app.jl, test_dev_server_worker.jl, test_provider_switch.jl (switch/restart half)

### ACP-PROTOCOL — move to AgentClientProtocol/test over real SubprocessTransport
test_transport_eof.jl, test_history_sync.jl + the existing 14 ACP `runtests.jl` testsets.
All drivable by a mock agent emitting frames over a real SubprocessTransport EXCEPT
**A7 push_snapshot!** (inspects channel buffer internals) → keep as a white-box unit test.

## ALREADY-DOM-E2E (the `_e2e`/stress files) — 11 files
test_popup_dock_e2e, test_bt_show_app_stress, test_bt_show_app_e2e, test_edit_tool_e2e,
test_real_e2e, test_bt_eval_e2e, test_real_lens_e2e, test_remote_embed_electron,
test_resume_discover_e2e, test_provider_switch_e2e, test_bg_kill_e2e.
Already drive a real `dev_server` + Electron/headless via the **TestKit** harness, mostly over a
real transport + **mock-agent binary** (some opt-in real-claude under `BT_RUN_E2E=1`). These are
the model to converge on. Work: confirm mock-agent fixture, adopt no-reset + leak audit.

## ELECTRON suite (27 files) — already DOM-driven, but fakes the agent
**Central finding:** `electron/helpers.jl` fakes the agent with `MockTransport` (a fake ACP
responder), NOT a real-transport mock agent. So all 27 electron tests inherit the fake **through
one shared helper** — swapping that helper to mock-agent-over-worker fixes the whole suite at once.
- Soak-compatible (share state across cases): test_keyed_list, test_virtual_scroll, test_folder_threads,
  test_chat_controls, test_auto_prompt, test_chat_stress, test_chat_streaming_sustained, profile_scroll.
- Reset-per-case (`make_state()` per test → move last / isolate): test_chat_show, test_chat_show_extras,
  test_chat_errors, test_cross_worker_sync_ui, test_worker_move, test_cross_worker_sync, test_remotesync.
- NEEDS-WORK (within-file accumulation): test_layout_fixes, test_scroll_stress, test_chat_attach,
  test_session_changes, test_scroll_chase, test_follow_pill, test_streamed_tool_input,
  test_resume_no_jserrors, test_chat_background_tab, test_chat_remount.

## RESETS-STATE → run LAST in the soak (and/or isolate)
test_restart, test_restart_real_transport, test_stability, test_concurrent_turns, test_worker_state,
test_provider_switch, test_mcp_ctrl, test_dev_server_worker, test_bg_kill_e2e; electron:
test_chat_show*, test_chat_errors, test_cross_worker_sync*, test_worker_move, test_remotesync.

---

## Leak ledger

### MUST-RETURN-TO-BASELINE (assert empty/at-baseline after a chat closes / soak ends)
| container | where | drained by | leak risk |
|---|---|---|---|
| `state.chat_models` | state.jl:158 | `stop_session!` (dashboard.jl:425) | orphaned if worker disconnects before delete, or session dies mid-render (stop_session! never runs) |
| `BG_POLLERS` IdDict | chat.jl:2345 | poller `finally` on `user_messages` close | leaks if `close(model)` never runs |
| `ChatModel.consumer_task` | chat.jl:85 | ends on `user_messages` close | assert `istaskdone` after close |
| `ChatModel.user_messages` | chat.jl:55 | `close(model)` | — |
| `RESTART_INFLIGHT`/`RESTART_GEN` | chat.jl:3151/3161 | restart `finally` | accumulate on rapid switches if bring-up never completes |
| `EVAL_WORKERS` | remote_app.jl:46 | `teardown_eval_bridge!` via stop_session! | orphan on worker disconnect (redial keeps it; only explicit stop deletes) |
| `EvalBridge.pending`, `MCP_CTRL`, `BRIDGE_ATTACHED`, `MOUNTS` | remote_app.jl | finally / WS-drop / bridge teardown | safe |
| `PENDING_PERMISSIONS`/`PENDING_QUESTIONS` | chat.jl:2885/2978 | handler finally + `sweep_pending_asks!` at turn end | safe |
| ACP `Connection.pending`/`active_turns`/`inbox`/`reader_task`/`dispatcher_task` | connection.jl | dispatcher/reader `finally` on transport close | safe by design (drains even on hard EOF) |
| `state.pending_rpcs`, `state.worker_control_ws` | state.jl:172/168 | response / disconnect | worker_control_ws deletion path UNCLEAR on abrupt disconnect |
| per-session Observable bridges | state.jl/chat.jl `map(identity,session,parent)` | Bonito session close | auto-GC; this is what the Bonito leak check asserts |

### GROWS-BY-DESIGN (do NOT assert baseline)
`state.workers`/`projects`/`discovered` (disk mirror), `msgs_store` (history),
`SHOW_FETCH_INFLIGHT` (one lock/path), `EvalBridge.root_conn` Ref.

### Mirror the Bonito leak check
Bonito's tests (dev/Bonito/test/basics.jl ~86–100): after `close(session)` assert
`isempty(obs.listeners)`, `isempty(session_objects)`, child removed from parent. Our analog,
after `stop_session!` (and after a full open/send/close soak cycle ×N):
```
!haskey(state.chat_models, pid)
!haskey(BG_POLLERS, model) && istaskdone(model.consumer_task[])
!haskey(EVAL_WORKERS, pid) && !haskey(RESTART_INFLIGHT, model)
conn.closed && istaskdone(reader_task) && istaskdone(dispatcher_task) && isempty(conn.pending)
no orphan agent/worker OS processes beyond baseline
Bonito session count + object cache back to baseline
```
This set is exactly what would have caught this session's bugs (reader spin, subprocess orphan,
chat_models/BG_POLLERS retention).
