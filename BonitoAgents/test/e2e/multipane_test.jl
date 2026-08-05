# Explicit multi-pane coverage. SharedServer keeps several chat panes MOUNTED at
# once (only the active one visible; the rest are display:none but still in the
# DOM). A UI action driven through a bare selector must hit the ACTIVE pane — not
# a stale hidden one. That's exactly the bug class that bit chat_cancel/chat_attach
# when their selectors were global, and which the auto-scoping TestKit helpers now
# prevent. We reproduce it ON PURPOSE here — create the extra panes ourselves,
# then drive the GLOBAL `.bt-stop-btn` (no manual pane-scoping) and assert it
# stopped the right chat — so the systematic fix has a guard that fails loudly if
# it ever regresses. (Also exercises lazy ACP: three chats open, only the one we
# message binds an agent.)
@testitem "e2e:multipane" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    const CHUNKS = 30
    const DELAY_MS = 400
    function agent_script(prompt)
        if occursin("story", lowercase(prompt))
            evs = Any[]
            for i in 1:CHUNKS
                push!(evs, TK.text("part$(i) "))
                push!(evs, TK.delay(DELAY_MS))
            end
            push!(evs, TK.end_turn())
            return evs
        end
        return [TK.text("echo: $(prompt)"), TK.end_turn()]
    end
    s.agent_fn[] = agent_script

    # Three chats → three panes. The last opened is active/visible; the first two
    # stay mounted but hidden — the stale panes a global selector could leak to.
    TK.new_chat(s; title = "mp-A")
    TK.new_chat(s; title = "mp-B")
    pidC = TK.new_chat(s; title = "mp-C")
    TK.open_chat(s, pidC)

    @testset "several panes mounted, exactly one visible" begin
        npanes = TK.eval_js(s, "document.querySelectorAll('.bt-chatpane').length")
        @test (npanes === nothing ? 0 : Int(npanes)) >= 3
        nvis = TK.eval_js(s, "[...document.querySelectorAll('.bt-chatpane')].filter(p=>p.offsetParent!==null).length")
        @test (nvis === nothing ? 0 : Int(nvis)) == 1
    end

    @testset "global .bt-stop-btn auto-scopes to the active pane" begin
        # Stream in the VISIBLE chat C, land mid-stream, then stop via the bare
        # global selectors — auto-scoping must route them to C. If a stale pane
        # were hit instead, C would never cancel and run to `part30`.
        TK.send_message(s, "tell me a long story")
        VIS = "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent!==null)"
        @test TK.wait_for(s, "C mid-stream",
            "(() => { const b=$(VIS); const busy=document.querySelector('.bt-busy'); " *
            "return b.length>0 && !!busy && busy.classList.contains('bt-busy-active') && " *
            "(b[b.length-1].innerText||'').includes('part2 '); })()"; timeout = 30) == true
        TK.click(s, ".bt-stop-btn")     # UNSCOPED on purpose — relies on auto-scope
        @test TK.wait_for(s, "C stopped early (not a stale pane)",
            "(() => { const b=$(VIS); if(!b.length) return false; const t=b[b.length-1].innerText||''; " *
            "return t.includes('part2 ') && !t.includes('part$(CHUNKS)'); })()"; timeout = 20) == true
    end

    @test isempty(TK.js_errors(s))
end
