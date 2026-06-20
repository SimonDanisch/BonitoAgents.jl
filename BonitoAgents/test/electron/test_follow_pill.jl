# Tier 2n — follow mode + "↓ New messages" pill.
#
# Verifies the new scroll-UX contract:
#   - followMode starts true; chunks auto-scroll the viewport
#   - user scrolls up → followMode flips false, pill mounts hidden
#   - new content while disengaged → pill becomes visible, unreadCount++
#   - clicking the pill → followMode back to true, pill hides,
#     scrollTop snaps to bottom (no smooth-scroll over 1000 messages)
#   - user scrolling back to the very bottom (within AT_BOTTOM_PX) also
#     re-engages followMode automatically (Slack/Discord style)
#   - sending a user message always re-engages, even from scrollback
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using JSON

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]
let
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
    TH.seed_chat_history!(model, 20)
end

ctx = TH.open_window(state)
chat = state.chat_models["p-1"]
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"
    sleep(1.0)

    follow_mode() = TH.eval_js(ctx,
        "document.querySelector('.bt-messages').__bt_chat.followMode")
    unread()      = TH.eval_js(ctx,
        "document.querySelector('.bt-messages').__bt_chat.unreadCount")
    pill_visible() = TH.eval_js(ctx, """
        (() => {
            const el = document.querySelector('.bt-new-msg-pill');
            return el ? el.classList.contains('bt-new-msg-pill-visible') : false;
        })()
    """)

    function scroll_up_as_user!()
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        sleep(0.3)
    end

    function emit_agent_burst(stream_id, n)
        if !any(m -> m isa BonitoAgents.AgentMsg && m.id == stream_id, chat.msgs_store)
            push!(chat.msgs_store, BonitoAgents.AgentMsg(stream_id, ""))
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "agent", "id" => stream_id, "streaming" => true,
                "text" => "", "n" => length(chat.msgs_store)))
            sleep(0.15)
        end
        for _ in 1:n
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "chunk", "id" => stream_id,
                "text" => "More content arriving while user is scrolled away. "))
        end
    end

    # ── 1. Initial state ──────────────────────────────────────────────────
    TH.section("Initial: followMode=true, no pill") do
        record("followMode is true",     @TH.test_eq follow_mode() true)
        record("unreadCount is 0",       @TH.test_eq unread() 0)
        record("pill not visible",       @TH.test_eq pill_visible() false)
    end

    # ── 2. Streaming while at bottom — no pill ───────────────────────────
    TH.section("Streaming while at bottom doesn't show pill") do
        emit_agent_burst("burst-1", 8)
        sleep(0.8)
        record("followMode still true",  @TH.test_eq follow_mode() true)
        record("unreadCount still 0",    @TH.test_eq unread() 0)
        record("pill still hidden",      @TH.test_eq pill_visible() false)
    end

    # ── 3. User scrolls up → followMode off, pill mounts hidden ──────────
    TH.section("User scroll-to-top disengages follow mode") do
        scroll_up_as_user!()
        record("followMode is false",    @TH.test_eq follow_mode() false)
        # Pill still hidden — nothing new yet to be unread.
        record("pill still hidden (no unread yet)",
               @TH.test_eq pill_visible() false)
    end

    # ── 4. New chunks while disengaged → pill becomes visible ────────────
    TH.section("New content while disengaged surfaces the pill") do
        emit_agent_burst("burst-2", 6)
        sleep(0.8)
        record("followMode still false (chunks didn't yank us back)",
               @TH.test_eq follow_mode() false)
        record("pill is visible",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible') !== null";
                   timeout = 2.0))
        record("unreadCount > 0",        @TH.test_true (Int(unread()) > 0))
    end

    # ── 5. Click pill → followMode on, scroll to bottom, pill hides ──────
    TH.section("Clicking the pill jumps back, hides pill, re-engages follow") do
        TH.eval_js(ctx,
            "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible').click()")
        # Allow rAF + scroll handler to settle.
        record("followMode is true after pill click",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-messages').__bt_chat.followMode === true";
                   timeout = 2.0))
        record("pill hidden after click",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const el = document.querySelector('.bt-new-msg-pill');
                       return !el || !el.classList.contains('bt-new-msg-pill-visible');
                   })()
                   """; timeout = 2.0))
        record("unreadCount cleared",    @TH.test_eq unread() 0)
        # Scroll position should settle to the bottom — rAF can be
        # throttled under offscreen Electron load, so poll up to 2s.
        record("scroll gap < 50 after pill click (poll)",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const c = document.querySelector('.bt-messages');
                       return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                   })()
                   """; timeout = 2.0))
    end

    # ── 6. Scrolling back to the very bottom auto-re-engages ─────────────
    TH.section("Scrolling manually to the bottom auto-re-engages follow") do
        # First disengage.
        scroll_up_as_user!()
        @assert follow_mode() == false
        # Now simulate the user scrolling back down (via wheel + scrollTop
        # set to scrollHeight - clientHeight, which IS the bottom).
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = c.scrollHeight - c.clientHeight;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        sleep(0.4)
        record("followMode re-engaged by scrolling to bottom",
               @TH.test_eq follow_mode() true)
        record("pill hidden after auto-re-engage",
               @TH.test_eq pill_visible() false)
    end

    # ── 7. Sending a user message from scrollback does NOT auto-re-engage
    # Strict spec: "always stay at the position the user scrolls to". The
    # user's own bubble appears, the pill stays up (counts as unread),
    # and they have to click the pill (or scroll to the bottom) to come
    # back. The agent reply that arrives later is also held off-screen.
    TH.section("Sending a user message from scrollback stays in scrollback") do
        scroll_up_as_user!()
        @assert follow_mode() == false
        emit_agent_burst("burst-3", 4)
        sleep(0.4)
        @assert pill_visible() == true
        scroll_top_before = TH.eval_js(ctx,
            "document.querySelector('.bt-messages').scrollTop")
        TH.type_into(ctx, ".bt-text-input", "stay where I am")
        sleep(0.1)
        TH.dom_click(ctx, ".bt-send-btn")
        sleep(0.8)
        record("followMode still false after user send",
               @TH.test_eq follow_mode() false)
        record("pill still visible (unread count includes the send)",
               @TH.test_eq pill_visible() true)
        # ScrollTop shouldn't have changed materially — give a generous
        # tolerance for any scroll-anchoring adjustment that could shift
        # us when new bottom nodes get added.
        scroll_top_after = TH.eval_js(ctx,
            "document.querySelector('.bt-messages').scrollTop")
        record("scrollTop didn't jump to the bottom",
               @TH.test_true (abs(Int(scroll_top_after) -
                                  Int(scroll_top_before)) < 200))
    end

    # ── 8. No JS errors ──────────────────────────────────────────────────
    TH.section("No JS errors during the pill exercise") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_eq length(errs) 0)
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "follow-pill final")

finally
    TH.report!("Tier 2n — follow mode + new-message pill", results)
    TH.shutdown(ctx)
end
