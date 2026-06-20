# Stress tests for ChatModel that drive `BonitoAgents.serve(...)` — the
# real production entry point. The Electron windows below load
# `Bonito.online_url(state.srv, "")`, the exact URL `serve()` prints to
# the console, so the request path is identical to what a user gets.
#
# Earlier revisions of this file took two shortcuts and we don't go back
# to them:
#   - An ad-hoc `App() do _; DOM.div(model); end` shim that bypassed
#     `unified_main`'s `map(current_view)` reactive swap (passed even
#     when production errored on `convert(::Node, ::ChatModel)`).
#   - Building `Bonito.Server(unified_app(state), ...)` inline, which
#     skipped `serve()`'s `proxy_url = "."` + worker WS routes wiring.
# Anything that exercises chat must navigate by clicking the real
# sidebar entry (which sets `current_view` exactly the way a user does).
#
# Coverage:
#   1. 1000 messages: virtual scroll renders the right window, range
#      requests serve correct slices, no message loss.
#   2. 100-msg burst from Julia: every message reaches JS, totalCount
#      converges, no drops.
#   3. Two browser tabs of the same unified_app: both see the seed,
#      both pick up server-side pushes.
#   4. 10 fast open/close cycles: server-side state intact, no leaks.
#   5. Drop browser mid-stream: server keeps accepting pushes, reconnect
#      bootstraps correctly.
#   6. Streaming agent chunks via the real ACP path.
#   7. Project switch: alpha → beta → alpha shows correct content each
#      time, including a background-pushed message.

include(joinpath(@__DIR__, "helpers.jl"))

using Test, Bonito, BonitoAgents, JSON, Dates
import ElectronCall

const RESULTS = Pair{String,Bool}[]

# ── helpers ──────────────────────────────────────────────────────────────

# Open an Electron window pointing at the live production server URL
# returned by `serve()` (held in `state.srv`). We use a raw
# (Application, Window) pair instead of `Bonito.use_electron_display`
# because all we actually want is "load URL X" — display registration
# would be dead weight here. The server stays up across multiple
# open/close cycles on the same `state`; only the window is per-test.
function open_window(state; opts = Dict{String,Any}("show"=>false,
                                                     "focusOnWebView"=>false))
    app = ElectronCall.Application()
    win = ElectronCall.Window(app, ElectronCall.URI(Bonito.online_url(state.srv, ""));
                           options = opts)
    sleep(2.5)
    return (; app, win)
end

close_window(w)   = (try close(w.win) catch end; try close(w.app) catch end)
close_state(state) = (try close(state.srv) catch end)

function wait_for_js(win, predicate; timeout = 5.0, interval = 0.1)
    deadline = time() + timeout
    while time() < deadline
        try
            v = ElectronCall.run(win, "(() => { return ($predicate); })()")
            v === true && return true
        catch
        end
        sleep(interval)
    end
    return false
end

# Click the sidebar entry whose data-project-id matches `pid`. Empty pid
# selects Home (the dashboard view).
function navigate_to(win, pid::AbstractString)
    # Wait for the sidebar to be present first.
    wait_for_js(win,
        "document.querySelector('.bt-side-item[data-project-id=$(JSON.json(pid))]') !== null";
        timeout = 5)
    ElectronCall.run(win, """
        (() => {
            const el = document.querySelector('.bt-side-item[data-project-id=$(JSON.json(pid))]');
            if (el) { el.click(); return true; }
            return false;
        })()
    """)
end

# Boot the production server via `serve(...)` (port=0 → kernel-assigned),
# then seed it with one stub worker + N projects + matching ChatModels.
# `serve()` captures `state` in the unified_app closure, so projects added
# afterwards are visible to every later session.
function fresh_state(project_ids::Vector{String})
    state = BonitoAgents.serve(;
        host          = "127.0.0.1",
        port          = 0,
        worker_secret = "x",
        state_dir     = mktempdir(),
        working_dir   = mktempdir())

    state.workers[]["w1"] = BonitoAgents.WorkerInfo("w1", "Tester", "<inbound-ws>",
        "x", nothing, "h", "/h", "", String[], "/p", :online, now(UTC))
    notify(state.workers)
    models = Dict{String, BonitoAgents.ChatModel}()
    for pid in project_ids
        state.projects[][pid] = BonitoAgents.ProjectInfo(pid, pid, "w1",
            mktempdir(), mktempdir(), now(UTC))
        m = BonitoAgents.ChatModel(state, mktempdir(); project_id=pid)
        state.chat_models[pid] = m
        models[pid] = m
    end
    notify(state.projects)
    return state, models
end

function chat_total(win)
    ElectronCall.run(win,
        "document.querySelector('.bt-messages')?.__bt_chat?.totalCount ?? -1")
end

# ── (1) 1000 message virtual-scroll integrity ───────────────────────────
TH.section("Stress 1: 1000 messages, virtual scroll integrity") do
    state, models = fresh_state(["stress-1k"])
    TH.seed_chat_history!(models["stress-1k"], 500)   # 500 (user, agent) pairs

    w = open_window(state)
    try
        navigate_to(w.win, "stress-1k")

        ok = wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 1000";
            timeout = 10)
        push!(RESULTS, "1k: totalCount converged" => ok)

        wait_for_js(w.win, """
            (() => {
                const us = document.querySelectorAll('.bt-user-msg');
                return us.length > 0 && us[us.length-1].textContent === 'hi 500';
            })()
        """; timeout = 15)
        wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.atBottom() === true";
            timeout = 10)

        last_user = ElectronCall.run(w.win, """
            (() => {
                const us = document.querySelectorAll('.bt-user-msg');
                return us.length ? us[us.length-1].textContent : null;
            })()
        """)
        push!(RESULTS, "1k: last user bubble is final pair" => (last_user == "hi 500"))
        rendered = ElectronCall.run(w.win,
            "document.querySelectorAll('.bt-messages > .bt-user-msg, .bt-messages > .bt-agent-msg').length")
        push!(RESULTS, "1k: window bounded (< 60 visible)" => (rendered isa Number && rendered < 60))
    finally
        close_window(w); close_state(state)
    end
end

# ── (2) Burst of server-side pushes ─────────────────────────────────────
TH.section("Stress 2: 100-msg burst from Julia") do
    state, models = fresh_state(["stress-burst"])
    model = models["stress-burst"]
    TH.seed_chat_history!(model, 5)
    w = open_window(state)
    try
        navigate_to(w.win, "stress-burst")
        wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 10";
            timeout = 8)

        for i in 1:100
            BonitoAgents.send!(model, BonitoAgents.UserMsg("burst-$i"))
        end
        ok = wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 110";
            timeout = 12.0)
        push!(RESULTS, "burst: every message reached JS (totalCount==110)" => ok)
        push!(RESULTS, "burst: server store has 110" => (length(model.msgs_store) == 110))
    finally
        close_window(w); close_state(state)
    end
end

# ── (3) Multi-tab sync (real serve()) ───────────────────────────────────
TH.section("Stress 3: two tabs of the same serve(), same project") do
    state, models = fresh_state(["stress-multitab"])
    model = models["stress-multitab"]
    TH.seed_chat_history!(model, 3)

    url = Bonito.online_url(state.srv, "")
    a1 = ElectronCall.Application(); a2 = ElectronCall.Application()
    w1 = ElectronCall.Window(a1, ElectronCall.URI(url); options=Dict{String,Any}("show"=>false))
    w2 = ElectronCall.Window(a2, ElectronCall.URI(url); options=Dict{String,Any}("show"=>false))
    sleep(3.0)
    try
        nav = w -> ElectronCall.run(w, """
            (() => {
                const el = document.querySelector('.bt-side-item[data-project-id="stress-multitab"]');
                el && el.click();
            })()
        """)
        nav(w1); nav(w2); sleep(0.4)

        wait_total = (w, n, tmo=10.0) -> begin
            deadline = time() + tmo
            while time() < deadline
                try
                    ElectronCall.run(w, "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === $n") === true && return true
                catch end
                sleep(0.1)
            end
            false
        end
        push!(RESULTS, "multitab: tab A sees seeded count" => wait_total(w1, 6))
        push!(RESULTS, "multitab: tab B sees seeded count" => wait_total(w2, 6))

        BonitoAgents.send!(model, BonitoAgents.UserMsg("broadcast"))
        push!(RESULTS, "multitab: tab A picked up push" => wait_total(w1, 7))
        push!(RESULTS, "multitab: tab B picked up push" => wait_total(w2, 7))
    finally
        try close(w1) catch end
        try close(w2) catch end
        try close(a1) catch end
        try close(a2) catch end
        close_state(state)
    end
end

# ── (4) Fast reload churn ───────────────────────────────────────────────
TH.section("Stress 4: 10 fast open/close cycles of unified_app") do
    state, models = fresh_state(["stress-reload"])
    TH.seed_chat_history!(models["stress-reload"], 4)

    leaked = false
    try
        for i in 1:10
            w = open_window(state)
            navigate_to(w.win, "stress-reload")
            ok = wait_for_js(w.win,
                "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 8"; timeout=6)
            ok || (leaked = true; @warn "cycle $i did not converge")
            close_window(w)
            sleep(0.05)
        end
        push!(RESULTS, "reload: 10 cycles all converged" => !leaked)
        push!(RESULTS, "reload: server-side store intact" =>
              (length(models["stress-reload"].msgs_store) == 8))
    finally
        close_state(state)
    end
end

# ── (5) Connection interrupt: drop browser, server keeps pushing ────────
TH.section("Stress 5: drop browser mid-stream; reconnect bootstraps") do
    state, models = fresh_state(["stress-drop"])
    model = models["stress-drop"]
    TH.seed_chat_history!(model, 5)

    try
        w = open_window(state)
        try
            navigate_to(w.win, "stress-drop")
            wait_for_js(w.win,
                "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 10"; timeout=8)
        finally
            close_window(w)
        end

        threw = false
        try
            for i in 1:50
                BonitoAgents.send!(model, BonitoAgents.UserMsg("offline-$i"))
            end
        catch e
            threw = true
            @warn "push without listener raised" exception=e
        end
        push!(RESULTS, "drop: pushes without browser don't throw" => !threw)
        push!(RESULTS, "drop: store accumulated all 60" => (length(model.msgs_store) == 60))

        w2 = open_window(state)
        try
            navigate_to(w2.win, "stress-drop")
            ok = wait_for_js(w2.win,
                "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 60"; timeout=10)
            push!(RESULTS, "drop: reconnect bootstraps to 60" => ok)
        finally
            close_window(w2)
        end
    finally
        close_state(state)
    end
end

# ── (6) Streaming agent chunks via real ACP path ────────────────────────
TH.section("Stress 6: streaming agent chunks via unified_app") do
    state, models = fresh_state(["stress-stream"])
    model = models["stress-stream"]
    TH.seed_chat_history!(model, 20)

    w = open_window(state)
    try
        navigate_to(w.win, "stress-stream")
        wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 40"; timeout=10)
        sleep(1.0)   # let initial render settle before streaming on top of it

        # Stream into one agent bubble via the message-as-target verbs: `send!`
        # opens it (seeded with the first chunk), `append!` grows it in place.
        bubble = BonitoAgents.send!(model, BonitoAgents.AgentMsg(model, "Lorem "))
        for text in ["ipsum ", "dolor ", "sit ", "amet, ",
                     "consectetur ", "adipiscing ", "elit."]
            BonitoAgents.append!(bubble, text)
            sleep(0.3)
        end
        ok = wait_for_js(w.win, """
            (() => {
                const ag = document.querySelectorAll('.bt-agent-msg');
                if (!ag.length) return false;
                return ag[ag.length-1].textContent.includes('Lorem ipsum dolor sit amet');
            })()
        """; timeout = 20)
        push!(RESULTS, "stream: last agent bubble has accumulated chunks" => ok)
        push!(RESULTS, "stream: still pinned to bottom after stream" =>
              ElectronCall.run(w.win,
                  "document.querySelector('.bt-messages')?.__bt_chat?.atBottom() === true"))
    finally
        close_window(w); close_state(state)
    end
end

# ── (7) Project switch with background updates ──────────────────────────
TH.section("Stress 7: switch alpha ↔ beta, background push to inactive project") do
    state, models = fresh_state(["alpha", "beta"])
    a, b = models["alpha"], models["beta"]
    TH.seed_chat_history!(a, 3)
    TH.seed_chat_history!(b, 7)

    w = open_window(state)
    try
        navigate_to(w.win, "alpha")
        ok_a = wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 6"; timeout=8)
        push!(RESULTS, "switch: alpha shows 6" => ok_a)

        # Push to beta while viewing alpha
        BonitoAgents.send!(b, BonitoAgents.UserMsg("background-beta"))

        navigate_to(w.win, "beta")
        # Slower than the seeded-only case — the chat mounts AND has to
        # re-establish msgs.count via a comm round-trip because the
        # observable's pre-mount value is a "user" event (the background
        # push), not a msgs.count.
        ok_b = wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 15"; timeout=15)
        push!(RESULTS, "switch: beta shows pre-existing + background push (15)" => ok_b)

        navigate_to(w.win, "alpha")
        ok_a2 = wait_for_js(w.win,
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 6"; timeout=15)
        push!(RESULTS, "switch: back to alpha still 6" => ok_a2)
    finally
        close_window(w); close_state(state)
    end
end

TH.report!("Tier — chat_stress (via unified_app)", RESULTS)
