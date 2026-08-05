# Black-box e2e for the "auto prompt" feature, ported from the legacy electron
# test `test/electron/test_auto_prompt.jl`.
#
# What auto-prompt is (production contract):
#   `auto_prompt` is a per-PROJECT config field on `ProjectInfo`. In production
#   it is seeded by the "From GitHub" flow (`create_project_from_github!` →
#   `github_issue_prompt`) for issue/PR URLs. When the project's chat session is
#   next brought up (`ensure_project_session!` → `bring_up_project_session!` →
#   `fire_auto_prompt!`), and the chat is otherwise empty, the stored prompt is
#   fired ONCE as the first user message, then `auto_prompt` is cleared and
#   persisted to `nothing` so a server restart / session reconnect never
#   re-fires it.
#
# Why this drives the REAL config path (and not the UI button):
#   The only black-box UI entrypoint that seeds `auto_prompt` is "+ From GitHub",
#   which clones a real repo and fetches GitHub issue metadata over the network —
#   not reproducible against the mock worker. So, exactly like the sibling
#   `chat_close_rename` suite reaches `BT.ensure_project_session!` /
#   `server.h.state` to drive the discover-menu Resume entrypoint the mock can't
#   surface, this suite seeds the SAME real config field (`proj.auto_prompt`) on
#   the real `ServerState` and then drives the SAME real production fire path
#   (`stop_session!` → set field → `ensure_project_session!`). Everything we
#   ASSERT on is rendered DOM (the user/agent bubbles) plus the persisted config
#   the restart-safety contract is about.
#
# Sequence mirrors production "From GitHub": a project exists with no live
# session and an empty transcript, `auto_prompt` gets set, then the session is
# brought up → the prompt fires as the first user message.
@testitem "e2e:auto_prompt" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

    s     = SharedServer.server()
    state = s.h.state

    # Scripted reply so the auto_prompt turn runs end to end (user bubble +
    # agent reply), and a recognisable follow-up echo for the no-re-fire check.
    const AUTO_PROMPT = "review the README and tell me what's wrong"
    s.agent_fn[] = prompt -> begin
        if occursin("review the README", prompt)
            [TK.text("README looks fine."), TK.end_turn()]
        else
            [TK.text("echo: $(prompt)"), TK.end_turn()]
        end
    end

    # 1. Create a real chat the way a user does. No message is sent, so the
    #    project's transcript stays empty and `auto_prompt` is unset → the
    #    bring-up that `new_chat` performs fires nothing.
    pid  = TK.new_chat(s; title = "AutoPrompt")
    proj = state.projects[][pid]
    @test proj.auto_prompt === nothing

    # 2. Tear the freshly-bound session down so we're back to the production
    #    pre-condition the GitHub flow sets up: a registered project with NO
    #    live ChatModel and an empty transcript. `stop_session!` evicts the
    #    model from `state.chat_models`.
    BT.stop_session!(state, proj)
    @test TK.wait_for(s, "session torn down",
        "true"; timeout = 1) == true  # settle the @async teardown notify
    @test !haskey(state.chat_models, pid)

    # 3. Seed the auto_prompt on the real config field — the exact field
    #    `create_project_from_github!` writes for an issue/PR URL.
    proj.auto_prompt = AUTO_PROMPT
    BT.save_projects!(state)

    @testset "auto_prompt fires as the first user message" begin
        # 4. Bring the session back up via the SAME entrypoint the GitHub flow
        #    and the discover-menu Resume button use. This runs
        #    `fire_auto_prompt!`, which (transcript empty) sends the stored
        #    prompt as the first user message and clears the field.
        BT.ensure_project_session!(state, proj)
        # Make sure the chat is the one on screen so the rendered DOM is the
        # pane we assert against.
        TK.open_chat(s, pid)

        @test TK.wait_for(s, "auto_prompt user bubble",
            """(() => {
                const us = document.querySelectorAll('.bt-user-msg');
                return [...us].some(u => (u.innerText || '').includes('review the README'));
            })()""";
            timeout = 30) == true
    end

    @testset "auto_prompt is cleared (so it doesn't re-fire)" begin
        # fire_auto_prompt! sets the field to nothing immediately + persists it.
        @test TK.wait_for(s, "auto_prompt cleared on project",
            "true"; timeout = 1) == true
        @test state.projects[][pid].auto_prompt === nothing
    end

    @testset "agent reply to the auto_prompt arrives normally" begin
        @test TK.wait_for(s, "agent reply rendered",
            """(() => {
                const as = document.querySelectorAll('.bt-agent-msg');
                return [...as].some(a => (a.innerText || '').includes('README looks fine'));
            })()""";
            timeout = 30) == true
    end

    @testset "no re-fire: a normal follow-up doesn't replay the auto_prompt" begin
        # Count the auto_prompt user bubbles before the follow-up.
        before = TK.eval_js(s, """(() => [...document.querySelectorAll('.bt-user-msg')]
            .filter(u => (u.innerText || '').includes('review the README')).length)()""")
        @test before == 1

        TK.send_message(s, "what about the tests")
        @test TK.wait_for(s, "follow-up echoed",
            """(() => {
                const as = document.querySelectorAll('.bt-agent-msg');
                return [...as].some(a => (a.innerText || '').includes('echo: what about the tests'));
            })()""";
            timeout = 30) == true

        # Still exactly ONE auto_prompt bubble — the cleared field means the
        # next turn's bring-up/send path never re-seeds it.
        after = TK.eval_js(s, """(() => [...document.querySelectorAll('.bt-user-msg')]
            .filter(u => (u.innerText || '').includes('review the README')).length)()""")
        @test after == 1
        @test state.projects[][pid].auto_prompt === nothing
    end

    @testset "restart-safety: auto_prompt persisted as nothing" begin
        # Persist + reload the project store from disk exactly as a server
        # restart would. The reloaded project must carry `auto_prompt = nothing`
        # so a restart can't replay the seeded message.
        BT.save_projects!(state)
        reloaded = BT.ServerState(;
            state_dir     = state.state_dir,
            working_dir   = state.working_dir,
            worker_secret = state.worker_secret)
        @test haskey(reloaded.projects[], pid)
        @test reloaded.projects[][pid].auto_prompt === nothing
    end

    @test isempty(TK.js_errors(s))
end
