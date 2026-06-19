# auto_prompt: a project-level field set by the "From GitHub" template (or any
# other seeding flow) that gets fired as the FIRST user message the very first
# time the chat brings up an ACP session, and is then cleared + persisted to
# nothing so a server restart doesn't re-fire.
#
# Migrated onto the TestKit harness: real dev_server, real worker subprocess,
# real ACP wire, real Electron browser. The agent's behaviour is the only fake —
# a reactive mock that answers the auto-fired prompt with a short reply, so the
# whole auto_prompt → send_message! → worker → agent → reply path runs for real.
#
# We exercise the production seam directly: create a chat (real UI), tear its
# session down (`stop_session!` evicts the model), stamp `auto_prompt` on the
# project, then re-open the chat through the UI. Re-opening calls
# `ensure_project_session!` → fresh ChatModel → `fire_auto_prompt!`, exactly as a
# first-ever open of a GitHub-seeded project does.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn

const AP_PROMPT = "review the README and tell me what's wrong"

@testset "auto_prompt fires as the first user message, then is cleared" begin
    # The agent answers whatever prompt it receives with a short reply, so the
    # auto-fired prompt completes a full turn end-to-end.
    s = TK.dev_server(; agent = msg -> [text("README looks fine."), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)

        # 1. Create the project + chat the normal way. This opens a session with
        #    NO auto_prompt set (harmless), then we tear it down so we can seed
        #    auto_prompt before the FIRST real bring-up of the prompt path.
        pid = TK.new_chat(s)

        state = s.h.state
        proj  = lock(state.lock) do
            state.projects[][pid]
        end

        # Evict the live model so the next open is a genuine first-bring-up.
        BonitoAgents.stop_session!(state, proj)
        # Seed the auto_prompt the way the GitHub template / seeding flow does.
        # A GitHub-imported project carries a `title` (repo name) on disk, so it
        # stays listed in the sidebar across a restart even with no live model —
        # which is exactly the pre-first-open state we want to reproduce here.
        proj.title       = "seeded-project"
        proj.auto_prompt = AP_PROMPT
        BonitoAgents.notify_chats!(state)
        @test proj.auto_prompt == AP_PROMPT

        # 2. Re-open the chat from the sidebar — ensure_project_session! rebuilds
        #    the model and fire_auto_prompt! sends AP_PROMPT as the first user
        #    message. The agent replies, completing the turn.
        TK.to_dashboard(s)
        TK.open_chat(s, pid)

        # The user bubble must carry the auto_prompt text — proof it fired as a
        # real user message through the real send path.
        TK.wait_for(s, "auto_prompt user bubble", """
            (() => {
                const us = document.querySelectorAll('.bt-user-msg');
                return Array.from(us).some(u => (u.innerText || '').indexOf('review the README') !== -1);
            })()
        """; timeout = 30)

        # The agent reply still arrives normally.
        TK.wait_for(s, "agent reply", """
            (() => {
                const as = document.querySelectorAll('.bt-agent-msg');
                return Array.from(as).some(a => (a.innerText || '').indexOf('README looks fine') !== -1);
            })()
        """; timeout = 30)

        # auto_prompt is cleared on the project immediately (so it never re-fires).
        @test proj.auto_prompt === nothing

        # Restart-safety: save + reload state from disk; auto_prompt stays nothing
        # so a server restart doesn't replay the seeded message.
        BonitoAgents.save_projects!(state)
        s2 = BonitoAgents.ServerState(;
                state_dir     = state.state_dir,
                working_dir   = state.working_dir,
                worker_secret = state.worker_secret)
        @test s2.projects[][pid].auto_prompt === nothing

        # Calling fire_auto_prompt! again is a no-op (auto_prompt cleared +
        # msgs_store non-empty → guard kicks in, nothing extra happens).
        model = lock(state.lock) do; state.chat_models[pid]; end
        before_count = length(model.msgs_store)
        BonitoAgents.fire_auto_prompt!(model)
        sleep(0.3)
        @test length(model.msgs_store) == before_count

        TK.screenshot(s, joinpath(tempdir(), "bt-auto-prompt-final.png"))

        # No JS errors fired in the renderer.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
