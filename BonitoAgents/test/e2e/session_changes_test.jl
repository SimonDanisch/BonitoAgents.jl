# Black-box port of the legacy in-window `test/electron/test_session_changes.jl`
# onto the shared soak server. Everything here drives the REAL `dev_server`
# through electron only (DOM events + eval_js) — no server-state introspection,
# no internal-API calls. Each assertion the legacy script made that is
# reproducible black-box is preserved; the ones that aren't are NOTED below.
#
# Covered black-box:
#   • markdown rendering of a streamed agent chunk — bold/emph + intraword `_`
#     stays literal (legacy #6; reuses chat_features' markdown asserts and adds
#     the underscore-eating regression the legacy script flagged)
#   • tool wide-mode toggle (legacy #2) — expand the body, click the
#     `.bt-tool-fullwidth` button, assert `.bt-tool-wide-active` toggles on/off,
#     the card actually WIDENS (max-width beats the embed cap), and the wide
#     click does NOT toggle the body (`data-expanded` stays)
#   • tool title stays text-selectable (legacy #5) — computed user-select != none
#   • localStorage `bt-last-pid` persistence on view change (legacy #8) — value
#     is `<boot>|<pid>`, so we match the `|pid` suffix and the empty-pid suffix
#     after navigating Home
#
# NOT reachable black-box through the TestKit DSL (NOTED, not silently dropped):
#   • SummaryMsg (legacy #1): a `.bt-summary-msg` is rendered only for an ACP
#     `UserMessage` whose text starts with `SUMMARY_PREFIX` (see
#     `is_summary_text` + `adopt_replayed!`/`msg_for` in src/chat.jl). The mock
#     agent (test/mocks/mock_claude_agent_acp.jl) has NO event that emits a
#     `UserMessage` — a `text` event always becomes an `agent_message_chunk`
#     (→ `.bt-agent-msg`). The legacy test reached it only by calling
#     `BT.send!(chat, BT.SummaryMsg(...))` against an in-process model, which is
#     exactly the internal-API path the black-box harness forbids. To cover it
#     here we'd need a new TestKit DSL event (e.g. `user_message`/`summary`) that
#     drives the mock to emit a `session/update` `user_message_chunk` with the
#     summary prefix. Left as a harness gap.
#   • Queued user bubble `.bt-queued` (legacy #9): only observable by injecting a
#     pre-queued `UserMsg` via `send!` and manually driving
#     `promote_queued_user_bubble!` — internal API; the production consumer pops
#     + promotes too fast for the JS race window to be seen black-box.
#   • Resumable / touched-project row survival (legacy #7): requires mutating
#     `state.chat_models` + `notify_chats!` directly (internal API). Black-box,
#     a project row's lifecycle is already exercised by chat_features' sidebar
#     switching; the teardown-survival contract has no UI-only trigger.
#   • Plotpane resize handle (#3) + FloatingWindow auto-hide (#4): these were
#     already separate concerns in the legacy file and live in the workspace /
#     popup layer, not the session-changes batch this port targets.
@testitem "e2e:session_changes" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # A markdown chunk that exercises every render path the legacy #6 touched:
    # bold, emph at word boundaries, and intraword underscores that must stay
    # literal (the `xxx_xxx` regression — stdlib Markdown italicised the middle
    # word; strict CommonMark must keep it literal).
    const MD_TEXT = "**hello** _world_ path/foo_bar_baz.jl"

    s.agent_fn[] = function (prompt)
        if occursin("tool", lowercase(prompt))
            return [TK.tool(kind = "execute", title = "ls -la", id = "t-wide",
                            tool_name = "Bash", status = "completed",
                            content = [TK.text_block("file1.txt\nfile2.txt\nfile3.txt")]),
                    TK.end_turn()]
        else
            return [TK.text(MD_TEXT), TK.end_turn()]
        end
    end

    pid = TK.new_chat(s; title = "Session")

    # ── legacy #6: streamed CommonMark ────────────────────────────────────────
    TK.send_message(s, "go")
    @test TK.wait_for(s, "agent bubble landed",
        "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 30) == true
    @test TK.wait_for(s, "agent bubble got <strong>",
        "document.querySelector('.bt-agent-msg').innerHTML.indexOf('<strong>') !== -1"; timeout = 10) == true
    html = TK.eval_js(s, "document.querySelector('.bt-agent-msg').innerHTML")
    @test occursin("<strong>hello</strong>", html)
    @test occursin("<em>world</em>", html)
    # The exact bug the legacy script flagged: intraword `_` must NOT italicise.
    @test occursin("path/foo_bar_baz.jl", html)
    @test !occursin("<em>bar</em>", html)

    # ── legacy #2: tool pill wide-mode toggle ─────────────────────────────────
    TK.send_message(s, "show me the tool")
    @test TK.wait_for(s, "tool card rendered",
        "document.querySelectorAll('.bt-tool-msg').length >= 1"; timeout = 30) == true

    # The wide button is in the header but CSS reveals it (display:inline-flex)
    # ONLY while the body is expanded (styles.jl: `.bt-tool-header[data-expanded=
    # "true"] .bt-tool-fullwidth`). So expand the tool body first, then drive it.
    tool_of = id -> """(() => { for (const m of document.querySelectorAll('.bt-tool-msg')) {
        if (m.querySelector('.bt-tool-body[data-tool-id="$(id)"]')) return m; }
        return null; })()"""
    @test TK.wait_for(s, "wide tool body present",
        "$(tool_of("t-wide")) !== null"; timeout = 10) == true

    # Expand the body (click its header) so the fullwidth button becomes visible.
    TK.eval_js(s, """(() => { const m = $(tool_of("t-wide"));
        const h = m && m.querySelector('.bt-tool-header'); if (h) h.click(); return true; })()""")
    @test TK.wait_for(s, "tool body expanded",
        """(() => { const m = $(tool_of("t-wide"));
            const h = m && m.querySelector('.bt-tool-header');
            return !!h && h.dataset.expanded === 'true'; })()"""; timeout = 8) == true
    @test TK.wait_for(s, "fullwidth button visible",
        """(() => { const m = $(tool_of("t-wide"));
            const b = m && m.querySelector('.bt-tool-fullwidth');
            return !!b && b.offsetParent !== null; })()"""; timeout = 8) == true

    # Before clicking: not in wide mode. Record the default width.
    @test TK.eval_js(s, "$(tool_of("t-wide")).classList.contains('bt-tool-wide-active')") == false
    w_before = TK.eval_js(s, "Math.round($(tool_of("t-wide")).getBoundingClientRect().width)")
    # Click the fullwidth button → wide-active turns ON and the card WIDENS
    # (the toggle actually does something — the regression this pins is the
    # button looking dead because a cap held the width).
    TK.eval_js(s, "$(tool_of("t-wide")).querySelector('.bt-tool-fullwidth').click(); true")
    @test TK.wait_for(s, "wide-active after click",
        "$(tool_of("t-wide")).classList.contains('bt-tool-wide-active')"; timeout = 8) == true
    @test TK.wait_for(s, "card actually widened",
        "Math.round($(tool_of("t-wide")).getBoundingClientRect().width) > $(w_before) + 20"; timeout = 8) == true
    # Critical legacy contract: the wide click MUST NOT toggle expand/collapse —
    # the header stays expanded (stopPropagation in the JS handler).
    @test TK.eval_js(s,
        "$(tool_of("t-wide")).querySelector('.bt-tool-header').dataset.expanded") == "true"
    # Toggle off → wide-active turns back OFF and the width returns.
    TK.eval_js(s, "$(tool_of("t-wide")).querySelector('.bt-tool-fullwidth').click(); true")
    @test TK.wait_for(s, "wide-active removed",
        "!$(tool_of("t-wide")).classList.contains('bt-tool-wide-active')"; timeout = 8) == true

    # ── legacy #5: tool title is text-selectable (copyable paths) ─────────────
    # The header carries NO user-select rule (styles.jl), so text selects by
    # default (`auto`); the contract is just "anything but none".
    sel = TK.eval_js(s,
        "getComputedStyle($(tool_of("t-wide")).querySelector('.bt-tool-title')).userSelect")
    @test String(sel) != "none"

    # ── legacy #8: last-route memory persists to localStorage ─────────────────
    # `current_view` changes write `bt-last-pid` as `<boot>|<pid>` (sidebar.jl).
    # The chat we just opened is the active view, so the suffix is `|<pid>`.
    @test TK.wait_for(s, "bt-last-pid ends with active pid",
        "(localStorage.getItem('bt-last-pid') || '').endsWith('|$(pid)')"; timeout = 8) == true
    # Navigate Home; the pid part should clear → trailing `|`.
    TK.to_dashboard(s)
    @test TK.wait_for(s, "bt-last-pid pid part empty after home",
        "(localStorage.getItem('bt-last-pid') || '').endsWith('|')"; timeout = 8) == true

    # ── JS errors gate ────────────────────────────────────────────────────────
    @test isempty(TK.js_errors(s))
end
