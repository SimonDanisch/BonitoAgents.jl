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

using Test, BonitoAgents, Dates
using BonitoAgents.Bonito.Observables: on, off
using BonitoAgents: ProjectInfo, WorkerInfo, ServerState, ChatModel, MockTransport,
                   open_chat_projects, chat_status, now, UTC

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
    model = ChatModel(state, mktempdir();
                       project_id = p.id,
                       transport  = MockTransport((o, i) -> nothing))
    @test model.busy_active[] == false
    state.chat_models[p.id] = model
    @test chat_status(state, p) === :online
end

@testset "chat_status — ChatModel busy_active=true → :active" begin
    state, p = make_env()
    model = ChatModel(state, mktempdir();
                       project_id = p.id,
                       transport  = MockTransport((o, i) -> nothing))
    state.chat_models[p.id] = model
    model.busy_active[] = true
    @test chat_status(state, p) === :active
    # And dropping back to idle returns to :online.
    model.busy_active[] = false
    @test chat_status(state, p) === :online
end

@testset "chat_status — worker offline beats busy_active" begin
    # If the worker goes offline while a chat says it's busy, the LED
    # should reflect the connectivity loss, not the stale busy flag.
    state, p = make_env(; worker_status = :offline)
    model = ChatModel(state, mktempdir();
                       project_id = p.id,
                       transport  = MockTransport((o, i) -> nothing))
    state.chat_models[p.id] = model
    model.busy_active[] = true
    @test chat_status(state, p) === :offline
end

# ── Reactive chain: busy_active → notify_chats! → sidebar status ────────────
# The sidebar LED is updated via `Bonito.onjs(session, status_obs, …)`. The
# `status_obs` is rebuilt on `chat_signal`, and the `ChatModel` constructor
# anchors an `on(busy_active) do _; notify_chats!(state); end` so a prompt
# going in-flight (or finishing) fans through the chain WITHOUT polling.
# We can't easily probe the live DOM from a unit test, but we CAN observe
# that `chat_signal` fires on `busy_active` flips — that's the only edge
# the sidebar's `onjs` needs to recompute. End-to-end DOM verification
# belongs in a real-browser e2e suite.

@testset "busy_active flips fan through chat_signal (no polling)" begin
    state, p = make_env()
    model = ChatModel(state, mktempdir();
                       project_id = p.id,
                       transport  = MockTransport((o, i) -> nothing))
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
    end
end
