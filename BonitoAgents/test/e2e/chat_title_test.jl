@testitem "e2e:chat_title" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    server = SharedServer.server()
    server.agent_fn[] = prompt -> [TK.text("reply received"), TK.end_turn()]
    folder = mkpath(joinpath(mktempdir(), "VideoEdit"))
    title(pid) = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"] .bt-header-title-edit')?.value"

    first = TK.new_chat(server; cwd = folder)
    @test TK.wait_for(server, "folder title", "$(title(first)) === 'VideoEdit'") == true
    TK.send_message(server, "Please investigate something with a very different name")
    @test TK.wait_for(server, "reply",
        "[...document.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes('reply received'))") == true
    @test TK.eval_js(server, title(first)) == "VideoEdit"

    second = TK.new_chat(server; cwd = folder)
    @test first != second
    @test TK.wait_for(server, "numbered folder title", "$(title(second)) === 'VideoEdit 2'") == true
    TK.set_input(server, ".bt-header-title-edit", "VideoEdit")
    TK.eval_js(server, "document.querySelector('.bt-chatpane[data-pane-pid=\"$second\"] .bt-header-title-edit').dispatchEvent(new Event('change', {bubbles: true})); true")
    TK.open_chat(server, first)
    TK.open_chat(server, second)
    @test TK.wait_for(server, "explicit duplicate title kept", "$(title(second)) === 'VideoEdit'") == true
    @test TK.wait_for(server, "sidebar respects the edited title",
        "[...document.querySelectorAll('.bt-side-item[data-project-id=\"$second\"] .bt-side-name')].some(e => e.textContent.trim() === 'VideoEdit')") == true
end
