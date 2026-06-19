# Streamed tool input, browser side — migrated onto the TestKit harness (real
# dev_server, real worker subprocess, real ACP wire, real Electron browser; only
# the agent's behaviour is faked, via the `agent=` callback).
#
# Real claude-agent-acp ships tool arguments on a tool_call_update, so a tool's
# input "streams in". The DOM must grow / shed the late affordances accordingly:
#
#   • bt_julia_eval: while the call is in-flight (rawInput present, status not yet
#     completed) the live code preview + ⏱ timeout badge + ⊗ stop button show,
#     and the pill is `bt-tool-live`; on completion the preview is removed again.
#   • Read: once rawInput.file_path is known the tool TITLE becomes a clickable
#     path-link carrying the REAL worker path (not the display title "Read
#     hello.jl"); clicking it opens the plotpane Monaco editor on the server
#     mirror of that file, NOT expanding the pill.
#   • An agent message with a path-looking inline code span gets linkified
#     (`src/hello.jl` → path link), while a plain command word (`bash`) stays
#     unlinked.
#
# The legacy test scripted these via a deleted MockTransport. Here we drive the
# SAME wire shapes through the real stack: the agent callback opens each tool
# with `complete=false` (carrying the streamed rawInput), holds it live with a
# `delay`, then completes it with `tool_update` — exactly the pending → in-flight
# → completed sequence claude produces. (The constructor exposes no rawInput
# field, so we merge it into the event Dict directly; the mock's generic `tool`
# handler forwards it as the ACP `rawInput`.)

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: tool, tool_update, text, text_block, delay, end_turn

const EVALNAME = "mcp__btworker__bt_julia_eval"

# `TK.tool` exposes no rawInput parameter (claude usually sends it on a later
# update, not the opening header). Merge it into the event Dict so the mock's
# generic `tool` handler forwards it as the ACP `rawInput` — the chat side then
# derives the eval preview / path-link from it exactly as in production.
with_raw(ev::AbstractDict, raw::AbstractDict) = merge(ev, Dict("raw_input" => raw))

@testset "streamed tool input — eval extras, Read path-link, linkified message" begin
    # The Read tool's rawInput.file_path needs the live project's worker_path,
    # which is only known after new_chat. So the chat is brought up with a benign
    # agent, then `s.agent_fn[]` is swapped to the real scenario once the paths
    # are known (the dispatcher uses `invokelatest`, so the swap takes effect on
    # the next prompt).
    s = TK.dev_server()
    try
        TK.open_browser(s; width = 1280, height = 900)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        # Real project paths: write hello.jl into the server mirror, point the
        # Read tool's rawInput.file_path at the WORKER-side absolute path. The
        # path-link click resolves worker→server via show_server_path and opens
        # the mirror copy in the editor.
        proj  = lock(s.h.state.lock) do; s.h.state.projects[][pid]; end
        fpath = joinpath(proj.worker_path, "hello.jl")
        write(joinpath(proj.server_path, "hello.jl"), "greet() = println(\"hi\")\n")

        # One turn: open the eval tool (rawInput carries code+timeout+env_path),
        # hold it live, complete it; then open the Read tool (rawInput carries the
        # worker file_path), hold it live, complete it; then an agent message with
        # a path-looking code span. The generous `delay`s give the test a window
        # to assert the in-flight DOM before each completion.
        s.agent_fn[] = function (_msg)
            eval_raw = Dict("code" => "sleep(2); 40 + 2", "timeout" => 60,
                            "env_path" => "/tmp/p")
            Any[
                with_raw(tool(; kind = "execute", title = EVALNAME, tool_name = EVALNAME,
                                id = "ev1", open_status = "in_progress", complete = false),
                         eval_raw),
                delay(4000),
                tool_update("ev1"; status = "completed",
                            content = [text_block("```julia\nsleep(2); 40 + 2\n```\n42")]),
                with_raw(tool(; kind = "read", title = "Read hello.jl", tool_name = "Read",
                                id = "rd1", open_status = "in_progress", complete = false),
                         Dict{String,Any}("file_path" => fpath)),
                delay(4000),
                tool_update("rd1"; status = "completed",
                            content = [text_block("greet() = println(\"hi\")\n")]),
                text("Edited `src/hello.jl` for you (`bash` is a command, not a path)."),
                end_turn(),
            ]
        end

        TK.send_message(s, "go")

        # ── eval: extras appear on the in-flight tool, gone on completion ────
        @test TK.wait_for(s, "eval pill arrives", """
            [...document.querySelectorAll('.bt-tool-title')]
                .some(t => (t.innerText||'').indexOf('bt_julia_eval') !== -1)
        """; timeout = 15) == true
        # Live code preview shows the code while running.
        @test TK.wait_for(s, "live code preview appears", """
            (() => { const pv = document.querySelector('.bt-eval-preview pre');
                     return pv && (pv.innerText||'').indexOf('sleep(2)') !== -1; })()
        """; timeout = 8) == true
        # ⏱ timeout badge inserted.
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

        # ── read: title becomes a path-link; click opens the editor ─────────
        @test TK.wait_for(s, "title becomes a path-link with the REAL path", """
            (() => { const n = [...document.querySelectorAll('.bt-tool-msg')]
                       .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                     const t = n && n.querySelector('.bt-tool-title.bt-path-link');
                     return t != null && t.dataset.path === $(repr(fpath)); })()
        """; timeout = 10) == true
        # Click the title path-link.
        TK.eval_js(s, """
            (() => { const n = [...document.querySelectorAll('.bt-tool-msg')]
                       .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                     const t = n && n.querySelector('.bt-tool-title.bt-path-link');
                     if (t) t.click(); return true; })()
        """)
        # The click opens the editable Monaco editor (a Workspace panel, not
        # expanding the pill).
        @test TK.wait_for(s, "path-link click opens editable Monaco",
            "document.querySelector('.bt-file-editor .monaco-editor') !== null";
            timeout = 15) == true
        # The editor targets the server mirror of the REAL worker path (its header
        # path is the resolved server file), not the display title "Read hello.jl".
        @test TK.eval_js(s, """
            (() => { const p = document.querySelector('.bt-file-editor-path');
                     return p != null && (p.innerText||'').endsWith('/hello.jl'); })()
        """) == true
        # Editor carries the REAL file content (mirror copy).
        @test TK.wait_for(s, "editor shows the file content",
            "(document.querySelector('.bt-file-editor').innerText||'').indexOf('greet') !== -1";
            timeout = 8) == true

        # ── agent message: path-looking code spans get linkified ────────────
        @test TK.wait_for(s, "`src/hello.jl` code span becomes a path link", """
            (() => { const l = document.querySelector('.bt-agent-msg code.bt-path-link');
                     return l != null && l.dataset.path === 'src/hello.jl'; })()
        """; timeout = 15) == true
        # Plain `bash` code span stays unlinked.
        @test TK.eval_js(s, """
            (() => [...document.querySelectorAll('.bt-agent-msg code')]
                .some(c => c.textContent === 'bash' &&
                           !c.classList.contains('bt-path-link')))()
        """) == true

        TK.screenshot(s, joinpath(tempdir(), "bt-streamed-tool-input-final.png"))

        # No JS errors across the whole run.
        @test isempty(TK.eval_js(s, "window.__errs || []"))
    finally
        close(s)
    end
end
