# The worker's cut of a resumed session's replay (BonitoWorker replay_tail.jl):
# the server asks for the last N messages, the worker holds the replay back as it
# arrives from the agent and sends only that tail, then the load's answer. What is
# not part of a message (modes, usage, titles) always goes on; so does everything
# that isn't this load's replay.
@testitem "unit:replay_tail" tags = [:unit] begin
    import BonitoWorker as BW
    import JSON

    # What the worker would put on the server's channel.
    struct Sent
        lines::Vector{String}
    end
    BW.WebSockets.send(s::Sent, line::AbstractString) = (push!(s.lines, String(line)); nothing)

    upd(u) = JSON.json(Dict("jsonrpc" => "2.0", "method" => "session/update",
                            "params" => Dict("sessionId" => "s1", "update" => u)))
    chunk(kind, t) = upd(Dict("sessionUpdate" => kind, "content" => Dict("type" => "text", "text" => t)))
    user(t)  = chunk("user_message_chunk", t)
    agent(t) = chunk("agent_message_chunk", t)
    tool(id) = upd(Dict("sessionUpdate" => "tool_call", "toolCallId" => id, "status" => "pending", "title" => id))
    done(id) = upd(Dict("sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => "completed"))
    child(id, parent) = upd(Dict("sessionUpdate" => "tool_call", "toolCallId" => id, "status" => "pending",
                                 "_meta" => Dict("claudeCode" => Dict("parentToolUseId" => parent))))
    usage(n) = upd(Dict("sessionUpdate" => "usage_update", "used" => n, "size" => 1000))
    load(id; tail = nothing) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "method" => "session/load",
        "params" => Dict{String,Any}("sessionId" => "s1", "cwd" => "/p", "mcpServers" => Any[],
                                     "_meta" => tail === nothing ? Dict{String,Any}() :
                                                Dict{String,Any}("bonito/replayTail" => tail))))
    answer(id) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict()))

    function run(lines; tail)
        cut = BW.ReplayCut(); sent = Sent(String[])
        BW.note_replay_load!(cut, load(7; tail))
        foreach(l -> BW.forward_agent_line!(cut, sent, l), lines)
        return sent.lines, cut
    end

    replay = [user("q1"), agent("a1 "), agent("still a1"),        # 1, 2
              tool("t1"), done("t1"), child("c1", "t1"),          # 3 (with its update and its subagent's call)
              usage(10),                                          # not a message
              agent("a2"), tool("t2"), user("q3")]                # 4, 5, 6 (t2 never finishes)

    @testset "the last N messages, the metadata, then the answer" begin
        out, cut = run([replay; answer(7)]; tail = 2)
        @test out == [usage(10), tool("t2"), user("q3"), answer(7)]
        @test isempty(cut.frames)
        out, _ = run([replay; answer(7)]; tail = 4)
        # A tool call keeps its updates and its subagent's frames with it.
        @test out == [tool("t1"), done("t1"), child("c1", "t1"), usage(10), agent("a2"), tool("t2"), user("q3"), answer(7)]
        # A run of chunks is one message: asking for 5 brings both halves of a1.
        out, _ = run([replay; answer(7)]; tail = 5)
        @test out[1:2] == [agent("a1 "), agent("still a1")]
    end

    @testset "everything else goes on at once" begin
        other = JSON.json(Dict("jsonrpc" => "2.0", "method" => "_auth/status_update", "params" => Dict()))
        not_json = "not json at all\n"
        out, _ = run([user("q1"), other, not_json, agent("a1"), answer(7)]; tail = 1)
        @test out == [other, not_json, agent("a1"), answer(7)]
        # A load that asks for no tail is not held back at all.
        out, _ = run([user("q1"), agent("a1")]; tail = nothing)
        @test out == [user("q1"), agent("a1")]
        # After the answer, the session talks as usual.
        cut = BW.ReplayCut(); sent = Sent(String[])
        BW.note_replay_load!(cut, load(7; tail = 1))
        foreach(l -> BW.forward_agent_line!(cut, sent, l), [user("q1"), agent("a1"), answer(7), agent("live")])
        @test sent.lines == [agent("a1"), answer(7), agent("live")]
    end

    @testset "a long replay is held in bounded memory" begin
        cut = BW.ReplayCut(); sent = Sent(String[])
        BW.note_replay_load!(cut, load(9; tail = 3))
        held = 0
        for i in 1:20_000
            BW.forward_agent_line!(cut, sent, isodd(i) ? user("q$i") : agent("a$i"))
            held = max(held, length(cut.frames))
        end
        @test held < 3000
        @test isempty(sent.lines)
        BW.forward_agent_line!(cut, sent, answer(9))
        @test sent.lines == [agent("a19998"), user("q19999"), agent("a20000"), answer(9)]
    end
end
