# Session-changes batch verification, migrated onto the TestKit harness (real
# dev_server, real worker subprocess, real ACP wire, real Electron browser; only
# the agent's behaviour is faked, via the `agent=` callback).
#
# A broad multi-section file; each section preserves its legacy user-visible
# assertion, driven through the REAL DOM:
#
#   #6 streamed agent chunks render as CommonMark — `**bold**`, `_emph_`, and
#       intraword `_` left alone (no italic-eats-underscore). Driven by the
#       agent callback shipping a markdown text chunk.
#   #2 tool pill's wide-mode toggle (`.bt-tool-fullwidth`) adds
#       `.bt-tool-wide-active` WITHOUT toggling the body open. Tool comes from
#       the agent callback.
#   #5 `.bt-tool-title` stays selectable (Read paths copy-pasteable) — computed
#       user-select must not be `none`.
#   #1 centered SummaryMsg renders with `.bt-summary-msg` + html body, align-self
#       center. Pushed server-side via `BT.send!` (the legacy path — a summary is
#       not an ACP stream event).
#   #9 a UserMsg pushed while queued gets `.bt-queued`; `promote_queued_user_bubble!`
#       clears it. Driven server-side via `BT.send!` + `BT.promote_queued_user_bubble!`
#       (the legacy path — the visible queued window only exists when injected
#       directly, not via the fast idle-consumer pop).
#   #8 localStorage `bt-last-pid` updates on view change (stored `<boot-id>|<pid>`,
#       so we match the suffix).
#   #7 a touched project's sidebar row survives ChatModel teardown.
#
# Two legacy sections are intentionally dropped: #3 (plotpane `.bt-pp-resize`
# drag → `--bt-chat-width`) and #4 (`.bn-floating-window` auto-hide on Home). The
# UI they asserted no longer exists — the plotpane was replaced by the
# BonitoWidgets workspace stage (`.bt-stage` / `.bw-ws-panel`): there is no
# `#bt-plotpane-dropzone`, no `.bt-pp-resize` handle, and `detach_app` now adopts
# the embed into a workspace panel rather than popping a `.bn-floating-window`.
# Those are different features now (covered by the BonitoWidgets layout tests),
# not the behavior this file guarded.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, tool, text_block, end_turn

# Markdown that exercises every render path the changes touched: bold, emph at
# word boundaries, and intraword underscores that must stay literal.
const MD_TEXT = "**hello** _world_ path/foo_bar_baz.jl"

@testset "session changes — markdown, tool toggle/select, summary, queued, last-route, sidebar survival" begin
    # The agent answers ANY prompt with the markdown chunk + a completed tool.
    s = TK.dev_server(; agent = msg -> [
        text(MD_TEXT),
        tool(; id = "t-wide", kind = "execute", title = "ls -la", status = "completed",
               content = [text_block("file1.txt\nfile2.txt\nfile3.txt")]),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # ── #6 streamed CommonMark ────────────────────────────────────────────
        TK.send_message(s, "go")
        @test TK.wait_for(s, "agent bubble landed",
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 30) == true
        # The streaming wire_chunk ships html, so rendered DOM has real markdown
        # tags rather than raw asterisks/underscores.
        @test TK.wait_for(s, "agent bubble got <strong>",
            "document.querySelector('.bt-agent-msg').innerHTML.indexOf('<strong>') !== -1";
            timeout = 10) == true
        html = TK.eval_js(s, "document.querySelector('.bt-agent-msg').innerHTML")
        @test occursin("<strong>hello</strong>", html)
        @test occursin("<em>world</em>", html)
        # The exact bug: `xxx_xxx` italicized the middle word under stdlib
        # Markdown; strict CommonMark keeps the literal text.
        @test occursin("path/foo_bar_baz.jl", html)
        @test !occursin("<em>bar</em>", html)

        # ── #2 tool pill wide toggle ──────────────────────────────────────────
        @test TK.wait_for(s, "tool mounted",
            "document.querySelectorAll('.bt-tool-msg').length >= 1"; timeout = 30) == true
        @test TK.eval_js(s, "document.querySelector('.bt-tool-msg .bt-tool-fullwidth') !== null") == true
        # Before clicking: not wide.
        @test TK.eval_js(s,
            "document.querySelector('.bt-tool-msg').classList.contains('bt-tool-wide-active')") == false
        TK.click(s, ".bt-tool-msg .bt-tool-fullwidth")
        @test TK.wait_for(s, "wide-active after click",
            "document.querySelector('.bt-tool-msg').classList.contains('bt-tool-wide-active')";
            timeout = 4) == true
        # Critical: the wide click MUST NOT toggle expand/collapse.
        @test String(TK.eval_js(s,
            "document.querySelector('.bt-tool-header').dataset.expanded")) == "false"
        # Toggle off.
        TK.click(s, ".bt-tool-msg .bt-tool-fullwidth")
        @test TK.wait_for(s, "wide-active removed",
            "!document.querySelector('.bt-tool-msg').classList.contains('bt-tool-wide-active')";
            timeout = 4) == true

        # ── #5 user-select on tool title ──────────────────────────────────────
        # The header carries NO user-select rule (styles.jl): text selects by
        # default (`auto`); only chrome opts out via `none`. Contract: not `none`.
        sel = TK.eval_js(s,
            "getComputedStyle(document.querySelector('.bt-tool-title')).userSelect")
        @test String(sel) != "none"

        # ── #1 centered session summary ───────────────────────────────────────
        # A SummaryMsg is not an ACP stream event; push it through the normal
        # send! path exactly as the legacy test did.
        BT.send!(chat, BT.SummaryMsg(chat,
            BT.SUMMARY_PREFIX * " This is the **previous** turn's summary."))
        @test TK.wait_for(s, "summary node appears",
            "document.querySelectorAll('.bt-summary-msg').length >= 1"; timeout = 5) == true
        @test TK.eval_js(s, "document.querySelector('.bt-summary-msg .bt-summary-body') !== null") == true
        # Centered: align-self resolves to `center`.
        align = TK.eval_js(s,
            "getComputedStyle(document.querySelector('.bt-summary-msg')).alignSelf")
        @test String(align) == "center"

        # ── #9 queued user bubble ─────────────────────────────────────────────
        # Inject a queued UserMsg directly (the fast idle-consumer pop would close
        # the visible window before the test could see it), then promote it.
        queued = BT.UserMsg(chat, "queued question")
        queued.queued = true
        BT.send!(chat, queued)
        @test TK.wait_for(s, "queued bubble gains bt-queued", """
            (() => { const us = document.querySelectorAll('.bt-user-msg');
                     const last = us[us.length - 1];
                     return last && last.classList.contains('bt-queued'); })()
        """; timeout = 5) == true
        BT.promote_queued_user_bubble!(chat)
        @test TK.wait_for(s, "queued class cleared after promote",
            "document.querySelectorAll('.bt-user-msg.bt-queued').length === 0"; timeout = 5) == true

        # ── #8 last-route memory in localStorage ──────────────────────────────
        # Stored as `<boot-id>|<pid>`; match the `|pid` suffix.
        stored = TK.eval_js(s, "localStorage.getItem('bt-last-pid')")
        @test endswith(String(stored), "|" * pid)
        # Navigate Home; the pid part should clear.
        TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\"\"]').click()")
        sleep(0.4)
        @test TK.wait_for(s, "last-pid pid part empty after home",
            "((localStorage.getItem('bt-last-pid')||'').endsWith('|'))"; timeout = 4) == true

        # ── #7 sidebar keeps a touched project after chat teardown ────────────
        # Tearing down the live ChatModel must NOT drop the project's row (the
        # sidebar lists touched projects independent of a live model).
        lock(s.h.state.lock) do; delete!(s.h.state.chat_models, pid); end
        BT.notify_chats!(s.h.state)
        @test TK.wait_for(s, "project row survives teardown",
            "document.querySelector('.bt-side-item[data-project-id=\"$pid\"]') !== null";
            timeout = 4) == true

        TK.screenshot(s, joinpath(tempdir(), "bt-session-changes-final.png"))

        # ── No JS errors across the whole run ─────────────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
