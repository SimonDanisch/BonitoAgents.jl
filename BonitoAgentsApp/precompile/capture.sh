#!/usr/bin/env bash
# Capture precompile statements by running the e2e suite under --trace-compile,
# then regenerate src/precompile_statements.jl.
#
# The e2e suite (BonitoAgents/test/e2e/run_all.jl) drives the REAL dashboard in a
# browser via ElectronCall.Testing + a mock ACP binary — so it exercises exactly
# the interactive paths (chat streaming, tool rendering, scroll, ACP dispatch,
# observable cascades) that headless precompile workloads can't reach. We trace:
#   - the main/server process       (--trace-compile on the julia invocation)
#   - the spawned worker process    (BONITOAGENTS_TRACE_DIR -> worker_command
#                                     appends its own --trace-compile; see
#                                     BonitoAgentsApp.worker_command)
#
# Needs a display: run under Xvfb (CI) or set DISPLAY to a live X server.
#   xvfb-run -a precompile/capture.sh        # headless
#   DISPLAY=:1 precompile/capture.sh         # against a running Xvfb
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"   # BonitoAgentsApp/precompile
APP="$(cd "$HERE/.." && pwd)"           # BonitoAgentsApp
REPO="$(cd "$APP/.." && pwd)"           # monorepo root (contains BonitoAgents/)
TRACE_DIR="$HERE/traces"
JULIA="${JULIA:-julia}"

rm -rf "$TRACE_DIR"; mkdir -p "$TRACE_DIR"
export DISPLAY="${DISPLAY:-:1}"
export BONITOAGENTS_TRACE_DIR="$TRACE_DIR"   # opt-in subprocess tracing

echo ">> running e2e suite under --trace-compile (DISPLAY=$DISPLAY)"
# The trace is written as methods compile, independent of test pass/fail — and
# the e2e soak flakes occasionally. So don't let a non-zero exit abort the
# capture; we only care that the suites RAN and exercised the paths.
( cd "$REPO/BonitoAgents" && \
  "$JULIA" --project=. --trace-compile="$TRACE_DIR/main.jl" test/e2e/run_all.jl ) \
  || echo ">> e2e exited non-zero (soak flakes are fine — the trace is captured)"

echo ">> verifying + emitting -> BonitoAgents/src/precompile_statements.jl"
# generate.jl loads the stack to VERIFY each statement, so it runs in the
# BonitoAgents project env (not bare julia).
"$JULIA" --project="$REPO/BonitoAgents" "$APP/precompile/generate.jl" "$TRACE_DIR"
