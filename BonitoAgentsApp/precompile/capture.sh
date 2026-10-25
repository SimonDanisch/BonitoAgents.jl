#!/usr/bin/env bash
# Capture precompile statements by running e2e items under --trace-compile, then
# regenerate BonitoAgents/src/precompile_statements.jl.
#
# The e2e items (BonitoAgents/test/e2e, ReTestItems) drive the REAL dashboard in a
# browser via ElectronCall.Testing + the mock ACP agent, with the dev server in
# the test process itself, so tracing that process captures exactly the
# interactive server paths (page render, chat open, streaming, tool rendering,
# scroll, ACP dispatch, observable cascades) that headless workloads can't reach.
# What is not compiled ahead runs on first use, on the thread that serves every
# tab and worker link: a server restart then stalls the first page for seconds.
#
# ITEMS is a regex over item names. The default is a representative set (the
# whole suite takes hours): the dashboard, opening and streaming chats, every
# tool kind, evals and live apps, files, the phone layouts and the connection.
#
# Needs a display: run under Xvfb (CI) or set DISPLAY to a live X server.
#   xvfb-run -a precompile/capture.sh        # headless
#   DISPLAY=:1 precompile/capture.sh         # against a running X server
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"   # BonitoAgentsApp/precompile
APP="$(cd "$HERE/.." && pwd)"           # BonitoAgentsApp
REPO="$(cd "$APP/.." && pwd)"           # monorepo root (contains BonitoAgents/)
TRACE_DIR="$HERE/traces"
JULIA="${JULIA:-julia}"
ITEMS="${ITEMS:-^e2e:(smoke|dashboard_layout|overview|sidebar|sidebar_groups|settings_page|new_project|create_chat_no_card|chat_controls|chat_features|chat_streaming_sustained|streaming_flood|tool_rendering|edit_diff|chat_show|chat_show_extras|show_reopen|media|image_controls|media_reserve|bt_eval|bt_eval_types|eval_embed_park|eval_runs|app_reload|app_scroll|file_tree|file_view|file_open|chat_attach|file_attach|queued_messages|chat_cancel|thinking_progress|todo_taskbar|todo_app|subagent_feed|background_shell|transcript_window|scroll_anchor|follow_pill|lens|mobile_composer|mobile_media|attach_mobile|connection_guard|chat_closed_under_tab|two_tab|history_input|chat_title|usage_commands|model_search|session_notice|review|worker_colors|chat_remount|draft_survives_reload|console_clean_reload|multipane|header_collapse)\$}"

rm -rf "$TRACE_DIR"; mkdir -p "$TRACE_DIR"
export DISPLAY="${DISPLAY:-:1}"

echo ">> running e2e items under --trace-compile (DISPLAY=$DISPLAY)"
# The items run IN the traced process (`nworkers = 0`): test/runtests.jl runs
# them in a worker process of their own, which --trace-compile never reaches.
# The trace is written as methods compile, independent of test pass/fail, so a
# flaky item must not abort the capture: we only need the items to have RUN.
export ITEMS
( cd "$REPO/BonitoAgents/test" && \
  env -u JULIA_DEPOT_PATH JULIA_LOAD_PATH="@:$PWD:@stdlib" \
  "$JULIA" --project=. --trace-compile="$TRACE_DIR/main.jl" -e '
    using ReTestItems, BonitoAgents
    ReTestItems.TEST_ENVS[ReTestItems.identify_project(pwd())] = joinpath(pwd(), "Project.toml")
    ReTestItems.runtests(pwd(); name = Regex(ENV["ITEMS"]), nworkers = 0,
                         testitem_timeout = 900, logs = :issues)' ) \
  || echo ">> e2e exited non-zero (a flaky item is fine: the trace is captured)"

echo ">> verifying + emitting -> BonitoAgents/src/precompile_statements.jl"
# generate.jl loads the stack to VERIFY each statement, so it runs in the
# BonitoAgents project env (not bare julia).
"$JULIA" --project="$REPO/BonitoAgents" "$APP/precompile/generate.jl" "$TRACE_DIR"
