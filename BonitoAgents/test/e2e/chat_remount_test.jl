# Black-box e2e: re-mounting a chat preserves its history (regression).
#
# Ported from the legacy electron suite `test/electron/test_chat_remount.jl`.
# The bug it guards: navigating Home (to the dashboard) and back into a chat
# used to drop the rendered history — the chat pane re-mounted but the
# user/agent bubbles from before the navigation didn't repaint.
#
# Drives the REAL shared dev_server entirely through the DOM (no server-state
# introspection): build a known multi-turn history, go to the dashboard, reopen
# the chat, and assert the same bubbles (texts + counts) are still there. The
# Home→back cycle is repeated to prove the remount is stable, not a one-shot.
@testitem "e2e:chat_remount" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # Deterministic echo so each agent bubble carries a text we can assert on.
    s.agent_fn[] = prompt -> [TK.text("reply to: $(prompt)"), TK.end_turn()]

    # Distinct, easily-grepped prompts so we can confirm THESE exact bubbles
    # survive a remount (not just "some bubble is present").
    prompts = ["remount-history-one", "remount-history-two"]

    pane_visible = "!!document.querySelector('.bt-text-input') && !!document.querySelector('.bt-chatpane')"

    # All message selectors below resolve within the VISIBLE chat pane (the
    # harness installs a pane-scope shim in open_browser), so counts/text read
    # the rendered DOM the user actually sees — exactly the remount contract.
    user_count() = TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length")
    agent_count() = TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length")
    visible_text() = String(TK.eval_js(s, """(() => {
        const m = document.querySelector('.bt-messages');
        return m ? (m.innerText || '') : '';
    })()"""))

    pid = TK.new_chat(s; title = "Remountable")

    # ── Build a known history: two full turns ────────────────────────────────
    for (i, p) in enumerate(prompts)
        TK.send_message(s, p)
        @test TK.wait_for(s, "user bubble $i rendered",
            "document.querySelectorAll('.bt-user-msg').length >= $i"; timeout = 30) == true
        @test TK.wait_for(s, "agent bubble $i rendered",
            "document.querySelectorAll('.bt-agent-msg').length >= $i"; timeout = 60) == true
        @test TK.wait_for(s, "agent reply $i text present",
            "(() => { const m=document.querySelector('.bt-messages'); return !!m && (m.innerText||'').includes('reply to: $p'); })()";
            timeout = 60) == true
    end

    # Snapshot the on-screen history that MUST survive the remount.
    n_user_before  = user_count()
    n_agent_before = agent_count()
    @test n_user_before == length(prompts)
    @test n_agent_before == length(prompts)
    for p in prompts
        @test occursin(p, visible_text())
        @test occursin("reply to: $p", visible_text())
    end

    # ── Home → back, twice, asserting the history is intact each round ───────
    for round in 1:2
        TK.to_dashboard(s)
        # On the dashboard no chat is active and the chat pane is hidden.
        @test TK.wait_for(s, "round $round: on dashboard",
            "!document.querySelector('.bt-side-item.bt-side-active') || document.querySelector('.bt-side-item.bt-side-active').getAttribute('data-project-id') !== $(repr(pid))";
            timeout = 10) == true

        TK.open_chat(s, pid)
        @test TK.wait_for(s, "round $round: chat pane visible again", pane_visible; timeout = 15) == true
        # The reopened chat must be the SELECTED pane (so the pane-scope shim
        # reads its DOM, not a stale hidden one).
        @test TK.wait_for(s, "round $round: chat reselected",
            "(() => { const a=document.querySelector('.bt-side-item.bt-side-active'); return !!a && a.getAttribute('data-project-id')===$(repr(pid)); })()";
            timeout = 15) == true

        # History survives the remount: same bubble counts, same texts. Give the
        # JS-side chat its initial range fetch a beat before counting.
        @test TK.wait_for(s, "round $round: user bubbles repainted",
            "document.querySelectorAll('.bt-user-msg').length === $n_user_before"; timeout = 30) == true
        @test TK.wait_for(s, "round $round: agent bubbles repainted",
            "document.querySelectorAll('.bt-agent-msg').length === $n_agent_before"; timeout = 30) == true

        @test user_count() == n_user_before
        @test agent_count() == n_agent_before
        for p in prompts
            @test occursin(p, visible_text())
            @test occursin("reply to: $p", visible_text())
        end

        # Scroll/state sane: the messages container exists and isn't scrolled
        # past its content (no NaN / negative offsets from a botched remount).
        @test TK.eval_js(s, """(() => {
            const m = document.querySelector('.bt-messages');
            if (!m) return false;
            const top = m.scrollTop;
            return Number.isFinite(top) && top >= 0 && top <= m.scrollHeight;
        })()""") == true
    end

    @test isempty(TK.js_errors(s))
end
