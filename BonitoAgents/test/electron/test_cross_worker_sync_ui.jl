# Tier 2e — cross-worker sync modal, UI wiring.
#
# Complements the backend test (test_cross_worker_sync.jl) by driving the
# actual DOM: the chat header surfaces a "⇄ <worker>" button only when the
# open project has a same-named sibling on another worker; clicking it opens
# the comparison modal (render_sync_modal); the modal shows both sides and
# its Cancel/direction buttons behave.
#
# Workers here are the offline stubs from make_state, so `compare_projects`
# falls back to the server-side mirror — which is why both projects'
# server_path dirs are seeded with real files below.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents, Dates

state = TH.make_state(; n_workers = 2, n_projects = 0)

# Two projects with the SAME display name on DIFFERENT workers. Seed each
# project's server-side mirror with real, distinct content so the offline
# fallback in `inspect_project` has something to summarise.
const NM = "BonitoAgents"
sp1 = mktempdir(); write(joinpath(sp1, "README.md"), "FROM w-1\n"); write(joinpath(sp1, "one.txt"), "1\n")
sp2 = mktempdir(); write(joinpath(sp2, "README.md"), "FROM w-2\n"); write(joinpath(sp2, "two.txt"), "2\n")
p1 = BonitoAgents.ProjectInfo("p-1", NM, "w-1", sp1, "/tmp/w1/$NM", now())
p2 = BonitoAgents.ProjectInfo("p-2", NM, "w-2", sp2, "/tmp/w2/$NM", now())
state.projects[]["p-1"] = p1
state.projects[]["p-2"] = p2
notify(state.projects)

# A chat session for p-1 (mock transport — no real worker / claude).
let model = BonitoAgents.ChatModel(state, p1.server_path;
                                  project_id = p1.id,
                                  transport  = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    # Navigate into p-1's chat. The worker tag lives in the icon now (the
    # name span carries just the title), so select the row by its stable
    # data-project-id instead of matching label text.
    found = TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 5.0)
    record("found p-1 sidebar row", @TH.test_true found)
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"

    TH.section("⇄ button present only because a sibling exists") do
        # Two .bt-header-sync buttons now: the cross-worker one + plain Sync.
        record("two header-sync buttons", @TH.test_eq TH.dom_count(ctx, ".bt-header-sync") 2)
        has_x = TH.eval_js(ctx, """
            [...document.querySelectorAll('.bt-header-sync')].some(b => b.innerText.includes('⇄'))
        """)
        record("one button is the cross-worker (⇄) control", @TH.test_true has_x)
        names_other_worker = TH.eval_js(ctx, """
            [...document.querySelectorAll('.bt-header-sync')].some(b => b.innerText.includes('w-2'))
        """)
        record("⇄ button names the other worker (w-2)", @TH.test_true names_other_worker)
    end

    TH.section("clicking ⇄ opens the comparison modal") do
        TH.eval_js(ctx, """
            (() => { const b = [...document.querySelectorAll('.bt-header-sync')]
                        .find(x => x.innerText.includes('⇄')); if (b) b.click(); })()
        """)
        record("modal overlay appears",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-collision-overlay') !== null";
                                         timeout = 5.0))
        record("modal shows two side panels",
               @TH.test_eq TH.dom_count(ctx, ".bt-collision-side") 2)
        record("modal has three action buttons",
               @TH.test_eq TH.dom_count(ctx, ".bt-collision-actions button") 3)
        title = TH.dom_text(ctx, ".bt-collision-card h3")
        record("modal title names the project",
               @TH.test_true title !== nothing && occursin(NM, title))
        # Both workers should be named somewhere in the card.
        card = TH.dom_text(ctx, ".bt-collision-card")
        record("card references both workers",
               @TH.test_true card !== nothing && occursin("w-1", card) && occursin("w-2", card))
    end

    TH.section("Cancel closes the modal") do
        TH.dom_click(ctx, ".bt-collision-actions .bt-btn-ghost")
        record("overlay gone after Cancel",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-collision-overlay') === null";
                                         timeout = 5.0))
    end

    TH.section("a direction button dismisses the modal without JS error") do
        # Re-open, then click the primary (push) direction. The backend apply
        # fails because the stub workers aren't connected — but the handler
        # catches it and closes the modal; the click itself must not throw.
        TH.eval_js(ctx, """
            (() => { const b = [...document.querySelectorAll('.bt-header-sync')]
                        .find(x => x.innerText.includes('⇄')); if (b) b.click(); })()
        """)
        @assert TH.wait_for(ctx, "document.querySelector('.bt-collision-overlay') !== null";
                            timeout = 5.0) "modal didn't reopen"
        before = length(TH.js_errors(ctx))
        TH.dom_click(ctx, ".bt-collision-actions .bt-btn-primary")
        record("overlay closes after a direction pick",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-collision-overlay') === null";
                                         timeout = 5.0))
        record("no new JS error from the apply click",
               @TH.test_eq length(TH.js_errors(ctx)) before)
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 2e — cross-worker sync modal")

finally
    TH.report!("Tier 2e — cross-worker sync UI", results)
    TH.shutdown(ctx)
end
