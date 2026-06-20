# Regression tests for the 2026-06-10 stability review (BonitoAgents findings
# T1–T22). Each @testset pins the Julia-side invariant a fix established so the
# bug can't silently come back. UI-only races (where the only observable is in
# the browser) are asserted at the server-side seam the fix touches.
#
# These are headless: no real worker subprocess, no browser. Where a finding is
# about a worker RPC we drive the `pending_rpcs` table directly; where it's about
# the chat consumer/poller we use a `MockTransport`.

using Test
using JSON
using BonitoAgents
using Bonito
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

stab_newstate() = BT.ServerState(; state_dir   = mktempdir(),
                                   working_dir = mktempdir(),
                                   worker_secret = "x")

# A MockTransport whose responder answers initialize + session/new and finishes
# every prompt cleanly. Enough for a real `start_chat_client!` bring-up (consumer
# + poller) without a worker.
function stab_normal_transport()
    resp(id, result) = JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result))
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg    = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, resp(id, Dict()))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, resp(id, Dict("sessionId" => "s")))
                elseif method == "session/prompt" && id !== nothing
                    put!(incoming, resp(id, Dict("stopReason" => "end_turn")))
                end
            end
        catch e
            e isa InvalidStateException || @warn "stab responder failed" exception=e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

@testset "stability review (T1–T22)" begin

    # ── T1: ensure_project_session! funnels concurrent bring-ups ────────────
    # Two tabs opening the same project must spawn exactly ONE bring-up (one
    # claude-agent-acp). We don't redefine production code; instead we drive the
    # funnel's decision logic directly:
    #   (a) when a bring-up is already in flight, a caller AWAITS it (no second
    #       bring-up) and gets its result;
    #   (b) when the model is already cached, no bring-up runs at all.
    # Both are the exact branches `ensure_project_session!` takes under the lock.
    @testset "T1 SESSION_INFLIGHT funnels concurrent callers to one bring-up" begin
        state = stab_newstate()
        wid = "w1"
        state.workers[][wid] = BT.WorkerInfo(wid, "W1", "ws://x", "x", nothing,
                                             "host", "/home", "", String[], "/root",
                                             :online, BT.Dates.now(BT.Dates.UTC))
        p = BT.ProjectInfo("pid1", "proj", wid, mktempdir(), "/root/proj",
                           BT.Dates.now(BT.Dates.UTC))
        state.projects[][p.id] = p

        # (a) A slow in-flight bring-up task is registered; a concurrent
        # ensure_project_session! must await THAT task, not start a second one.
        ran = Threads.Atomic{Int}(0)
        inflight = @task begin
            Threads.atomic_add!(ran, 1)
            sleep(0.2)
            sentinel = (:model, p.id)
            # Mirror the real owner: clear the funnel entry when done.
            BT.lock(state.lock) do
                get(BT.SESSION_INFLIGHT, p.id, nothing) === current_task() &&
                    delete!(BT.SESSION_INFLIGHT, p.id)
            end
            sentinel
        end
        BT.lock(state.lock) do
            BT.SESSION_INFLIGHT[p.id] = inflight
        end
        schedule(inflight)
        result = BT.ensure_project_session!(state, p)   # must await inflight
        @test result == (:model, p.id)
        @test ran[] == 1                                # only the one bring-up
        @test !haskey(BT.SESSION_INFLIGHT, p.id)        # entry cleared

        # (b) Now the model is cached → no bring-up, returns the cached model.
        cached = BT.ChatModel(state, mktempdir(); transport = stab_normal_transport())
        BT.lock(state.lock) do
            state.chat_models[p.id] = cached
        end
        @test BT.ensure_project_session!(state, p) === cached
        close(cached)
    end

    # ── T2: concurrent save_projects! never corrupts projects.json ──────────
    # Hammer save_projects! from many tasks while a writer mutates the dict; the
    # file must always parse (unique tmp + lock-snapshot).
    @testset "T2 concurrent save_projects! keeps projects.json parseable" begin
        state = stab_newstate()
        for i in 1:20
            id = "p$i"
            state.projects[][id] = BT.ProjectInfo(id, "proj$i", "w", "/s/$i",
                "/w/$i", BT.Dates.now(BT.Dates.UTC))
        end
        path = BT.projects_file(state)
        tasks = Task[]
        for _ in 1:40
            push!(tasks, @async BT.save_projects!(state))
        end
        # A concurrent mutator churning the dict under the lock.
        push!(tasks, @async begin
            for k in 1:50
                BT.lock(state.lock) do
                    id = "x$k"
                    state.projects[][id] = BT.ProjectInfo(id, "x", "w", "/s", "/w",
                        BT.Dates.now(BT.Dates.UTC))
                end
                yield()
            end
        end)
        foreach(fetch, tasks)
        # The on-disk file must be valid JSON every time we wrote it; assert the
        # final state parses and no stray temp files leaked alongside it.
        @test JSON.parsefile(path) isa AbstractVector
        leftovers = filter(f -> startswith(f, "jl_") || endswith(f, ".tmp"),
                           readdir(dirname(path)))
        @test isempty(leftovers)
    end

    # ── T3: handle_handoff_ws takes the channel under the lock ──────────────
    # We can't open a real WS here, but the invariant is: a handoff for a
    # already-claimed/expired id must NOT KeyError, and a delivered handoff pops
    # the entry exactly once. Drive deliver/take against pending_rpcs directly to
    # pin the take-if-present semantics the handler now shares.
    @testset "T3 pending-RPC take-if-present is atomic (no KeyError)" begin
        state = stab_newstate()
        rid, ch = BT.register_rpc!(state)
        # First taker wins; second finds it gone (mirrors handoff vs timeout).
        first = BT.lock(state.lock) do
            haskey(state.pending_rpcs, rid) ? pop!(state.pending_rpcs, rid) : nothing
        end
        second = BT.lock(state.lock) do
            haskey(state.pending_rpcs, rid) ? pop!(state.pending_rpcs, rid) : nothing
        end
        @test first === ch
        @test second === nothing       # no KeyError, just "already taken"
    end

    # ── T4: closing a ChatModel stops the consumer + poller ─────────────────
    @testset "T4 close(::ChatModel) ends consumer + background poller" begin
        state = stab_newstate()
        model = BT.ChatModel(state, mktempdir(); transport = stab_normal_transport())
        BT.start_chat_client!(model)
        consumer = model.consumer_task[]
        @test consumer isa Task
        @test BT.lock(() -> haskey(BT.BG_POLLERS, model), BT.BG_POLLERS_GC_LOCK)
        poller = BT.lock(() -> BT.BG_POLLERS[model], BT.BG_POLLERS_GC_LOCK)
        @test !istaskdone(poller)
        @test isopen(model.user_messages)

        close(model)
        @test !isopen(model.user_messages)
        # Consumer ends when the channel closes; poller exits on its next loop
        # guard (within one 1 s tick).
        @test timedwait(() -> istaskdone(consumer), 5.0) === :ok
        @test timedwait(() -> istaskdone(poller),   5.0) === :ok
        # And the registry self-cleans (no leaked strong ref to the model).
        @test timedwait(
            () -> !BT.lock(() -> haskey(BT.BG_POLLERS, model), BT.BG_POLLERS_GC_LOCK),
            5.0) === :ok
        close(model)   # idempotent
    end

    # ── T6: safe_notify! survives a throwing (stale) listener ───────────────
    # A stale-session listener that throws must NOT starve later listeners, and
    # the dead one is deregistered. A real (non-stale) error rethrows.
    @testset "T6 safe_notify! isolates + drops a stale listener" begin
        obs = Observable(0)
        reached = Ref(false)
        # First listener simulates a dead browser tab (JS-exception class).
        on(_ -> throw(Base.IOError("stale tab", 0)), obs)
        # Second must still fire despite the first throwing.
        on(_ -> (reached[] = true), obs)
        n0 = length(obs.listeners)
        BT.safe_notify!(obs)
        @test reached[]                        # later listener not starved
        @test length(obs.listeners) == n0 - 1  # dead listener deregistered

        # A genuine bug in a listener must propagate, not be swallowed.
        obs2 = Observable(0)
        on(_ -> error("real bug"), obs2)
        @test_throws ErrorException BT.safe_notify!(obs2)
    end

    # ── T7: sync_project_to_server! atomic test-and-set guard ───────────────
    # A project already :syncing must make the second caller error cleanly
    # (atomic transition under the lock).
    @testset "T7 double sync is rejected atomically" begin
        state = stab_newstate()
        p = BT.ProjectInfo("ps", "proj", "w", mktempdir(), "/w/proj",
                           BT.Dates.now(BT.Dates.UTC))
        state.projects[][p.id] = p
        p.backup_status = :syncing
        # Worker is "connected" so we get past that check and hit the guard.
        state.worker_control_ws["w"] = :fake
        state.workers[]["w"] = BT.WorkerInfo("w", "W", "ws://x", "x", nothing,
            "h", "/home", "", String[], "/root", :online, BT.Dates.now(BT.Dates.UTC))
        @test_throws ErrorException BT.sync_project_to_server!(state, p)
    end

    # ── T8: tool_content_cache reads/writes are lock-guarded ────────────────
    # Hammer cache_tool_content! + tool_content_for_render from many tasks; with
    # the model.lock guard there must be no data-race crash and the final read
    # returns a stored value.
    @testset "T8 tool_content_cache concurrent access is safe" begin
        state = stab_newstate()
        model = BT.ChatModel(state, mktempdir(); transport = stab_normal_transport())
        tasks = Task[]
        for i in 1:100
            push!(tasks, @async BT.cache_tool_content!(model, "tool$(i % 7)",
                Any["content-$i"]))
        end
        foreach(fetch, tasks)
        # Reads under the lock return one of the stored values, never crash.
        BT.lock(model.lock) do
            @test haskey(model.tool_content_cache, "tool0")
        end
        close(model)
    end

    # ── T10: a pending RPC is not leaked when the send fails ────────────────
    # send_command throws (worker not connected); the wrapper's finally must
    # unregister the pending entry.
    @testset "T10 failed RPC send leaves no pending entry" begin
        state = stab_newstate()
        @test_throws ErrorException BT.list_worker_dir(state, "ghost", "/tmp")
        @test isempty(state.pending_rpcs)     # no leak
    end

    # ── T15: take_pending! doesn't strand a sleeping task on a fast reply ────
    # A reply that lands immediately must let the timer be closed, not leave a
    # task sleeping for the full (here large) timeout.
    @testset "T15 take_pending! reaps its timer on a fast reply" begin
        state = stab_newstate()
        rid, ch = BT.register_rpc!(state)
        @async (sleep(0.05); BT.deliver_rpc_response!(state, rid, "ok"))
        t0 = time()
        val = BT.take_pending!(state, ch, rid, 60.0, "fast op")
        @test val == "ok"
        @test time() - t0 < 5.0               # returned fast, didn't wait 60s
        @test isempty(state.pending_rpcs)
    end

    # ── T13: chat.md header rewrite is atomic + serialized with appends ──────
    # update_session_id! must preserve concurrently-appended bodies and never
    # truncate the file.
    @testset "T13 update_session_id! keeps concurrent appends" begin
        dir = mktempdir()
        session = BT.load_session(dir, dir)
        # Append several user messages while rewriting the header concurrently.
        appenders = [@async BT.append_user(session, BT.UserMsg("msg $i"))
                     for i in 1:20]
        rewriters = [@async BT.update_session_id!(session, "sid-$i") for i in 1:10]
        foreach(fetch, vcat(appenders, rewriters))
        content = read(BT.session_file(dir), String)
        # Header intact (front matter present) AND every append survived.
        @test occursin("+++", content)
        for i in 1:20
            @test occursin("msg $i", content)
        end
        # File reloads cleanly into the expected number of user messages.
        msgs = BT.load_history(session)
        @test count(m -> m isa BT.UserMsg, msgs) == 20
    end

    # ── T16: do_import / open-on-worker busy guard collapses double-clicks ───
    # The busy state machine: once busy, is_busy_idle is false, so a second
    # synchronous attempt bails. Pin that semantics (the fix moved busy_start!
    # synchronous + added the guard).
    @testset "T16 busy guard rejects a second concurrent long-op" begin
        busy = Observable(BT.BUSY_IDLE)
        @test BT.is_busy_idle(busy[])
        BT.busy_start!(busy, "Working")
        @test !BT.is_busy_idle(busy[])     # second click would bail here
        BT.busy_clear!(busy)
        @test BT.is_busy_idle(busy[])
    end

    # T19 (popup geometry load/save) was removed: the popup/floating-window
    # subsystem (popup.jl, floating_window.jl, load_popup_state/save_popup_state)
    # was moved out of BonitoAgents into the BonitoWidgets Workspace in the
    # monorepo refactor. The geometry is now the Workspace's concern.

end
