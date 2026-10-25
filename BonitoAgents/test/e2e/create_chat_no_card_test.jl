# Creating a chat is opening one: the chat's own loading spinner is the only
# thing on screen, as for a chat that already existed. It used to run through
# the window's progress card, "Importing X" and then "Imported X" for 4.5 s on
# top of the new chat's header controls.
@testitem "e2e:create_chat_no_card" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # Every state the window's progress card takes from here on.
    TK.eval_js(s, """(() => {
        const now = () => document.querySelector('.bt-prog')?.className || '';
        let last = now();
        window.__progChanges = [];
        new MutationObserver(() => {
            const c = now();
            if (c !== last) { last = c; window.__progChanges.push(c); }
        }).observe(document.body, {subtree: true, childList: true, attributes: true, attributeFilter: ['class']});
        return true; })()""")
    pid = TK.new_chat(s; title = "NoCard")
    @test TK.current_chat_id(s) == pid
    sleep(1)
    changes = TK.eval_js(s, "window.__progChanges")
    @test !any(c -> occursin("bt-prog-run", c) || occursin("bt-prog-ok", c), changes)
    @test isempty(TK.js_errors(s))
end
