# Sidebar's unified "Open chats" list + per-entry LED status.
#
# `open_chat_projects` decides which projects appear. A project is "open"
# iff the user has interacted with it (title backfilled OR resume_session_id
# imported from claude-agent-acp). Both markers persist in projects.json,
# so the list survives server AND worker restarts — no more sidebar going
# empty when you bounce the server.
#
# `chat_status` computes the LED state used by the sidebar:
#   :offline — worker isn't online OR isn't registered
#   :online  — worker up, no agent turn in flight (resumable OR idle live chat)
#   :active  — busy_active==true on a live ChatModel (claude is thinking)
#
# TestKit migration. `MockTransport`/`transport=` is deleted; the live `ChatModel`s
# below bind a no-op `MockAgent([])` (a pure state holder — none of these tests
# drive a turn). Split per the migration rule:
#
#   * `open_chat_projects` / `chat_status` are pure functions over `ServerState`
#     → DIRECT unit tests (no DOM, no agent).
#   * the busy_active → chat_signal fan-out is a pure Observable edge → unit test.
#   * the FULL LED reactive chain ("user sees the LED change") IS drivable end to
#     end, so it's a real-stack TestKit DOM e2e: flip the live chat's
#     `busy_active` and assert the sidebar `.bt-side-led` swaps its `data-status`
#     (online → active → online) in the browser.

using Test, BonitoAgents, Dates
using BonitoAgents.Bonito.Observables: on, off
using BonitoAgents: ProjectInfo, WorkerInfo, ServerState, ChatModel, MockAgent,
                   open_chat_projects, chat_status, now, UTC

include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit
const TK = TestKit
using .TestKit: text, end_turn

mk_project(id, wid; title=nothing, resume=nothing) = begin
    p = ProjectInfo(id, id, wid, "/srv/$id", "/w/$id", now(UTC))
    p.title             = title
    p.resume_session_id = resume
    p
end
mk_worker(wid; status::Symbol = :online) = WorkerInfo(
    wid, "name-$wid", "ws://w", "secret", "u@h",
    "host", "/home", "julia", String[], "/proj",
    status, now(UTC))

# A live ChatModel bound to a no-op MockAgent (the deleted MockTransport's
# replacement). None of these tests drive a turn, so the agent never spawns the
# mock binary — it's a pure state holder so the ChatModel ctor can bind.
mk_model(state, p) = ChatModel(state, mktempdir(); project_id = p.id, agent = MockAgent([]))

@testset "open_chat_projects — only persisted-interacted projects" begin
    projects = Dict(
        "p-pristine" => mk_project("p-pristine", "wA"),
        "p-titled"   => mk_project("p-titled",   "wA"; title  = "Why is the sky blue?"),
        "p-resumed"  => mk_project("p-resumed",  "wA"; resume = "abc-def"),
        "p-both"     => mk_project("p-both",     "wA"; title  = "x", resume = "y"),
    )
    out = open_chat_projects(projects)
    ids = Set(p.id for p in out)

    @test "p-pristine" ∉ ids   # never interacted
    @test "p-titled"   in ids   # title backfilled
    @test "p-resumed"  in ids   # imported claude session
    @test "p-both"     in ids
end

# Build a real ServerState with a worker + a project. Returns (state, p) so the
# tests can mutate p.title / worker.status / chat_models freely and re-probe.
function make_env(; worker_status::Symbol = :online,
                    title = "x", resume = nothing)
    state = ServerState(; state_dir = mktempdir(),
                          working_dir = mktempdir(),
                          worker_secret = "x")
    w = mk_worker("wA"; status = worker_status)
    state.workers[]["wA"] = w
    p = mk_project("p1", "wA"; title = title, resume = resume)
    state.projects[][p.id] = p
    return state, p
end

@testset "chat_status — worker offline → :offline" begin
    state, p = make_env(; worker_status = :offline)
    @test chat_status(state, p) === :offline
end

@testset "chat_status — worker missing from registry → :offline" begin
    state, p = make_env()
    delete!(state.workers[], "wA")   # worker was removed
    @test chat_status(state, p) === :offline
end

@testset "chat_status — worker online, no ChatModel → :online" begin
    state, p = make_env()
    @test !haskey(state.chat_models, p.id)
    @test chat_status(state, p) === :online
end

@testset "chat_status — ChatModel exists, idle → :online" begin
    state, p = make_env()
    model = mk_model(state, p)
    @test model.busy_active[] == false
    state.chat_models[p.id] = model
    @test chat_status(state, p) === :online
    close(model)
end

@testset "chat_status — ChatModel busy_active=true → :active" begin
    state, p = make_env()
    model = mk_model(state, p)
    state.chat_models[p.id] = model
    model.busy_active[] = true
    @test chat_status(state, p) === :active
    # And dropping back to idle returns to :online.
    model.busy_active[] = false
    @test chat_status(state, p) === :online
    close(model)
end

@testset "chat_status — worker offline beats busy_active" begin
    # If the worker goes offline while a chat says it's busy, the LED
    # should reflect the connectivity loss, not the stale busy flag.
    state, p = make_env(; worker_status = :offline)
    model = mk_model(state, p)
    state.chat_models[p.id] = model
    model.busy_active[] = true
    @test chat_status(state, p) === :offline
    close(model)
end

# ── Reactive chain: busy_active → notify_chats! → chat_signal ────────────────
# The sidebar LED is updated via `Bonito.onjs(session, status_obs, …)`. The
# `status_obs` is rebuilt on `chat_signal`, and the `ChatModel` constructor
# anchors an `on(busy_active) do _; notify_chats!(state); end` so a prompt
# going in-flight (or finishing) fans through the chain WITHOUT polling. This
# unit test asserts the server-side edge (`chat_signal` fires on every
# `busy_active` flip); the DOM e2e below asserts the browser-side tail (the LED
# attribute actually swaps).

@testset "busy_active flips fan through chat_signal (no polling)" begin
    state, p = make_env()
    model = mk_model(state, p)
    state.chat_models[p.id] = model

    bumps = Ref(0)
    listener = on(state.chat_signal) do _; bumps[] += 1; end
    try
        # Each `busy_active[] = …` notify (Observables fire on every set,
        # regardless of value equality) MUST fan through to `chat_signal`.
        # That's what lets the sidebar's `onjs` see a fresh status without
        # any polling. The downstream JS is a no-op when the data-status
        # hasn't actually changed, so the extra-bump-on-same-value is free.
        before = bumps[]
        model.busy_active[] = true
        @test bumps[] == before + 1
        model.busy_active[] = false
        @test bumps[] == before + 2
        model.busy_active[] = true
        @test bumps[] == before + 3
    finally
        off(state.chat_signal, listener)
        close(model)
    end
end

# ── DOM e2e: the LED reactive chain end-to-end (user sees the LED change) ─────
# Real dev_server + worker + browser. Create a chat (its sidebar row carries a
# `.bt-side-led`), then flip the LIVE shared ChatModel's `busy_active` and watch
# the LED's `data-status` swap online → active → online in the DOM — the exact
# chain `busy_active → notify_chats! → chat_signal → status_obs → onjs` drives.
@testset "sidebar LED reflects busy_active live (DOM)" begin
    s = TK.dev_server(; agent = _msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1100, height = 760)
        pid = TK.new_chat(s; cwd = mktempdir(), title = "LedChat")
        led_sel = ".bt-side-item[data-project-id=\"$pid\"] .bt-side-led"

        # The sidebar row renders its LED, idle → online.
        @test TK.wait_for(s, "LED present + online",
            "(() => { const e=document.querySelector('$led_sel'); return e && e.dataset.status === 'online'; })()";
            timeout = 15) == true

        # Flip the LIVE shared ChatModel busy → the LED must turn active.
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        model.busy_active[] = true
        @test TK.wait_for(s, "LED active",
            "(() => { const e=document.querySelector('$led_sel'); return e && e.dataset.status === 'active'; })()";
            timeout = 8) == true

        # Drop back to idle → the LED returns to online.
        model.busy_active[] = false
        @test TK.wait_for(s, "LED back online",
            "(() => { const e=document.querySelector('$led_sel'); return e && e.dataset.status === 'online'; })()";
            timeout = 8) == true

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
