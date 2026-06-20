# Virtual scroll: a populated history (200 messages) should NOT all live in
# the DOM at once. Only the visible-window slice (plus overscan) is
# materialised; scrolling fetches the next slice via requestRange and
# evicts off-screen nodes.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

# `JSON.json(...)` is interpolated into the test's eval_js strings at Main scope.
using JSON

const N_HISTORY = 200    # 100 user + 100 agent pairs

state = TH.make_state(; n_workers = 1, n_projects = 1)

let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
    TH.seed_chat_history!(model, N_HISTORY ÷ 2)
    @assert length(model.msgs_store) == N_HISTORY
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("Initial mount renders only a window") do
        # Wait for the first range fetch to land.
        @assert TH.wait_for(ctx,
            "document.querySelectorAll('.bt-user-msg, .bt-agent-msg').length > 0";
            timeout = 5.0) "no bubbles materialised"
        sleep(0.5)  # let the initial-load scroll-to-bottom + ResizeObserver settle

        n_in_dom = TH.eval_js(ctx,
            "document.querySelectorAll('.bt-user-msg, .bt-agent-msg').length")
        record("DOM has SOME bubbles", @TH.test_true (n_in_dom > 0))
        # We seeded 200; if the virtual-scroll worked, the DOM has far fewer.
        # If it broke, we'd see all 200. Threshold: anything below 100 means
        # windowing kicked in. Typical with EST_HEIGHT=80 in a ~600px viewport
        # is ~15-20 bubbles + overscan.
        record("virtual-scroll caps DOM well below total ($n_in_dom < 100)",
               @TH.test_true (n_in_dom < 100))
        # The chat object is hung off the .bt-messages node by
        # `connect(node, comm)` in bonitoagents.js as `node.__bt_chat = chat`.
        # totalCount should reflect all 200.
        total = TH.eval_js(ctx,
            "document.querySelector('.bt-messages').__bt_chat.totalCount")
        record("totalCount mirrors model", @TH.test_eq Int(total) N_HISTORY)
    end

    TH.section("Initial scroll position is at the bottom (newest message)") do
        # initialLoad → scrollToBottom fires after the FIRST range response.
        # That triggers a second range fetch (now near the bottom), and the
        # latest agent bubble ("ok 100") only materialises after that round
        # trip finishes — so we wait on its appearance, not on raw scrollTop.
        record("seeded 'ok 100' bubble surfaces near the bottom",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const els = document.querySelectorAll('.bt-agent-msg');
                       return Array.from(els).some(e => e.innerText === 'ok 100');
                   })()
               """; timeout = 5.0))
        # And once the latest bubble is in the DOM the container should be
        # parked near the bottom.
        ok_at_bottom = TH.eval_js(ctx, """
            (() => {
                const c = document.querySelector('.bt-messages');
                if (!c) return false;
                return c.scrollHeight - (c.scrollTop + c.clientHeight) < 200;
            })()
        """)
        record("scroll position within 200px of the bottom",
               @TH.test_true ok_at_bottom)
    end

    TH.section("Scroll up triggers a new range fetch + new bubbles render") do
        # Capture the current top-most rendered bubble's text so we can
        # verify a different (earlier) bubble surfaces after scrolling up.
        top_before = TH.eval_js(ctx, """
            (() => {
                const els = document.querySelectorAll('.bt-user-msg, .bt-agent-msg');
                return els.length > 0 ? els[0].innerText : '';
            })()
        """)
        # Jump to scrollTop = 0 (top of the messages container) to force a
        # range request for index 0. Dispatch a synthetic 'scroll' event
        # after the assignment: in Electron's offscreen renderer (and some
        # other headless browser setups), programmatic `scrollTop = N`
        # changes the value but doesn't fire a 'scroll' event, so the chat's
        # _onScroll listener would never see the jump.
        TH.eval_js(ctx, """
            const c = document.querySelector('.bt-messages');
            if (c) {
                c.scrollTop = 0;
                c.dispatchEvent(new Event('scroll'));
            }
        """)
        # Give the scroll listener + range round-trip a moment.
        record("a different top bubble appears after scrolling up",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const els = document.querySelectorAll('.bt-user-msg, .bt-agent-msg');
                       return els.length > 0 && els[0].innerText !== $(JSON.json(top_before));
                   })()
               """; timeout = 5.0))
        # The very first message we seeded was "hi 1"; after scrolling all
        # the way up it should be visible.
        record("seeded 'hi 1' bubble visible at top",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const u = document.querySelectorAll('.bt-user-msg');
                       return Array.from(u).some(e => e.innerText === 'hi 1');
                   })()
               """; timeout = 5.0))
    end

    TH.section("Spacers maintain virtual scrollHeight") do
        # bt-spacer-top + visible bubbles + bt-spacer-bottom should add up
        # to roughly N_HISTORY * EST_HEIGHT (80px each → ~16000px). The
        # browser's scrollHeight reflects the full virtual content.
        sh = TH.eval_js(ctx,
            "document.querySelector('.bt-messages').scrollHeight")
        record("scrollHeight reflects ~all 200 msgs (>= 8000px)",
               @TH.test_true (Int(sh) >= 8000))
    end

    TH.section("No JS errors during scroll exercise") do
        record("zero JS errors",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "virtual scroll — final")

finally
    TH.report!("Virtual scroll", results)
    TH.shutdown(ctx)
end
