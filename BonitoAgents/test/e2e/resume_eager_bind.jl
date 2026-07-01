# Server-level regression for the "an old chat opens BLANK until you type" bug.
#
# A RESUMED chat (one with a `resume_session_id`) keeps its conversation only in
# the agent's session; the history replays via `session/load` when the agent
# binds. The chat view registers LAZILY (`register_chat_model!` — bind on first
# turn), so a freshly imported chat with no server-side `chat.md` history yet
# used to open empty and stay empty until the first message lazily bound the
# agent. `bring_up_project_session!` now binds eagerly when resuming with no
# local history, so the conversation appears on open.
#
# This drives the SERVER path (no browser): `create_project_from_worker!` with
# and without a `resume_session_id`, asserting the agent binds eagerly only for
# the resume case. (The mock's `session/load` returns no replay frames, so we
# assert on the BIND, not on a populated store — the bind is the behaviour that
# regressed; real `claude-agent-acp` then streams the history through it.)

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
const BA = TestKit.BT

# Poll a server-side condition (no browser involved).
function poll_until(cond; timeout = 30.0, interval = 0.25)
    t0 = time()
    while time() - t0 < timeout
        cond() && return true
        sleep(interval)
    end
    return false
end

function run_suite(server)
    state = server.h.state
    # Wait for the worker to dial in.
    @test poll_until(() -> !isempty(state.workers[]); timeout = 30)
    wid = first(keys(state.workers[]))

    @testset "resumed chat binds the agent eagerly on open" begin
        # Resume → eager bind: the agent gets a live client WITHOUT any turn.
        pres = BA.create_project_from_worker!(state, wid, mktempdir();
            name = "resumeChat", resume_session_id = "mock-resume-eager",
            start_session = true)
        @test poll_until(timeout = 30) do
            m = get(state.chat_models, pres.id, nothing)
            m !== nothing && m.agent.client !== nothing
        end

        # No resume → stays lazy: no client until the first turn.
        pfresh = BA.create_project_from_worker!(state, wid, mktempdir();
            name = "freshChat", resume_session_id = nothing, start_session = true)
        # Give the (would-be) bring-up a chance to run, then assert it did NOT.
        sleep(3.0)
        mf = get(state.chat_models, pfresh.id, nothing)
        @test mf !== nothing
        @test mf.agent.client === nothing
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server()
    try
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
