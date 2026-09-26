# A dropped worker connection costs a chat nothing, even with data in flight.
#
# The worker link's promise: a connection that drops only DETACHES the link. The
# worker keeps running its agents, queues what they send, reconnects, and the
# link resumes where it stopped, replaying whatever the other side had not seen.
# `e2e:worker_zombie` covers an idle chat through a wedge; this covers the two
# streams that are live WHILE the connection is gone:
#
#   * an agent reply, streamed chunk by chunk — every chunk must arrive, once,
#     in order, from the same agent process;
#   * an eval's live stdout, which travels the MCP's relay channel (a channel on
#     the same link) — it must keep streaming into the card after the reconnect,
#     not only show up in the final result.
#
# Own dev server (the drop is ours to inject), through SharedServer's TestKit so
# the shared stack is released first.
@testitem "e2e:worker_resume" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    import BonitoAgents as BT

    CHUNKS = 100
    EVALENV = abspath(joinpath(@__DIR__, "..", "evalenv"))
    # 150 lines at 0.1 s: long enough that the eval is still running well after
    # the worker's 5 s reconnect.
    COUNT = "for i in 1:150; println(\"line \", i); sleep(0.1); end; :counted"

    function agent(prompt)
        if occursin("stream", prompt)
            # ~8 s of reply: it spans the drop and the reconnect.
            events = Any[]
            for i in 1:CHUNKS
                push!(events, TK.text("r$i "), TK.delay(80))
            end
            return push!(events, TK.end_turn())
        elseif occursin("count", prompt)
            return Any[TK.bt_eval(COUNT; env_path = EVALENV, id = "cnt", timeout = 120), TK.end_turn()]
        end
        return Any[TK.text("echo: $(prompt)"), TK.end_turn()]
    end

    s = TK.dev_server(; agent)
    wpid = getpid(s.h.worker_proc)
    agent_pids() = readlines(ignorestatus(pipeline(`pgrep -P $wpid -f MockACP`)))
    online(wid) = s.h.state.workers[][wid].online[]
    newest_reply = """(() => {
        const b = [...document.querySelectorAll('.bt-agent-msg')].filter(e => e.offsetParent);
        return b.length ? b[b.length - 1].innerText.trim() : '';
    })()"""
    card = ".bt-tool-msg[data-msg-id*=\\\"cnt\\\"]"
    # The result section only: the Code section shows `:counted` from the start.
    result_text = "((document.querySelector(\"$card .bt-eval-result\") || {}).innerText || '')"
    # The highest `line N` the eval card shows so far.
    max_line = """(() => {
        const o = document.querySelector("$card .bt-eval-output");
        const t = o ? o.innerText : '';
        return Math.max(0, ...[...t.matchAll(/line (\\d+)/g)].map(m => +m[1]));
    })()"""
    try
        TK.open_browser(s)
        TK.new_chat(s; title = "Resume")
        TK.send_message(s, "hello")
        @test TK.wait_for(s, "first reply", "$(newest_reply) === 'echo: hello'"; timeout = 90) == true
        # The chat's agent, once the worker's short-lived session-scan agents are gone.
        @test timedwait(() -> length(agent_pids()) == 1, 60.0; pollint = 0.5) == :ok
        agents_before = agent_pids()
        wid = only(collect(keys(s.h.state.worker_links)))

        @testset "a reply streaming across the drop arrives whole, in order" begin
            TK.send_message(s, "stream")
            @test TK.wait_for(s, "stream under way", "$(newest_reply).includes('r10')"; timeout = 60) == true
            link = TK.drop_worker_connection!(s)
            @test timedwait(() -> !online(wid), 10.0; pollint = 0.05) == :ok
            @test timedwait(() -> online(wid), 60.0; pollint = 0.2) == :ok
            @test s.h.state.worker_links[wid] === link          # resumed, not replaced
            expected = join(("r$i" for i in 1:CHUNKS), ' ')
            @test TK.wait_for(s, "every chunk, once, in order",
                "$(newest_reply) === $(TK.json(expected))"; timeout = 60) == true
            @test agent_pids() == agents_before                 # the SAME agent process
        end

        @testset "an eval's live output keeps streaming after the drop" begin
            TK.send_message(s, "count")
            @test TK.wait_for(s, "eval streaming", "$(max_line) >= 10"; timeout = 180) == true
            TK.drop_worker_connection!(s)
            at_drop = TK.eval_js(s, max_line)
            @test timedwait(() -> !online(wid), 10.0; pollint = 0.05) == :ok
            @test timedwait(() -> online(wid), 60.0; pollint = 0.2) == :ok
            # Live, not the final result: well past the drop while still running.
            # A stream lost with the connection would only jump at completion,
            # together with the result.
            @test TK.wait_for(s, "live output after the reconnect",
                "$(max_line) >= $(at_drop + 40) && !$(result_text).includes(':counted')"; timeout = 30) == true
            @test TK.wait_for(s, "eval completed", "$(result_text).includes(':counted')"; timeout = 60) == true
            @test TK.eval_js(s, max_line) == 150
        end

        @testset "the chat carries on with the same agent" begin
            TK.send_message(s, "after")
            @test TK.wait_for(s, "reply after the drops", "$(newest_reply) === 'echo: after'"; timeout = 60) == true
            @test agent_pids() == agents_before
            @test isempty(TK.js_errors(s))
        end
    finally
        close(s)
    end
end
