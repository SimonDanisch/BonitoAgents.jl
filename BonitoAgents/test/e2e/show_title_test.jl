# A bt_show card says what it shows: the agent's `title` when it gave one, else
# the file's name. Beside a title the summary names the file and its size, the
# full path is the title's tooltip, and the title opens the file. Simon asked to
# see the path behind a bt_show, and for the agent to be able to name it. Real
# BonitoMCP handler (`mcp_call`), real dev_server, DOM assertions.
@testitem "e2e:show_title" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    dir = mktempdir()
    png = joinpath(dir, "loss_curve.png"); write(png, UInt8.((0:999) .% 256))
    txt = joinpath(dir, "notes.txt"); write(txt, "one\ntwo\n")
    s.agent_fn[] = _ -> [
        TK.mcp_call("bt_show"; path = png, title = "Loss after 200 epochs", id = "show-cap"),
        TK.mcp_call("bt_show"; path = txt, id = "show-plain"),
        TK.end_turn()]

    pid = TK.new_chat(s)
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"]"
    # [title text, its tooltip, the path it opens, the summary, title shown, status shown]
    head(id) = """(() => { const c = document.querySelector('$(P) .bt-tool-msg[data-msg-id*="$(id)"]');
        const t = c && c.querySelector('.bt-tool-title'), s = c && c.querySelector('.bt-tool-summary');
        const st = c && c.querySelector('.bt-tool-status');
        return t ? [t.textContent, t.title, t.dataset.path || '', s ? s.textContent : '',
                    t.checkVisibility(), !!st && st.checkVisibility()] : null; })()"""

    function check_cards(when)
        @testset "$(when): the agent's title, the file's name beside it, the path on hover" begin
            @test TK.wait_for(s, "the captioned card",
                "($(head("show-cap")) || [])[0] === 'Loss after 200 epochs'"; timeout = 30) == true
            _, tip, path, summary, shown, status_shown = TK.eval_js(s, head("show-cap"))
            @test tip == png && path == png
            @test summary == "loss_curve.png · 1000B"
            # A picture shows bare ("Native Images"), its title a caption above it.
            @test shown == true && status_shown == false
        end
        @testset "$(when): without a title the card is named after the file" begin
            @test TK.wait_for(s, "the plain card",
                "($(head("show-plain")) || [])[0] === 'notes.txt'"; timeout = 30) == true
            _, tip, path, _, shown, status_shown = TK.eval_js(s, head("show-plain"))
            @test tip == txt && path == txt
            @test shown == true && status_shown == true          # a text file keeps its card
        end
    end

    TK.send_message(s, "show the plots")
    @test TK.wait_for(s, "both cards done",
        "[...document.querySelectorAll('$(P) .bt-tool-msg .bt-tool-status')].filter(e => e.textContent === 'completed').length >= 2";
        timeout = 60) == true
    check_cards("live")

    TK.navigate(s, "/")
    TK.open_chat(s, pid)
    check_cards("after a reload")
end
