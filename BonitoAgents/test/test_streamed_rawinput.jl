# Streamed tool input — migrated onto the TestKit harness (real dev_server, real
# worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked via the `agent=` callback).
#
# Real claude-agent-acp ships tool arguments on a later tool_call_update, so a
# tool's input "streams in":
#
#   tool_call          status=pending   rawInput={}          ← arguments NOT yet known
#   tool_call_update   status=running   rawInput={code,...}  ← arguments arrive, still running
#   tool_call_update   status=completed                      ← result
#
# Pre-fix, the empty initial rawInput was snapshotted into the ToolMsg and never
# refreshed: no live code preview / ⏱ / ⊗ for real evals, and the ✎ editor
# button on Read/Edit resolved the DISPLAY TITLE ("Read hello.jl") as a path —
# a button that silently did nothing.
#
# The old test scripted these through a deleted MockTransport and asserted the
# raw comm events. This is genuinely agent-driven, so it's now a DOM e2e: the
# agent callback opens each tool with `complete=false` carrying the streamed
# `raw_input`, HOLDS it live with a `delay`, then completes it with
# `tool_update` — the exact pending → in-flight → completed sequence. (`TK.tool`
# exposes no rawInput field; we merge a `"raw_input"=>Dict(...)` key into the
# event Dict so the mock forwards it as the ACP `rawInput`, and the chat derives
# the eval preview / path-link / taskbar flag from it exactly as in production.)
#
# `editable_path_from` / `mcp_path_hint` are pure (no agent), so they ALSO get a
# direct unit test of the key contract: the ✎ resolves from rawInput.file_path,
# NOT from the display title.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
using .TestKit: tool, tool_update, text, text_block, delay, end_turn

const EVALNAME = "mcp__btworker__bt_julia_eval"

# `TK.tool` exposes no rawInput parameter (claude usually sends it on a later
# update, not the opening header). Merge it into the event Dict so the mock's
# generic `tool` handler forwards it as the ACP `rawInput`.
with_raw(ev::AbstractDict, raw::AbstractDict) = merge(ev, Dict("raw_input" => raw))

# ── Pure unit: the ✎ derivation resolves rawInput.file_path, NOT the title ───
@testset "editable_path_from resolves rawInput.file_path, not the display title" begin
    # The exact derivation the ✎ click handler runs: a header dict carrying the
    # tool's path_hint (from rawInput.file_path) yields the REAL path, while the
    # display title "Read hello.jl" alone must NOT be treated as a path.
    @test BT.mcp_path_hint(Dict{String,Any}("file_path" => "/abs/hello.jl")) == "/abs/hello.jl"
    @test BT.mcp_path_hint(Dict{String,Any}("code" => "1+1")) === nothing

    hd = Dict{String,Any}("kind" => "read", "title" => "Read hello.jl",
                          "path_hint" => "/abs/hello.jl")
    @test BT.editable_path_from(hd, Any[]) == "/abs/hello.jl"

    # No hint → the display title is NOT a path (pre-fix bug: it produced the
    # garbage path "Read hello.jl").
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "Read hello.jl"), Any[]) === nothing
end

# ── DOM e2e: bt_julia_eval streamed code/⏱/⊗ + Read path-link + bg Bash ──────
@testset "streamed rawInput — eval extras + Read path-link" begin
    # The Read tool's rawInput.file_path needs the live project's worker_path,
    # known only after new_chat — so the chat comes up with a benign agent, then
    # `s.agent_fn[]` is swapped to the real scenario (the dispatcher uses
    # invokelatest, so the swap takes effect on the next prompt).
    s = TK.dev_server()
    try
        TK.open_browser(s; width = 1280, height = 900)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        # Real project paths: write hello.jl into the server mirror, point the
        # Read tool's rawInput.file_path at the WORKER-side absolute path.
        proj  = lock(s.h.state.lock) do; s.h.state.projects[][pid]; end
        fpath = joinpath(proj.worker_path, "hello.jl")
        write(joinpath(proj.server_path, "hello.jl"), "greet() = println(\"hi\")\n")

        s.agent_fn[] = function (_msg)
            eval_raw = Dict("code" => "sleep(2); 40 + 2", "timeout" => 60,
                            "env_path" => "/tmp/p")
            Any[
                # 1. eval: open live with streamed code/timeout, hold, complete.
                with_raw(tool(; kind = "execute", title = EVALNAME, tool_name = EVALNAME,
                                id = "ev1", open_status = "in_progress", complete = false),
                         eval_raw),
                delay(4000),
                tool_update("ev1"; status = "completed",
                            content = [text_block("```julia\nsleep(2); 40 + 2\n```\n42")]),
                # 2. Read: open live with streamed file_path, hold, complete.
                with_raw(tool(; kind = "read", title = "Read hello.jl", tool_name = "Read",
                                id = "rd1", open_status = "in_progress", complete = false),
                         Dict{String,Any}("file_path" => fpath)),
                delay(4000),
                tool_update("rd1"; status = "completed",
                            content = [text_block("greet() = println(\"hi\")\n")]),
                end_turn(),
            ]
        end

        TK.send_message(s, "go")

        # ── eval: extras appear on the in-flight tool, gone on completion ────
        @test TK.wait_for(s, "eval pill arrives", """
            [...document.querySelectorAll('.bt-tool-title')]
                .some(t => (t.innerText||'').indexOf('bt_julia_eval') !== -1)
        """; timeout = 15) == true
        # Live code preview shows the streamed code while running.
        @test TK.wait_for(s, "live code preview appears", """
            (() => { const pv = document.querySelector('.bt-eval-preview pre');
                     return pv && (pv.innerText||'').indexOf('sleep(2)') !== -1; })()
        """; timeout = 8) == true
        # ⏱ timeout badge inserted (60 from the streamed rawInput).
        @test TK.wait_for(s, "timeout badge shows 60", """
            (() => { const b = document.querySelector('.bt-tool-timeout');
                     return b && (b.innerText||'').indexOf('60') !== -1; })()
        """; timeout = 5) == true
        # ⊗ stop button inserted while live.
        @test TK.eval_js(s, "document.querySelector('.bt-tool-stop') !== null") == true
        # The pill is live while the preview shows.
        @test TK.eval_js(s, """
            (() => { const n = [...document.querySelectorAll('.bt-tool-msg')]
                       .find(x => x.querySelector('.bt-tool-body[data-tool-id="ev1"]'));
                     return n && n.classList.contains('bt-tool-live'); })()
        """) == true
        # On completion the preview is removed and the status flips.
        @test TK.wait_for(s, "preview removed on completion", """
            (() => { const n = [...document.querySelectorAll('.bt-tool-msg')]
                       .find(x => x.querySelector('.bt-tool-body[data-tool-id="ev1"]'));
                     const st = n && n.querySelector('.bt-tool-status');
                     return st && st.textContent === 'completed' &&
                            document.querySelector('.bt-eval-preview') === null; })()
        """; timeout = 12) == true

        # ── read: title becomes a path-link carrying the REAL streamed path ──
        @test TK.wait_for(s, "title becomes a path-link with the REAL path", """
            (() => { const n = [...document.querySelectorAll('.bt-tool-msg')]
                       .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                     const t = n && n.querySelector('.bt-tool-title.bt-path-link');
                     return t != null && t.dataset.path === $(repr(fpath)); })()
        """; timeout = 12) == true
        # Click the title path-link → opens the editable Monaco editor on the
        # server mirror of the streamed worker path (NOT the display title).
        TK.eval_js(s, """
            (() => { const n = [...document.querySelectorAll('.bt-tool-msg')]
                       .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                     const t = n && n.querySelector('.bt-tool-title.bt-path-link');
                     if (t) t.click(); return true; })()
        """)
        @test TK.wait_for(s, "path-link click opens editable Monaco",
            "document.querySelector('.bt-file-editor .monaco-editor') !== null";
            timeout = 15) == true
        @test TK.eval_js(s, """
            (() => { const p = document.querySelector('.bt-file-editor-path');
                     return p != null && (p.innerText||'').endsWith('/hello.jl'); })()
        """) == true
        @test TK.wait_for(s, "editor shows the file content",
            "(document.querySelector('.bt-file-editor').innerText||'').indexOf('greet') !== -1";
            timeout = 8) == true

        # ── live-state check on the parsed ToolMsg: raw_input was refreshed ──
        chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        @assert timedwait(() -> !chat.busy_active[], 25.0) === :ok "turn never settled"
        msgs = lock(() -> copy(chat.msgs_store), chat.lock)
        ev = only(m for m in msgs if m isa BT.MCPToolMsg && m.id == "ev1")
        @test ev.raw_input["code"] == "sleep(2); 40 + 2"
        @test BT.tool_path_hint(ev) === nothing            # no path args on an eval
        rd = only(m for m in msgs if m isa BT.GenericToolMsg && m.id == "rd1")
        @test rd.title == "Read hello.jl"
        @test BT.tool_path_hint(rd) == fpath               # ✎ resolves the REAL path
        @test BT.stored_path_hint(chat.chat_dir, "rd1") == fpath   # persisted for reload

        TK.screenshot(s, joinpath(tempdir(), "bt-streamed-rawinput-eval-read.png"))
        @test isempty(TK.eval_js(s, "window.__errs || []"))
    finally
        close(s)
    end
end

# ── DOM e2e: a background Bash's late command/description/run_in_background ───
# A separate turn (own server) so the editor panel opened by the Read scenario
# above can't interfere. The streamed rawInput arrives on the OPEN frame; the
# pill title shows the human DESCRIPTION (not the raw script) and a background
# bash pins to the taskbar as a non-todo slot.
@testset "streamed rawInput — background Bash command/description/flag" begin
    bg_script = "for i in \$(seq 1 900); do date; sleep 2; done"
    s = TK.dev_server(; agent = msg -> Any[
        with_raw(tool(; kind = "execute", title = "Bash", tool_name = "Bash",
                        id = "sh1", open_status = "in_progress", complete = false),
                 Dict{String,Any}("command" => bg_script,
                                   "description" => "Monitor system load",
                                   "run_in_background" => true)),
        delay(2500),
        tool_update("sh1"; status = "completed",
                    content = [text_block("monitor started")]),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        TK.send_message(s, "go")

        # Pill title shows the human description, not the raw script.
        @test TK.wait_for(s, "bg bash pill shows the description", """
            [...document.querySelectorAll('.bt-tool-title')]
                .some(t => (t.innerText||'').indexOf('Monitor system load') !== -1)
        """; timeout = 20) == true
        # A background bash pins to the taskbar as a non-todo slot.
        @test TK.wait_for(s, "background bash pins to the taskbar", """
            [...document.querySelectorAll('.bt-taskbar-slot')]
                .some(el => !el.classList.contains('bt-taskbar-todo'))
        """; timeout = 10) == true

        # The parsed BashToolMsg carries the streamed command + description + flag.
        chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        @test timedwait(() -> any(m -> m isa BT.BashToolMsg && m.id == "sh1",
                                  lock(() -> copy(chat.msgs_store), chat.lock)), 15.0) === :ok
        sh = only(m for m in lock(() -> copy(chat.msgs_store), chat.lock)
                  if m isa BT.BashToolMsg && m.id == "sh1")
        @test sh.command == bg_script
        @test sh.description == "Monitor system load"
        @test sh.is_background

        TK.screenshot(s, joinpath(tempdir(), "bt-streamed-rawinput-bash.png"))
        @test isempty(TK.eval_js(s, "window.__errs || []"))
    finally
        close(s)
    end
end
