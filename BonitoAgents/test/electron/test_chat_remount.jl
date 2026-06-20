# Tier 2e — re-mount preserves history (regression check).
#
# Flow under test: send a prompt, get a response, navigate Home, navigate back
# to the project. The chat panel re-mounts; the user/agent bubbles from before
# the navigation should still be visible.
#
# This was flagged as a follow-up earlier: chat re-mount after Home nav doesn't
# auto-render history. If the bug is still live, the assertions in the
# "After remount" section will FAIL — that's intentional, so this file
# documents the bug until we fix it.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents

state = TH.make_state(; n_workers = 1, n_projects = 1)

scripted = [(0.05, TH.agent_chunk_update("first response"))]

let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted))
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """
        (() => {
            const items = document.querySelectorAll('.bt-side-item .bt-side-name');
            for (let i = 0; i < items.length; i++)
                if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
            return -1;
        })()
    """)

    TH.section("Send + receive a turn") do
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
        @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"
        TH.type_into(ctx, ".bt-text-input", "first prompt")
        TH.dom_click(ctx, ".bt-send-btn")
        record("user bubble", @TH.test_true TH.wait_for(ctx,
            "document.querySelectorAll('.bt-user-msg').length >= 1"))
        record("agent bubble", @TH.test_true TH.wait_for(ctx,
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 5.0))
        # Wait for the busy indicator to clear so we know the turn fully ended.
        record("busy clears",
               @TH.test_true TH.wait_for(ctx,
                   "!document.querySelector('.bt-busy').classList.contains('bt-busy-active')";
                   timeout = 5.0))
    end

    # Snapshot the model state for verification after remount.
    local model = state.chat_models["p-1"]
    n_msgs_before = length(model.msgs_store)
    n_user_before  = TH.dom_count(ctx, ".bt-user-msg")
    n_agent_before = TH.dom_count(ctx, ".bt-agent-msg")

    TH.section("Navigate Home") do
        # Chat panes are KEPT ALIVE on navigation (display:none, see
        # unified_main's pane cache) — so .bt-app stays in the DOM. What
        # must change is visibility: dashboard shown, chat pane hidden.
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[0].click()""")
        record("dashboard becomes visible",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const dash = document.querySelector('.bt-view-dash');
                       return dash !== null && dash.style.display !== 'none';
                   })()
               """; timeout = 3.0))
        record("chat pane hidden (kept alive)",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const panes = document.querySelectorAll('.bt-view-chats .bt-chatpane');
                       return Array.from(panes).every(p => p.style.display === 'none');
                   })()
               """))
    end

    TH.section("Navigate back to project — history should still be there") do
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
        record("chat pane visible again",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const app = document.querySelector('.bt-app');
                       if (!app) return false;
                       const pane = app.closest('.bt-chatpane');
                       return pane === null || pane.style.display !== 'none';
                   })()
               """; timeout = 3.0))
        # Give the JS-side BonitoChat a moment to do its initial range fetch.
        sleep(0.5)

        # The model state on Julia is unchanged.
        record("model.msgs_store unchanged",
               @TH.test_eq length(model.msgs_store) n_msgs_before)

        # THESE are the assertions that fail today (the bug):
        # the re-mounted DOM doesn't repaint the history bubbles.
        record("user bubble re-renders",
               @TH.test_eq TH.dom_count(ctx, ".bt-user-msg") n_user_before)
        record("agent bubble re-renders",
               @TH.test_eq TH.dom_count(ctx, ".bt-agent-msg") n_agent_before)
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 2e — after remount")

finally
    TH.report!("Tier 2e — chat remount", results)
    TH.shutdown(ctx)
end
