# auto_prompt: a project-level field set by the "From GitHub" template
# (or any other seeding flow) that gets fired as the first user message
# the very first time the chat brings up an ACP session, and is then
# cleared + persisted to nothing so a server restart doesn't re-fire.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]
proj.auto_prompt = "review the README and tell me what's wrong"

# A short streaming reply so the auto_prompt path runs end-to-end.
scripted = [(0.05, TH.agent_chunk_update("README looks fine."))]

let
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted))
    BonitoAgents.start_chat_client!(model)
    BonitoAgents.fire_auto_prompt!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    # Select the row by its stable data-project-id: the auto-prompt turn
    # already ran, so the sidebar shows a meaningful title derived from
    # the prompt, NOT the raw project name "Project1".
    @assert TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 5.0) "p-1 sidebar row missing"
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("auto_prompt fires as the first user message") do
        record("user bubble carries the auto_prompt text",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const us = document.querySelectorAll('.bt-user-msg');
                       return Array.from(us).some(u => (u.innerText || '').indexOf('review the README') !== -1);
                   })()
               """; timeout = 5.0))
    end

    TH.section("auto_prompt is cleared on the project (so it doesn't re-fire)") do
        # fire_auto_prompt! sets proj.auto_prompt = nothing immediately.
        record("proj.auto_prompt now nothing",
               @TH.test_eq state.projects[]["p-1"].auto_prompt nothing)
    end

    TH.section("Agent reply still arrives normally") do
        record("agent bubble appears",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const as = document.querySelectorAll('.bt-agent-msg');
                       return Array.from(as).some(a => (a.innerText || '').indexOf('README looks fine') !== -1);
                   })()
               """; timeout = 5.0))
    end

    TH.section("Restart-safety: auto_prompt persisted as nothing") do
        # Save + reload state from disk; auto_prompt should remain nothing,
        # so a server restart doesn't replay the seeded message.
        BonitoAgents.save_projects!(state)
        s2 = BonitoAgents.ServerState(;
                state_dir     = state.state_dir,
                working_dir   = state.working_dir,
                worker_secret = state.worker_secret)
        record("post-restart proj.auto_prompt still nothing",
               @TH.test_eq s2.projects[]["p-1"].auto_prompt nothing)
    end

    TH.section("Calling fire_auto_prompt! again is a no-op") do
        # auto_prompt cleared + msgs_store non-empty → guard kicks in and
        # nothing extra happens.
        before_count = length(state.chat_models["p-1"].msgs_store)
        BonitoAgents.fire_auto_prompt!(state.chat_models["p-1"])
        sleep(0.2)
        record("msgs_store length unchanged after re-call",
               @TH.test_eq length(state.chat_models["p-1"].msgs_store) before_count)
    end

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "auto-prompt — final")

finally
    TH.report!("Auto-prompt", results)
    TH.shutdown(ctx)
end
