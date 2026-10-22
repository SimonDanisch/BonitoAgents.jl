@testitem "e2e:hidden_chat_cancel" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    s.agent_fn[] = _ -> [TK.text("still working"), TK.delay(60000), TK.end_turn()]
    first = TK.new_chat(s)
    second = nothing
    try
        TK.send_message(s, "first running chat")
        @test TK.wait_for(s, "first turn running", "!!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60)
        second = TK.new_chat(s)
        TK.send_message(s, "second running chat")
        @test TK.wait_for(s, "second turn running", "!!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60)
        TK.press_key!(s, "Escape")
        @test TK.wait_for(s, "visible turn stopped", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 20)
        TK.open_chat(s, first)
        @test TK.wait_for(s, "first chat visible",
            "document.querySelector('.bt-chatpane[aria-hidden=false]')?.dataset.panePid === $(TK.json(first))"; timeout = 20)
        @test TK.eval_js(s, "!!document.querySelector('.bt-busy.bt-busy-active')")
        TK.press_key!(s, "Escape")
        @test TK.wait_for(s, "first turn stopped separately", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 20)
        @test isempty(TK.js_errors(s))
    finally
        for pid in (first, second)
            pid === nothing && continue
            TK.open_chat(s, pid)
            TK.click(s, ".bt-stop-btn")
        end
        s.agent_fn[] = S.default_agent
    end
end
