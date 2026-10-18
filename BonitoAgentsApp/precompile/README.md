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
- `precompile/capture.sh` — runs a representative set of the e2e items (`ITEMS`, a
  regex over item names; the whole suite takes hours) under `--trace-compile`, in
  the traced process itself (`nworkers = 0`), where the dev server runs. Raw
  traces → `precompile/traces/`. It used to run `test/e2e/run_all.jl`, which went
  away with the move to ReTestItems; the statements then went stale from
  2026-09-25 on, and every server restart compiled the new paths on the first
  page, starving the thread every tab and worker link runs on (a 17 s stall on
  2026-10-16).
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
