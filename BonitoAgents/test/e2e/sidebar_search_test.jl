# Searching chats from the sidebar (2026-11-16). The box above the chat list
# finds chats by title: the open ones first, then the others, here a chat closed
# with ✕ and a session the worker's scan found that no chat resumes yet. A
# result opens from there, the found session as a chat of its own. What it finds
# is what the server persisted: after a restart it finds the same chats under
# the titles they were given.
#
# Its own server, on a state folder of its own: it is restarted.
@testitem "e2e:sidebar_search" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    dir = mktempdir()
    agent = p -> [TK.text("reply to: $(p)"), TK.end_turn()]
    old_folder = mktempdir()

    VISIBLE_PANE = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    rename(s, title) = TK.eval_js(s, """(() => {
        const inp = $VISIBLE_PANE?.querySelector('.bt-header-title-edit');
        if (!inp) return false;
        Object.getOwnPropertyDescriptor(inp.constructor.prototype, 'value').set.call(inp, $(repr(title)));
        inp.dispatchEvent(new Event('change', {bubbles: true}));
        return true; })()""")
    row(pid) = "[...document.querySelectorAll('.bt-side-chats .bt-side-item')].find(e => e.dataset.projectId === $(repr(pid)))"
    # What the results show, in order: "# section" headings and the titles.
    RESULTS = """[...document.querySelectorAll('.bt-side-results .bt-side-group, .bt-side-results .bt-side-hit, .bt-side-results .bt-side-empty')]
        .map(e => e.classList.contains('bt-side-group') ? '# ' + e.textContent :
                  e.classList.contains('bt-side-hit') ? e.querySelector('.bt-side-name').textContent : e.textContent)"""
    results(s) = TK.eval_js(s, RESULTS)
    shows(expected) = "JSON.stringify($RESULTS) === $(repr(TK.json(expected)))"
    search(s, q) = TK.set_input(s, ".bt-side-search", q)
    click_hit(s, title) = TK.eval_js(s, """(() => {
        const h = [...document.querySelectorAll('.bt-side-results .bt-side-hit')]
            .find(e => e.querySelector('.bt-side-name').textContent === $(repr(title)));
        if (!h) return false; h.click(); return true; })()""")
    CHATS_SHOWN = "document.querySelector('.bt-side-chats').checkVisibility()"

    s = TK.dev_server(; agent, dir)
    ids = Dict{String,String}()     # the chats' ids, across the restart
    try
        TK.open_browser(s)
        alpha = ids["alpha"] = TK.new_chat(s; title = "Alpha")
        TK.send_message(s, "hello alpha")
        @test TK.wait_for(s, "alpha answered", "($VISIBLE_PANE?.textContent || '').includes('reply to: hello alpha')"; timeout = 60) == true
        @test rename(s, "Alpha search target")
        @test TK.wait_for(s, "alpha renamed in the sidebar", "$(row(alpha))?.textContent.includes('Alpha search target')"; timeout = 20) == true
        beta = ids["beta"] = TK.new_chat(s; title = "Beta")
        TK.send_message(s, "hello beta")
        @test TK.wait_for(s, "beta answered", "($VISIBLE_PANE?.textContent || '').includes('reply to: hello beta')"; timeout = 60) == true
        @test rename(s, "Beta search target")
        @test TK.wait_for(s, "beta renamed in the sidebar", "$(row(beta))?.textContent.includes('Beta search target')"; timeout = 20) == true
        TK.eval_js(s, "$(row(beta)).querySelector('.bt-side-close').click(); true")
        @test TK.wait_for(s, "beta closed", "!$(row(beta))"; timeout = 20) == true
        # What a scan of the worker finds: an older session no chat resumes.
        state = s.h.state
        wid = only(keys(state.workers[]))
        state.discovered[][wid] = [Dict{String,Any}("session_id" => "sess-gamma", "path" => old_folder,
            "name" => basename(old_folder), "first_prompt" => "Gamma search target from last week",
            "last_used" => time() - 3 * 86400, "kind" => "session")]
        TK.BT.save_discovered!(state)
    finally
        close(s)
    end

    s = TK.dev_server(; agent, dir)
    alpha, beta = ids["alpha"], ids["beta"]
    try
        TK.open_browser(s)
        @test TK.wait_for(s, "the open chat after the restart", "!!$(row(alpha))"; timeout = 30) == true
        @test TK.wait_for(s, "the worker back", "[...document.querySelectorAll('.bt-side-chats .bt-glow-online')].length > 0"; timeout = 60) == true

        search(s, "search target")
        @test TK.wait_for(s, "open first, then the others, the most recent first",
            shows(["# Open", "Alpha search target", "# Not open", "Beta search target", "Gamma search target from last week"]);
            timeout = 20, describe = RESULTS) == true
        @test TK.eval_js(s, CHATS_SHOWN) == false
        # Escape clears the search and the chat list is back.
        TK.press_key!(s, "Escape")
        @test TK.wait_for(s, "the search cleared", "$CHATS_SHOWN && document.querySelector('.bt-side-search').value === ''"; timeout = 10) == true
        @test isempty(results(s))

        # A closed chat opens from the results, and is open again.
        search(s, "beta")
        @test TK.wait_for(s, "beta found", shows(["# Not open", "Beta search target"]); timeout = 20, describe = RESULTS) == true
        @test click_hit(s, "Beta search target")
        @test TK.wait_for(s, "beta on screen", "$VISIBLE_PANE?.dataset.panePid === $(repr(beta))"; timeout = 60) == true
        @test TK.wait_for(s, "beta back in the sidebar", "!!$(row(beta))"; timeout = 20) == true
        @test TK.eval_js(s, "document.querySelector('.bt-side-search').value") == ""

        # A found session opens as a chat of its own, on its folder.
        search(s, "gamma")
        @test TK.wait_for(s, "the session found", shows(["# Not open", "Gamma search target from last week"]); timeout = 20, describe = RESULTS) == true
        @test click_hit(s, "Gamma search target from last week")
        @test TK.wait_for(s, "a new chat on screen",
            "!!$VISIBLE_PANE && ![$(repr(alpha)), $(repr(beta))].includes($VISIBLE_PANE.dataset.panePid)"; timeout = 60) == true
        gamma = TK.eval_js(s, "$VISIBLE_PANE.dataset.panePid")
        @test TK.wait_for(s, "its folder in the header",
            "($VISIBLE_PANE.querySelector('.bt-header-env')?.getAttribute('title') || '').includes($(repr(basename(old_folder))))"; timeout = 30) == true
        # It resumes the session, so searching finds the chat, not the session.
        search(s, "gamma")
        @test TK.wait_for(s, "found as that chat", "JSON.stringify($RESULTS).includes('# Open') && !JSON.stringify($RESULTS).includes('# Not open')";
            timeout = 20, describe = RESULTS) == true
        @test s.h.state.projects[][gamma].resume_session_id == "sess-gamma"

        search(s, "nothing like this")
        @test TK.wait_for(s, "nothing found", shows(["No chat matches “nothing like this”."]); timeout = 20, describe = RESULTS) == true
        TK.press_key!(s, "Escape")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
