# A resumed chat gets only the END of its session's replay over the worker's
# connection. The whole replay used to cross it: 3591 messages with images from
# a laptop (11-27) held up every other request on that connection for over
# ten minutes, and the chat sat "busy" with no session. The worker now receives
# the replay from the agent and sends the server the last N messages; the
# server's reconciler anchors on its newest messages inside that tail. A session
# that went on elsewhere for longer than the tail is loaded whole, once.
#
# Real server + worker + MockACP with a scripted `session/load` replay
# (TK.REPLAY_FN), like `e2e:session_sync`. What crossed the connection is read
# from the chat's wire log (acp.jsonl), the server's own record of every frame.
@testitem "e2e:replay_tail" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    TK = TestKit
    BA = TestKit.BT
    import JSON

    msgs(state, pid) = BA.shared(state.chat_models[pid]).msgs_store
    texts(state, pid) = [String(m.text) for m in msgs(state, pid) if hasproperty(m, :text)]
    turns(r) = reduce(vcat, ([TK.user("q$i"), TK.text("a$i")] for i in r); init = Any[])

    # The replayed messages of each `session/load` (one chunk each here), in the
    # order the loads happened.
    function replays(state, pid)
        log = joinpath(BA.chat_storage_dir(state, pid, state.projects[][pid].server_path), "acp.jsonl")
        counts = Int[]
        loading = nothing
        for l in eachline(log)
            f = JSON.parse(l); m = f["msg"]
            if f["dir"] == "out" && get(m, "method", "") == "session/load"
                loading = m["id"]; push!(counts, 0)
            elseif loading !== nothing && f["dir"] == "in"
                if get(m, "method", "") == "session/update" &&
                   m["params"]["update"]["sessionUpdate"] in ("user_message_chunk", "agent_message_chunk")
                    counts[end] += 1
                elseif get(m, "id", nothing) == loading
                    loading = nothing
                end
            end
        end
        return counts
    end

    server = TK.dev_server(agent = p -> [TK.text("live reply"), TK.end_turn()])
    try
        state = server.h.state
        @test timedwait(() -> !isempty(state.workers[]), 30) === :ok
        wid = first(keys(state.workers[]))

        history = turns(1:150)                        # 300 messages
        TK.REPLAY_FN[] = sid -> history

        # Import: the chat has nothing yet, so it takes the whole replay.
        p = BA.create_project_from_worker!(state, wid, mktempdir();
                name = "tailchat", resume_session_id = "s", start_session = true)
        @test timedwait(() -> haskey(state.chat_models, p.id) && length(msgs(state, p.id)) == 300, 60) === :ok
        @test replays(state, p.id) == [300]

        # The worker scan says the session moved on since we last synced, which
        # makes opening the chat bind it at once (as in `e2e:session_sync`).
        function mark_newer!(dt)
            lock(state.lock) do
                state.discovered[][wid] = [Dict{String,Any}(
                    "session_id" => "s", "path" => p.worker_path, "name" => p.name,
                    "last_used" => time() + dt, "kind" => "session")]
            end
            notify(state.discovered)
        end

        # Continued elsewhere by two messages: only the tail crosses, and the
        # two are adopted after our newest.
        append!(history, turns(151:151))
        BA.stop_session!(state, p)
        mark_newer!(5)
        BA.ensure_project_session!(state, p)
        @test timedwait(() -> length(msgs(state, p.id)) == 302, 60) === :ok
        @test texts(state, p.id)[end-1:end] == ["q151", "a151"]
        @test replays(state, p.id) == [300, 200]
        @test count(==("a150"), texts(state, p.id)) == 1

        # Continued elsewhere by more than the tail: our newest messages are not
        # in it, so the whole replay is loaded once, and nothing is lost.
        append!(history, turns(152:301))              # 300 more
        BA.stop_session!(state, p)
        mark_newer!(10)
        BA.ensure_project_session!(state, p)
        @test timedwait(() -> length(msgs(state, p.id)) == 602, 90) === :ok
        @test replays(state, p.id) == [300, 200, 200, 602]
        t = texts(state, p.id)
        @test t[1:2] == ["q1", "a1"] && t[end-1:end] == ["q301", "a301"]
        @test allunique(t)
    finally
        TK.REPLAY_FN[] = sid -> Any[]
        close(server)
    end
end
