# Session-sync correctness, end to end against the real server + worker +
# MockACP with SCRIPTED session/load replays (TK.REPLAY_FN): the black-box
# regressions for the three real-world failures —
#   (a) a session that advanced OUTSIDE BonitoAgents (Claude Code CLI) syncs on
#       OPEN, without the user having to send anything;
#   (b) a COMPACTED outside-continuation (replay starts with the summary)
#       merges via the suffix anchor: new turns adopted, zero duplicates;
#   (c) typing into a stale chat: the user's message stays the LAST message —
#       the adopted flood splices in ABOVE it ("my message is gone" fix);
#   (d) the count invariant: the store length always matches what the plan
#       produced — nothing lost, nothing doubled.
@testitem "e2e:session_sync" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    TK = TestKit
    BA = TestKit.BT

    function poll(cond; timeout = 30.0)
        t0 = time()
        while time() - t0 < timeout
            cond() && return true
            sleep(0.2)
        end
        return false
    end
    msgs(state, pid) = BA.shared(state.chat_models[pid]).msgs_store
    texts(state, pid) = [replace(String(m.text), r"\s+" => " ")
                         for m in msgs(state, pid) if hasproperty(m, :text)]

    server = TK.dev_server(agent = p -> [TK.text("live reply"), TK.end_turn()])
    try
        state = server.h.state
        @test poll(() -> !isempty(state.workers[]))
        wid = first(keys(state.workers[]))

        # The session's scripted history; grows as "the CLI continued it".
        history = Any[TK.user("hi"), TK.text("hello")]
        TK.REPLAY_FN[] = sid -> history

        # (a) Import the session: eager bind on the EMPTY store replays it.
        p = BA.create_project_from_worker!(state, wid, mktempdir();
                name = "syncchat", resume_session_id = "s", start_session = true)
        @test poll(() -> haskey(state.chat_models, p.id) &&
                         length(msgs(state, p.id)) == 2)
        @test texts(state, p.id) == ["hi", "hello"]

        # Advance the session OUTSIDE (the CLI): two more turns. Stop the
        # bound session, mark the session newer than our sync stamp via the
        # worker-scan sink, and REOPEN — the tail must appear WITHOUT a send.
        push!(history, TK.user("outside question"), TK.text("outside reply"))
        BA.stop_session!(state, p)
        lock(state.lock) do
            state.discovered[][wid] = [Dict{String,Any}(
                "session_id" => "s", "path" => p.worker_path, "name" => p.name,
                "last_used" => time() + 5, "kind" => "session")]
        end
        notify(state.discovered)
        BA.ensure_project_session!(state, p)
        @test poll(() -> length(msgs(state, p.id)) == 4)
        @test texts(state, p.id) == ["hi", "hello", "outside question", "outside reply"]

        # (b) Compaction outside: the replay now STARTS with the summary, then
        # repeats the recent tail, then continues. Suffix anchor ⇒ only the
        # genuinely new turns are adopted; nothing duplicates.
        empty!(history)
        append!(history, Any[
            TK.user(BA.SUMMARY_PREFIX * " Summary of everything so far."),
            TK.user("outside question"), TK.text("outside reply"),
            TK.user("post-compact question"), TK.text("post-compact answer")])
        BA.stop_session!(state, p)
        lock(state.lock) do
            state.discovered[][wid][1]["last_used"] = time() + 10
        end
        notify(state.discovered)
        BA.ensure_project_session!(state, p)
        @test poll(() -> length(msgs(state, p.id)) == 6)
        @test texts(state, p.id)[end-1:end] == ["post-compact question", "post-compact answer"]
        # No duplicates of the overlap:
        @test count(==("outside reply"), texts(state, p.id)) == 1

        # (c) Type into a stale chat: the sync must splice the adopted turns
        # ABOVE the user's fresh message — it stays LAST.
        push!(history, TK.user("even newer"), TK.text("even newer reply"))
        BA.stop_session!(state, p)
        lock(state.lock) do
            state.discovered[][wid][1]["last_used"] = time() + 15
        end
        notify(state.discovered)
        BA.ensure_project_session!(state, p)   # async sync kicks off…
        model = state.chat_models[p.id]
        BA.send_message!(model, BA.UserMsg(model, "typed while stale"))  # …user types NOW
        @test poll(() -> length(msgs(state, p.id)) >= 9)
        # The user's message is the last USER message and sits AFTER the
        # adopted turns; the live mock reply to it lands at the very end.
        @test poll(() -> begin
            t = texts(state, p.id)
            i_user  = findlast(==("typed while stale"), t)
            i_adopt = findlast(==("even newer reply"), t)
            i_user !== nothing && i_adopt !== nothing && i_adopt < i_user
        end)
        @test count(==("typed while stale"), texts(state, p.id)) == 1

        # (d) Count invariant: exactly one copy of everything, no gaps.
        t = texts(state, p.id)
        @test count(==("hi"), t) == 1 && count(==("outside reply"), t) == 1 &&
              count(==("post-compact answer"), t) == 1
    finally
        TK.REPLAY_FN[] = sid -> Any[]
        close(server)
    end
end
