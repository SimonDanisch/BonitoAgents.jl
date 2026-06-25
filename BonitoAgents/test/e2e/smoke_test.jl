# Black-box e2e smoke testitem — proves the whole harness end to end:
#   • the shared per-worker dev_server + electron window starts (SharedServer),
#   • a chat round-trips a prompt through the real server/worker/mock-agent,
#   • we assert ONLY on rendered DOM (no server-state introspection),
#   • no JS errors leaked.
# The deep `e2e:media` item (bt_show image+video → /assets/<key> src → 206 range
# stream → lightbox) builds on exactly this pattern once the harness is green.
@testitem "e2e:smoke" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    s.agent_fn[] = prompt -> [TK.text("pong: $(prompt)"), TK.end_turn()]
    pid = TK.new_chat(s)
    TK.send_message(s, "ping")

    @test TK.wait_for(s, "agent reply rendered",
        "(document.body.innerText || '').includes('pong: ping')"; timeout = 60)
    @test isempty(TK.js_errors(s))
end
