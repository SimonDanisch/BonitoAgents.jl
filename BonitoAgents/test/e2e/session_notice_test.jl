@testitem "e2e:session_notice" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    notice = Dict{String,Any}("id"=>"transport-notice", "revision"=>1,
        "severity"=>"warning", "category"=>"unknown", "title"=>"Switching transport <probe>",
        "actions"=>[])
    event(record) = Dict("type"=>"session_notice", "record"=>record)
    s.agent_fn[] = _ -> [TK.text("Before notice"), event(notice), TK.delay(4000),
        event(merge(notice, Dict("revision"=>2, "title"=>"Transport recovered"))),
        event(notice), # late revision must not overwrite the newer notice
        TK.text("Warning: ordinary assistant prose"), TK.end_turn()]
    pid = TK.new_chat(s; title="Typed provider notice")
    TK.send_message(s, "exercise typed notices")
    visible = "[...document.querySelectorAll('.bt-session-notice')].find(e => e.offsetParent !== null)"
    @test TK.wait_for(s, "typed warning is visible while provider waits",
        "($visible)?.textContent.includes('Switching transport <probe>') === true"; timeout=30)
    @test TK.eval_js(s, "($visible).querySelector('probe') === null") === true
    @test TK.wait_for(s, "updated notice replaces older revision",
        "($visible)?.textContent.includes('Transport recovered') === true"; timeout=30)
    @test TK.wait_for(s, "ordinary warning text remains agent prose",
        "[...document.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes('Warning: ordinary assistant prose'))";
        timeout=30)
    @test TK.eval_js(s, "[...document.querySelectorAll('.bt-agent-msg')].every(e => !e.textContent.includes('Switching transport') && !e.textContent.includes('Transport recovered'))") === true
    TK.to_dashboard(s)
    TK.open_chat(s, pid)
    @test TK.wait_for(s, "notice survives switching chats",
        "($visible)?.textContent.includes('Transport recovered') === true"; timeout=15)
    TK.eval_js(s, "($visible).querySelector('button').click(); true")
    @test TK.wait_for(s, "notice is dismissible", "!($visible)"; timeout=10)
    @test isempty(TK.js_errors(s))
end
