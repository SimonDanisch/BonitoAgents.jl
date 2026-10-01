# Unsent text survives a reload. A login that ended, or a server restart, makes
# the page reload; a half-written message went with it (and the login-ended card
# sat over the composer, so it could not even be copied out first).
@testitem "e2e:draft_survives_reload" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    server = SharedServer.server()
    server.agent_fn[] = _ -> [TK.text("got it"), TK.end_turn()]

    pid = TK.new_chat(server; cwd = mktempdir(; prefix = "drafts-"))
    composer = "document.querySelector('.bt-chatpane[data-pane-pid=\"$(pid)\"] .bt-text-input')"
    saved = "localStorage.getItem('bt-draft:$(pid)')"

    TK.set_input(server, ".bt-text-input", "a long thought,\nhalf written")
    @test TK.eval_js(server, saved) == "a long thought,\nhalf written"

    # The page reloads (a fresh tab lands back on this chat) and the text is back.
    @test TK.reload!(server) == :dashboard
    TK.open_chat(server, pid)
    @test TK.wait_for(server, "the draft back in the composer",
        "($(composer) || {}).value === 'a long thought,\\nhalf written'"; timeout = 30) == true

    # Sending it is the end of the draft.
    TK.send_message(server, "sent now")
    @test TK.wait_for(server, "the reply", "document.body.textContent.includes('got it')"; timeout = 60) == true
    @test TK.eval_js(server, saved) === nothing
    @test TK.eval_js(server, "$(composer).value") == ""
    @test isempty(TK.js_errors(server))
end
