# Restart-lifecycle contract driven against a REAL local subprocess + ACP
# JSON-RPC handshake — the `BinAgent` local path (`MockAgent`, which spawns the
# SAME mock_claude_agent_acp.jl binary). Only the agent BEHAVIOUR is faked
# (selected by `BT_MOCK_ACP_SCENARIO`); the subprocess spawn, stdin/stdout
# pipes, reader-loop EOF cascade, `kill`, and blocking-IO flush are all real.
#
# Why a SECOND restart suite next to `test_restart.jl`: `test_restart.jl` covers
# the user-visible contract (in-flight bubble finalize, trailing thinking=false,
# tool→failed, session_reset→msgs.count ordering, busy cleared) against the same
# real MockAgent. THIS file keeps the scenarios `test_restart.jl` does NOT carry —
# the hang/crash/todo/background ones that exercise the OS-level teardown plumbing
# (a wedged subprocess that must be `kill`ed, a real EOFError flipping
# session_alive=false, the live-TodoListMsg orphan sweep, a live background
# BashToolMsg preserved across restart) — PLUS the two stress invariants:
#   • a 30-iteration prompt/restart/cancel mix, and
#   • two concurrent `restart_chat_session!` calls converging.
#
# MIGRATION (first-class-agent model): the deleted
# `BT.LocalTransport(cwd; agent_bin=MOCK_BIN, agent_env=…)` is replaced by
# `BT.MockAgent(; cwd)` (spawns the SAME mock binary). The scenario / chunk
# pacing rides `agent.env` (`BT_MOCK_ACP_SCENARIO` / `BT_MOCK_ACP_CHUNK_MS` /
# `BT_MOCK_ACP_CHUNKS`), set BEFORE `start_chat_client!`. `ChatModel(state, dir;
# agent = MockAgent(...))`; `model.client[]` → `client(model.agent)` /
# `isopen(model.agent)`; cancel via
# `BT.handle_command!(model, nothing, BT.CancelCommand())`.
#
# THE OLD CLOBBER IS GONE BY CONSTRUCTION: the deleted `LocalTransport` REUSED a
# single shared `inner[]` Ref across restarts, so a fresh `start_session` could
# overwrite (clobber) a sibling reader-loop's subprocess and trip an "ACP
# connection closed" from the bring-up `initialize` (plus, pre-`transport_eof`, a
# 100% CPU reader spin). With the agent model EACH agent owns its OWN subprocess
# (`start!(::BinAgent)` builds a fresh `SubprocessTransport`/`Connection`), so the
# clobber CANNOT occur — the old `6b. rapid re-bring-up` test is therefore dropped
# (its positive invariant now lives in `test_transport_eof.jl`'s
# "no clobber by construction" testset). The two-concurrent-restarts test (which
# used to be flaky/hang-prone BECAUSE of that clobber) is now CLEAN.
#
# ONE KNOWN TEARDOWN LIMITATION the stress test works around (NOT a clobber, and
# NOT this test's to fix — it lives in `close(::ACP.SubprocessTransport)`):
# `close` reaps the child with `kill` = SIGTERM, but a Julia child parked in
# `sleep`/mid-JIT (exactly the hang scenarios) does NOT reliably die on SIGTERM —
# only SIGKILL reaps it (verified in isolation). An un-reaped child keeps stdout
# open, so the parent's reader loop stays parked and that turn's `turns_active`
# never decrements (a later watchdog then reads "still busy"). The CHAT-STATE
# contract is unaffected (restart force-clears busy + sweeps orphans); only the
# OS reap lags. The stress + per-scenario testsets therefore `reap_stragglers!()`
# (SIGKILL) in their drain/`finally` — making teardown the robust SIGKILL
# escalation `close` ought to do — so the suite leaves NO leaked subprocess.

using Test
using BonitoAgents
using Bonito: on
using Random
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir   = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

# Count live mock subprocesses (pgrep exits 1 ⇒ none → 0).
mock_proc_count() =
    try parse(Int, strip(read(`pgrep -fc mock_claude_agent_acp.jl`, String))) catch; 0 end

# Force-reap any straggler mock subprocess and wait for the count to return to
# `base`. SIGKILL, because the teardown SIGTERM does NOT reliably reap a HUNG
# Julia child — see the KNOWN TEARDOWN LIMITATION note at the top of the
# stress/final testsets. Each SIGKILL closes the child's stdout, which EOFs the
# parent's parked reader loop, lets the turn's `drain_turn!` finally run, and so
# settles `turns_active`/`busy_active` too.
function reap_stragglers!(base::Int = 0; timeout = 6.0)
    mock_proc_count() <= base && return :ok
    try run(pipeline(`pkill -9 -f mock_claude_agent_acp.jl`; stderr = devnull, stdout = devnull)) catch; end
    return timedwait(() -> mock_proc_count() <= base, timeout)
end

# A live local chat backed by a real `MockAgent` running `scenario`. The mock
# subprocess + ACP handshake are real; `start_chat_client!` brings it up. The
# scenario / chunk-pacing env is set on the agent BEFORE bring-up (the mock reads
# it once at process start). `chunk_ms` paces the streaming side so a test can
# land its restart inside a known mid-stream window; `n_chunks` sizes the stream.
# The stderr redirect swallows the mock's SIGTERM backtrace dump on kill (the hang
# scenarios block on `sleep`, so teardown kills them).
function mock_chat(scenario::AbstractString; chunk_ms::Int = 0, n_chunks::Int = 3)
    st = newstate()
    ag = BT.MockAgent(; cwd = mktempdir())
    ag.env["BT_MOCK_ACP_SCENARIO"] = scenario
    ag.env["BT_MOCK_ACP_CHUNK_MS"] = string(chunk_ms)
    ag.env["BT_MOCK_ACP_CHUNKS"]   = string(n_chunks)
    m  = BT.ChatModel(st, ag.cwd; agent = ag)
    redirect_stderr(devnull) do
        BT.start_chat_client!(m)
    end
    return m
end

# Flip the agent's scenario for the NEXT bring-up, then restart. `redirect_stderr`
# silences the killed-mock backtrace from the old (hung) subprocess.
function restart_with_scenario!(model, scenario::AbstractString)
    model.agent.env["BT_MOCK_ACP_SCENARIO"] = scenario
    redirect_stderr(devnull) do
        BT.restart_chat_session!(model)
    end
    return nothing
end

# Restart keeping the CURRENT scenario (still silences the killed-mock backtrace).
function restart!(model)
    redirect_stderr(devnull) do
        BT.restart_chat_session!(model)
    end
    return nothing
end

# Collect every comm event a model emits into a Vector for assertion. The on()
# callback runs on the same task that wrote comm, so the events vector reflects
# wire order.
function capture_comm(model)
    events = Dict{String,Any}[]
    on(d -> push!(events, copy(d)), model.comm)
    return events
end

@testset "restart_chat_session! against a real MockAgent subprocess" begin

    base_procs = mock_proc_count()

    # ── 1. Restart mid agent stream (subprocess gets killed) ────────────
    # The real subprocess is hung in `hang_after_chunks` (it streamed N chunks
    # then sits in `sleep` forever). Restart must `kill` it, close its stdin,
    # watch the reader-loop EOF, and finalize the half-streamed bubble — all the
    # OS-level teardown plumbing the in-memory fake could never reproduce.
    @testset "restart mid agent stream finalizes the bubble" begin
        model = mock_chat("hang_after_chunks"; chunk_ms = 10)
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("go"))

            @test timedwait(() -> model.busy_active[], 5.0) === :ok
            @test timedwait(() ->
                any(m -> m isa BT.AgentMsg && !isempty(m.text), model.msgs_store),
                5.0) === :ok
            am = first(m for m in model.msgs_store if m isa BT.AgentMsg)
            @test am.in_flight == true   # mid-stream

            restart_with_scenario!(model, "normal")

            @test am.in_flight == false              # orphan sweep finalized it
            @test model.busy_active[] == false
            @test model.session_alive[] == true
            finals = [e for e in events
                      if get(e, "type", "") == "agent_final" && get(e, "id", "") == am.id]
            @test length(finals) >= 1
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 2. Restart mid thought → thinking=false is the LAST thinking event ─
    @testset "restart mid thought emits the trailing thinking=false" begin
        model = mock_chat("hang_in_thought")
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("think"))

            @test timedwait(() ->
                any(e -> get(e, "type", "") == "thinking" && get(e, "active", false), events),
                5.0) === :ok

            restart_with_scenario!(model, "normal")

            thinking_events = [e for e in events if get(e, "type", "") == "thinking"]
            @test !isempty(thinking_events)
            @test last(thinking_events)["active"] == false
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 3. Restart with a pending ToolMsg → status flipped to failed ────
    @testset "restart with pending tool: status forced to failed" begin
        model = mock_chat("hang_in_tool")
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("tool"))

            @test timedwait(() ->
                any(m -> m isa BT.ToolMsg, model.msgs_store),
                5.0) === :ok
            tool = first(m for m in model.msgs_store if m isa BT.ToolMsg)
            @test !(tool.status in ("completed", "failed"))

            restart_with_scenario!(model, "normal")

            @test tool.status == "failed"
            @test tool.finished_at !== nothing
            @test model.busy_active[] == false
            @test model.session_alive[] == true
            tu = [e for e in events if get(e, "type", "") == "tool_update"
                                    && get(e, "status", "") == "failed"]
            @test !isempty(tu)
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 4. Crashed agent → recover via restart ──────────────────────────
    # `crash` exits(1) right after `session/prompt` (no response, no chunks). The
    # real subprocess exit produces a real `EOFError` in the reader loop; the
    # turn's catch flips `session_alive=false`; restart spawns a fresh subprocess
    # and recovers. (An in-memory fake `Channel.close` yields an
    # `InvalidStateException`, NOT the `EOFError` the reader-loop classifies as
    # session-dead — so this path is only reachable over a real subprocess.)
    @testset "crashed agent: session_alive=false, then restart recovers" begin
        model = mock_chat("crash")
        try
            BT.send_message!(model, BT.UserMsg("die"))

            @test timedwait(() -> model.session_alive[] == false, 5.0) === :ok
            @test !isempty(model.last_error[])

            restart_with_scenario!(model, "normal")
            @test model.session_alive[] == true
            @test isempty(model.last_error[])
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 5. Stress: restarts interleaved with prompts + cancels ──────────
    # The randomized-timing test. Each iteration either sends a prompt, fires a
    # restart, or sends a cancel. After the loop, sweep the model and assert NO
    # orphaned in_flight bubbles, NO stuck busy, NO unmatched thinking-on. This is
    # the closest thing in the suite to "production load" — it catches races in
    # `restart_chat_session!`'s bounded wait, the orphan-sweep ordering, and the
    # thinking-pair emit. The old shared-inner clobber that made this flaky is
    # gone (each agent owns its own subprocess), so the CHAT-STATE invariants are
    # clean.
    #
    # KNOWN TEARDOWN LIMITATION (out of this test's scope to fix — it's in
    # `close(::ACP.SubprocessTransport)`): restarting WHILE a hung-mock turn is in
    # flight relies on the transport `kill`ing the child, but `kill` sends
    # SIGTERM, and a Julia child parked in `sleep`/mid-JIT does NOT reliably reap
    # on SIGTERM (only SIGKILL does — verified). An un-reaped child keeps its
    # stdout open, so the parent's reader loop stays parked and that turn's
    # `drain_turn!` never decrements `turns_active` — which a later `update_busy!`
    # watchdog reads as "still busy". So before asserting the drained invariants
    # we `reap_stragglers!()` (SIGKILL) — i.e. we make the teardown the robust
    # SIGKILL escalation that `close` SHOULD do. Once reaped, every parked reader
    # EOFs, `turns_active` settles to 0, and `busy_active` clears for real.
    @testset "stress: prompt/restart/cancel mixed over 30 iterations" begin
        model = mock_chat("hang_after_chunks"; chunk_ms = 2)
        try
            events = capture_comm(model)

            # Deterministic RNG so a failure is reproducible; bump the seed
            # locally to fuzz when investigating.
            rng = Random.Xoshiro(0x5acefade)

            for i in 1:30
                action = rand(rng, (:send, :restart, :cancel))
                if action == :send
                    BT.send_message!(model, BT.UserMsg("iter$i"))
                elseif action == :restart
                    restart!(model)
                else
                    # Cancel a possibly-running turn. No-op if nothing's in flight.
                    BT.handle_command!(model, nothing, BT.CancelCommand())
                end
                # Small jitter so the consumer task has SOME interleaving without
                # making the test glacial.
                sleep(rand(rng, 1:5) / 1000)
            end

            # Drain. First force-reap any hung-mock stragglers the teardown
            # SIGTERM couldn't (see note above) — including the loop's current
            # (possibly-hung) child. SIGKILL EOFs every parked reader, so every
            # in-flight turn's `drain_turn!` finally runs and `turns_active`
            # settles to 0. THEN a final restart to a clean scenario brings up one
            # fresh, healthy session so the drained invariants below hold.
            reap_stragglers!()
            restart_with_scenario!(model, "normal")
            @test timedwait(() -> !model.busy_active[], 5.0) === :ok

            # ── Post-stress invariants ───────────────────────────────────
            @test model.session_alive[] == true
            @test model.busy_active[] == false
            @test !any(m -> m isa BT.AgentMsg   && m.in_flight, model.msgs_store)
            @test !any(m -> m isa BT.ThoughtMsg && m.in_flight, model.msgs_store)
            @test all(m -> !(m isa BT.ToolMsg) || m.status in ("completed","failed"),
                      model.msgs_store)
            # Every thinking=true was followed (eventually) by a thinking=false.
            # We assert the LAST thinking event observed in comm is `false`, which
            # is the user-visible property — the indicator isn't stuck.
            thinking_events = [e for e in events if get(e, "type", "") == "thinking"]
            if !isempty(thinking_events)
                @test last(thinking_events)["active"] == false
            end
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 6. Restart with a LIVE todo plan ────────────────────────────────
    # The agent emitted a `plan` SessionUpdate with pending/in_progress entries
    # and then hung. ARCHITECTURE: a LIVE todo is NOT a chat-history message — it
    # lives on `shared(chat).live_todo` and renders ONLY in the taskbar (a live
    # plan panel). (Real claude-agent-acp reports todos exclusively as `plan`
    # updates; the old TodoWrite tool_call path is inert on the chat side.) The
    # agent that was supposed to keep driving the plan just died — the restart
    # orphan sweep MUST `finalize_todo!` it: clear `live_todo`, stamp
    # `finished_at`, drop the taskbar slot, and append the (now zombied) plan to
    # `msgs_store` as a history bubble — so a fresh agent's first plan starts a
    # NEW one instead of mutating the abandoned list.
    @testset "restart with a live todo plan: closed via orphan sweep" begin
        model = mock_chat("plan_hang")
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("plan"))

            s = BT.shared(model)
            @test timedwait(() -> s.live_todo[] isa BT.TodoListMsg, 5.0) === :ok
            todo = s.live_todo[]
            @test BT.is_live(todo) == true
            @test todo.finished_at === nothing
            # While live it is on the taskbar, NOT in chat history yet.
            @test !any(m -> m isa BT.TodoListMsg, model.msgs_store)

            restart_with_scenario!(model, "normal")

            # Sweep finalized the plan: live_todo cleared, finished_at stamped,
            # is_live false, and it landed in chat history.
            @test s.live_todo[] === nothing
            @test todo.finished_at !== nothing
            @test BT.is_live(todo) == false
            @test any(m -> m === todo, model.msgs_store)
            # JS sees a trailing `plan` event whose `live` field went false, so the
            # taskbar slot drops and a new agent's first plan spawns a fresh bubble.
            plan_finals = [e for e in events
                           if get(e, "type", "") == "plan" &&
                              get(e, "id", "") == todo.id &&
                              get(e, "live", true) == false]
            @test !isempty(plan_finals)
            @test model.session_alive[] == true
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 7. Restart with a LIVE background BashToolMsg ───────────────────
    # The agent backgrounded a shell (`run_in_background:true`). On the chat side
    # this materialises as a `BashToolMsg` whose tool_call status is "completed"
    # (the LAUNCH completed instantly) but `is_background=true` + `bg_running=true`
    # + `bg_output_path != ""`. The shell itself runs in the WORKER, not in the ACP
    # session — so restarting the ACP must NOT touch this entry: the poller keeps
    # tailing the file, the taskbar slot stays live, and the user can keep watching
    # its output across as many restarts as they like.
    @testset "restart preserves a live background BashToolMsg" begin
        model = mock_chat("bg_bash_hang")
        try
            BT.send_message!(model, BT.UserMsg("background"))

            @test timedwait(() ->
                any(m -> m isa BT.BashToolMsg && m.is_background && m.bg_running,
                    model.msgs_store),
                5.0) === :ok
            bash = first(m for m in model.msgs_store
                         if m isa BT.BashToolMsg && m.is_background)
            @test bash.bg_running == true
            @test bash.status == "completed"   # the LAUNCH completed; the shell is live
            @test !isempty(bash.bg_output_path)
            @test bash.finished_at === nothing

            restart_with_scenario!(model, "normal")

            # Sweep left the background tool ALONE — its lifecycle is the worker's
            # file, not the ACP session.
            @test bash.bg_running == true
            @test bash.finished_at === nothing
            @test bash.status == "completed"
            @test BT.is_live(bash) == true  # still live for the taskbar
            @test model.session_alive[] == true
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # ── 8. Restart-during-restart: concurrent calls ────────────────────
    # Two `restart_chat_session!` calls racing. The restart serializer must make
    # them converge to ONE live session without wedging or leaving a half-state.
    # The bounded-wait timeout caps the failure mode instead of hanging the suite.
    # With each agent owning its own subprocess, the old clobber that made this
    # race-prone is gone — both calls must land on one usable client.
    @testset "two concurrent restarts converge to one live session" begin
        model = mock_chat("normal")
        try
            t1 = @async restart!(model)
            t2 = @async restart!(model)
            # Wait for both to return; timedwait caps at 10 s.
            @test timedwait(() -> istaskdone(t1) && istaskdone(t2), 10.0) === :ok

            @test model.session_alive[] == true
            @test model.busy_active[] == false
            # The agent must hold a usable, live client (non-nothing).
            @test BT.client(model.agent) !== nothing
            @test BT.isopen(model.agent) == true
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
            reap_stragglers!()
        end
    end

    # No leaked mock subprocess survives the suite. Each test `stop!`s its agent
    # AND `reap_stragglers!()`s in `finally`, so by here the count is already back
    # to baseline; `reap_stragglers!(base_procs)` is the belt-and-suspenders final
    # sweep (a no-op if already clean) that also waits out any in-flight reap.
    @test reap_stragglers!(base_procs) === :ok
    @test mock_proc_count() <= base_procs
end
