# Regression test: new messages must appear in the DOM even when
# `requestAnimationFrame` is paused (backgrounded browser tab / window).
#
# Background: Chrome + Firefox pause rAF in backgrounded tabs (no callbacks
# fire). Earlier `appendNewMessage` queued its auto-scroll via
# `_queueScrollToBottom` → rAF. While the tab was backgrounded, new messages
# went into `__bt_chat.cache` but never into the DOM, because:
#
#   1. `updateDOM` had been called with the *pre-scroll* visibleRange,
#      which didn't include the new (bottom-of-content) bubble's index.
#   2. The rAF that was supposed to scroll to bottom + re-update never fired.
#
# When the user finally re-focused the tab, the queued rAF fired and all
# the cached-but-invisible bubbles appeared "instantly" — manifesting in
# the wild as "I sent a message and 5 old replies appeared at once".
#
# The fix replaces rAF batching in `appendNewMessage` with a synchronous
# `scrollToBottom()` (which itself calls `refresh()` → `updateDOM` with
# the post-scroll visible range). Synchronous DOM/scroll writes work
# regardless of tab visibility.
#
# This test reproduces the stuck-rAF condition by manually setting
# `_scrollQueued = true` and `_scrollRafId = -1` (a state a real
# backgrounded tab gets stuck in), then exercises `appendNewMessage`
# and asserts the new bubble lands in the DOM.

isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents, Bonito, JSON, Dates
import ElectronCall

const TH_ALIAS = TH

# We need a real `serve()` because the test exercises the full Bonito
# session + WS round-trip. Inline the fresh_state helper from
# test_chat_stress (kept local; same shape).
function fresh_state_(project_ids::Vector{String})
    state = BonitoAgents.serve(;
        host = "127.0.0.1", port = 0,
        worker_secret = "x",
        state_dir = mktempdir(),
        working_dir = mktempdir())
    state.workers[]["w1"] = BonitoAgents.WorkerInfo("w1", "Tester", "<inbound-ws>",
        "x", nothing, "h", "/h", "", String[], "/p", :online, now(UTC))
    notify(state.workers)
    models = Dict{String, BonitoAgents.ChatModel}()
    for pid in project_ids
        state.projects[][pid] = BonitoAgents.ProjectInfo(pid, pid, "w1",
            mktempdir(), mktempdir(), now(UTC))
        m = BonitoAgents.ChatModel(state, mktempdir(); project_id = pid)
        state.chat_models[pid] = m
        models[pid] = m
    end
    notify(state.projects)
    return state, models
end

function open_window_(state)
    app = ElectronCall.Application()
    win = ElectronCall.Window(app, ElectronCall.URI(Bonito.online_url(state.srv, ""));
        options = Dict{String,Any}("show" => false, "focusOnWebView" => false,
                                    "width" => 1280, "height" => 800))
    sleep(2.5)
    return (; app, win)
end

function wait_for_(win, predicate; timeout = 8.0)
    deadline = time() + timeout
    while time() < deadline
        try
            ElectronCall.run(win, "(() => { return ($predicate); })()") === true && return true
        catch end
        sleep(0.1)
    end
    return false
end

state, models = fresh_state_(["bg-tab"])
model = models["bg-tab"]
TH.seed_chat_history!(model, 5)   # have some history so virtual-scroll is engaged

w = open_window_(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    ElectronCall.run(w.win, """
        (() => {
            const el = document.querySelector('.bt-side-item[data-project-id="bg-tab"]');
            if (el) el.click();
        })()
    """)
    @assert wait_for_(w.win, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"
    @assert wait_for_(w.win,
        "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 10";
        timeout = 8) "history didn't load"

    TH.section("Backgrounded-tab rAF pause: new bubble still lands in DOM") do
        # Force rAF into the "queued-but-never-fires" state — the exact
        # condition a real backgrounded tab leaves the chat in. Cancel any
        # REAL chase rAF still in flight from the initial mount first:
        # planting `_scrollRafId = -1` over a live id leaves that callback
        # scheduled, and when it fires it clears `_scrollQueued` — the
        # sentinel assertion below then fails on a pure timing race.
        ElectronCall.run(w.win, """
            (() => {
                const c = document.querySelector('.bt-messages').__bt_chat;
                c._cancelPendingScroll();
                c._scrollQueued = true;
                c._scrollRafId  = -1;
                return true;
            })()
        """)

        before_bubbles = ElectronCall.run(w.win,
            "document.querySelectorAll('.bt-agent-msg, .bt-user-msg').length")
        before_total = ElectronCall.run(w.win,
            "document.querySelector('.bt-messages').__bt_chat.totalCount")

        # Push 3 fresh agent messages server-side. With the rAF stuck,
        # the pre-fix code would never insert them into the DOM.
        for i in 1:3
            BonitoAgents.send!(model,
                BonitoAgents.AgentMsg("bg-test-$i",
                    "background-tab message $i — should appear despite paused rAF"))
        end
        sleep(0.4)

        after_total = ElectronCall.run(w.win,
            "document.querySelector('.bt-messages').__bt_chat.totalCount")
        after_bubbles = ElectronCall.run(w.win,
            "document.querySelectorAll('.bt-agent-msg, .bt-user-msg').length")
        rAF_state = ElectronCall.run(w.win,
            "document.querySelector('.bt-messages').__bt_chat._scrollQueued")

        record("totalCount went up by 3",
            @TH.test_eq (after_total - before_total) 3)
        # The crux: bubbles in the DOM (the bug was bubbles staying cached
        # but not rendered). We don't require ALL 3 to be visible — virtual
        # scroll may only render some — but at least the last one should be
        # in the DOM since it's at the bottom of content and followMode is on.
        record("DOM bubble count grew (bubbles aren't stuck in cache)",
            @TH.test_true (after_bubbles > before_bubbles))
        # rAF is STILL stuck — we never let it fire. So if the bubbles are
        # in DOM, it's because the synchronous code path put them there.
        record("rAF queue still stuck (proves the fix didn't depend on rAF)",
            @TH.test_true (rAF_state === true))

        # The last bubble's text should be the LAST message we pushed.
        last_text = ElectronCall.run(w.win, """
            (() => {
                const b = document.querySelectorAll('.bt-agent-msg');
                return b.length > 0 ? b[b.length - 1].innerText : '';
            })()
        """)
        record("last DOM bubble has the most recent push's text",
            @TH.test_true occursin("background-tab message 3", String(last_text)))
    end
finally
    TH.report!("Tier — backgrounded-tab rAF", results)
    try close(w.win) catch end
    try close(w.app) catch end
    try close(state.srv) catch end
end
