@testitem "e2e:session_notice" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    notice = Dict{String,Any}("id"=>"transport-notice", "revision"=>1,
        "severity"=>"warning", "category"=>"unknown", "title"=>"Switching transport <probe>",
        "details"=>repeat("Connection diagnostics. ", 30), "actions"=>[])
    event(record) = Dict("type"=>"session_notice", "record"=>record)
    s.agent_fn[] = _ -> [TK.text("Before notice"), event(notice), TK.delay(4000),
        event(merge(notice, Dict("revision"=>2, "title"=>"Trying transport again"))),
        event(notice), # late revision must not overwrite the newer notice
        TK.delay(4000), TK.text("Warning: ordinary assistant prose"), TK.delay(4000), TK.end_turn()]
    pid = TK.new_chat(s; title="Typed provider notice")
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    q(sel) = "document.querySelector($(repr(P * sel)))"
    visible = "$(q(".bt-session-notice"))?.checkVisibility() === true"
    idle = "$(q(".bt-busy"))?.classList.contains('bt-busy-active') === false"
    says(text) = "$(q(".bt-messages"))?.textContent.includes($(repr(text))) === true"
    TK.send_message(s, "exercise typed notices")
    @test TK.wait_for(s, "typed warning is visible while provider waits",
        "$visible && $(q(".bt-session-notice"))?.textContent.includes('Switching transport <probe>') === true"; timeout=30)
    @test TK.eval_js(s, "$(q(".bt-session-notice")).querySelector('probe') === null") === true
    @test TK.eval_js(s, "$(q(".bt-session-notice")).getBoundingClientRect().height <= 60")
    @test TK.eval_js(s, "!$(q(".bt-session-notice-text")).checkVisibility()")
    TK.eval_js(s, "$(q(".bt-session-notice-title")).click(); true")
    @test TK.eval_js(s, "$(q(".bt-session-notice-text")).checkVisibility()")
    TK.screenshot(s, joinpath(mktempdir(; prefix="bt-notice-"), "details.png"))
    TK.eval_js(s, "$(q(".bt-session-notice-title")).click(); true")
    @test TK.wait_for(s, "updated notice replaces older revision",
        "$(q(".bt-session-notice-title"))?.textContent === 'Trying transport again'"; timeout=30)
    @test TK.wait_for(s, "ordinary warning text remains agent prose",
        says("Warning: ordinary assistant prose"); timeout=30)
    @test TK.wait_for(s, "resumed output clears the warning before the turn ends",
        "!($idle) && !($visible)"; timeout=10)
    @test TK.wait_for(s, "successful turn clears the recovered connection warning",
        "$idle && !($visible)"; timeout=30)
    @test TK.eval_js(s, "[...document.querySelectorAll($(repr(P * ".bt-agent-msg")))].every(e => !e.textContent.includes('Switching transport') && !e.textContent.includes('Trying transport again'))") === true
    TK.reload!(s)
    @test TK.wait_for(s, "recovered warning stays cleared after reload", "$idle && !($visible)"; timeout=30)

    # Dismissing a warning is shared state. A later revision during the same
    # turn and a fresh page must both respect the click.
    pending = merge(notice, Dict("id" => "pending-transport", "title" => "Retrying connection"))
    s.agent_fn[] = _ -> [event(pending), TK.delay(12000),
        event(merge(pending, Dict("revision" => 2, "title" => "Connection retry updated"))),
        TK.delay(4000), TK.text("Retried successfully"), TK.end_turn()]
    TK.send_message(s, "dismiss during retry")
    @test TK.wait_for(s, "new connection incident appears", "$visible"; timeout=30)
    TK.eval_js(s, "$(q(".bt-session-notice button")).click(); true")
    @test TK.wait_for(s, "notice dismissed", "!($visible)"; timeout=10)
    TK.reload!(s)
    @test TK.wait_for(s, "dismissal survives reload", "!!$(q(".bt-text-input")) && !($visible)"; timeout=30)
    @test TK.wait_for(s, "revision arrived without asking for another dismissal",
        "$(q(".bt-session-notice-title"))?.textContent === 'Connection retry updated' && !($visible)"; timeout=30)
    @test TK.wait_for(s, "retry finished", "$idle && $(says("Retried successfully"))"; timeout=30)

    # A cancelled turn is not recovery. Keep the failure until acknowledged or
    # until the agent really succeeds, even after a page reload.
    s.agent_fn[] = _ -> [event(merge(notice, Dict("id" => "stopped-retry"))), TK.delay(30000)]
    TK.send_message(s, "stop during retry")
    @test TK.wait_for(s, "retry warning before Stop", "$visible"; timeout=30)
    TK.eval_js(s, "$(q(".bt-stop-btn")).click(); true")
    @test TK.wait_for(s, "Stop retains the unresolved warning", "$idle && $visible"; timeout=30)

    limit = "Usage limit reached. Try again after your allowance resets."
    s.agent_fn[] = prompt -> prompt == "recovered" ?
        [TK.text("The allowance has reset"), TK.end_turn()] :
        [TK.codex_failure(limit; id = prompt), TK.end_turn()]
    TK.send_message(s, "limit-1")
    @test TK.wait_for(s, "a failed turn retains its limit error",
        "$idle && $visible && $(q(".bt-session-notice"))?.dataset.severity === 'error'"; timeout=30)
    TK.reload!(s)
    @test TK.wait_for(s, "unresolved error remains available after reload", "$visible"; timeout=30)
    TK.eval_js(s, "$(q(".bt-session-notice button")).click(); true")
    @test TK.wait_for(s, "limit dismissed", "!($visible)"; timeout=10)
    TK.send_message(s, "limit-2")
    @test TK.wait_for(s, "identical repeated error needs no second dismissal",
        "$idle && $(says("limit-2")) && $(q(".bt-session-notice"))?.dataset.noticeId === 'limit-2' && !($visible)"; timeout=30)
    TK.send_message(s, "recovered")
    @test TK.wait_for(s, "quota recovery clears the failure",
        "$idle && $(says("The allowance has reset")) && !($visible)"; timeout=30)
    TK.reload!(s)
    @test TK.wait_for(s, "old limit stays gone after reload", "$idle && !($visible)"; timeout=30)
    TK.send_message(s, "limit-3")
    @test TK.wait_for(s, "a new failure after recovery is visible again", "$idle && $visible"; timeout=30)
    TK.emulate_phone(s) do
        @test TK.wait_for(s, "notice stays compact on a phone",
            "(() => { const n = $(q(".bt-session-notice")); const r = n.getBoundingClientRect();
                       return n.checkVisibility() && r.height <= 60 && r.right <= innerWidth &&
                              n.scrollWidth <= n.clientWidth + 1; })()"; timeout=10)
        TK.screenshot(s, joinpath(mktempdir(; prefix="bt-notice-"), "phone.png"))
    end
    TK.to_dashboard(s)
    TK.open_chat(s, pid)
    @test TK.wait_for(s, "active failure survives switching chats", "$visible"; timeout=15)
    @test isempty(TK.js_errors(s))
end
