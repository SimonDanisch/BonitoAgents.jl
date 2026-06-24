# Precompile statements from the e2e suite

Startup latency comes from compiling the **interactive** paths a browser drives —
websocket session announce, observable cascades, chat streaming, tool rendering,
scroll, ACP dispatch. Headless workloads compile the *serve/render* path but not
those. So we capture them once from the real e2e suite and ship the resulting
`precompile(...)` calls; they run during `BonitoAgents` precompilation and bake the
signatures into its pkgimage. No browser is needed at precompile/CI time — only at
capture time.

## How it fits together

- `BonitoAgents/src/precompile_statements.jl` — generated, committed. A `let` block
  of **literal `precompile(Tuple{…})` calls** (no strings, no runtime `eval`). Every
  referenced module is bound from `Base.loaded_modules` (they're all loaded
  transitively, so no extra deps). `BonitoAgents.jl` `include`s it at module end, so
  the calls run during precompilation and land in the pkgimage. A stale statement
  errors **loudly** at build instead of being swallowed.
- `precompile/capture.sh` — runs `BonitoAgents/test/e2e/run_all.jl` under
  `--trace-compile`, tracing the **server** process (and the spawned **worker** via
  `BONITOAGENTS_TRACE_DIR`, which `worker_command` honours). Raw traces → `precompile/traces/`.
- `precompile/generate.jl` — runs **in the BonitoAgents env** (`--project=BonitoAgents`),
  loads the stack, binds every referenced module, then **runs each candidate
  `precompile(...)` and keeps only the ones that resolve and return `true`** — so the
  shipped file is verified-working by construction. It prints kept/dropped counts and
  the unresolved roots (no silent dropping).

## Regenerate

The e2e suite drives a real browser, so it needs a display:

```sh
DISPLAY=:1 precompile/capture.sh        # against a running X server
xvfb-run -a precompile/capture.sh       # headless (CI)
```

`capture.sh` runs `generate.jl` for you. Commit the updated
`BonitoAgents/src/precompile_statements.jl`. Re-run after changes to the
chat/dashboard/ACP paths; dropped (non-resolving) statements are reported, not hidden.

## CI

Add a job that runs `xvfb-run -a precompile/capture.sh` and either commits the diff or
fails if the file is out of date — so the list tracks the code instead of rotting.
