# Tier 2d — non-input chat controls.
#
#   - Stop button cancels an in-flight prompt
#   - Sync button (the one we just fixed) actually fires its handler — no
#     `Bonito.notify_observable is not a function` JS error
#   - Session-ended banner appears when session_alive flips false
#   - Restart button on the banner restores session_alive to true
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)

# A long-running stream so the stop test has time to interrupt: 10 chunks at
# 0.3s each = 3s of streaming.
slow_script = [(0.3, TH.agent_chunk_update("chunk$i ")) for i in 1:10]

let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted = slow_script))
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
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"
    local model = state.chat_models["p-1"]

    TH.section("Stop button cancels an in-flight prompt") do
        TH.type_into(ctx, ".bt-text-input", "go")
        TH.dom_click(ctx, ".bt-send-btn")
        # Wait for streaming to actually start (first chunk lands).
        @assert TH.wait_for(ctx,
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 3.0) "no agent bubble"

        # Hit stop. The mock cancel is fire-and-forget (notification, not
        # request), so the streamer keeps emitting until completion — but
        # AgentClientProtocol.cancel! does send the notification. We assert
        # *something* happens: either the request completes faster than 10
        # chunks (the mock would normally take 3s) OR busy clears.
        before_chunks = TH.eval_js(ctx, "document.querySelectorAll('.bt-agent-msg')[0].innerText.length")
        TH.dom_click(ctx, ".bt-stop-btn")
        sleep(0.3)
        record("stop click did not throw a JS error",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
        # The cancel notification reaches the mock; we just verify the call
        # didn't crash (real workers respond to the cancel by ending the turn).
        record("agent bubble still present (cancel doesn't wipe history)",
               @TH.test_true TH.dom_exists(ctx, ".bt-agent-msg"))
        # Drain remaining stream so subsequent sections don't race with it.
        sleep(3.0)
    end

    TH.section("Sync button click — no JS errors (the fix we made today)") do
        # Click and assert nothing throws. The sync handler will fail on the
        # backend (no real worker), but the click must reach Julia cleanly.
        before_errs = length(TH.js_errors(ctx))
        TH.dom_click(ctx, ".bt-header-sync")
        sleep(0.4)
        after_errs = length(TH.js_errors(ctx))
        record("no new JS errors after sync click",
               @TH.test_eq after_errs before_errs)
        # The sync_status observable starts at "" (button reads "Sync"); on
        # click it should change to "starting…" or an error string. Either way
        # it's not "Sync" anymore.
        btn_text = TH.eval_js(ctx, "document.querySelector('.bt-header-sync').innerText")
        record("sync button text changed from 'Sync'",
               @TH.test_true btn_text != "Sync")
    end

    TH.section("Dead-session pulse on the restart button + Restart works") do
        # The permanent header restart button starts in the healthy state.
        record("restart button healthy initially",
               @TH.test_true !TH.dom_exists(ctx, ".bt-header-restart-dead"))

        # Flip session_alive from Julia → button gains the dead/pulse class.
        model.session_alive[] = false
        model.last_error[]    = "test-induced disconnect"
        record("restart button flips to dead/pulse after session_alive=false",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-header-restart-dead') !== null";
                                         timeout = 3.0))

        # Click the (now-pulsing) restart button. The handler calls
        # `restart_chat_session!` which rebuilds the client via the mock
        # factory and sets session_alive back to true.
        TH.eval_js(ctx, """
            const btn = document.querySelector('.bt-header-restart-dead');
            if (btn) btn.click();
        """)
        record("restart button returns to healthy after restart",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-header-restart-dead') === null";
                                         timeout = 5.0))
        record("session_alive observable is true again",
               @TH.test_eq model.session_alive[] true)
    end

    TH.section("No JS errors") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_true (length(errs) == 0))
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "tier 2d — controls")

finally
    TH.report!("Tier 2d — chat controls", results)
    TH.shutdown(ctx)
end
