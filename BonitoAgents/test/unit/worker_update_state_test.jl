# The update check must flag the worker that needs it most. A worker from
# before self-updating sends neither `auto_update` nor `update_spec`, and the
# old rule `auto_update && spec differs` showed exactly that worker as current
# and green (the Laptop worker, 2026-09-15). The decision is a pure function of
# the hello frame so it can be pinned here without a websocket.
@testitem "unit:worker_update_state" tags = [:unit] setup = [LinkPair] begin
    import BonitoAgents, HTTP
    const BT = BonitoAgents
    using Test

    spec = Dict("repo" => "https://github.com/SimonDanisch/BonitoAgents.jl", "rev" => "v0.3.0",
                "source_id" => "s1", "bonito_url" => "u", "bonito_rev" => "b")
    wire(d) = Dict{String,Any}(k => v for (k, v) in d)   # what JSON decoding yields

    legacy = Dict{String,Any}("secret" => "x", "name" => "Laptop", "hostname" => "localhost")
    st, msg = BT.worker_update_state(legacy, spec)
    @test st === :reinstall
    @test occursin("Reinstall", msg)

    # A current worker without a configured spec (a dev worker from a checkout)
    # cannot be judged and stays current.
    dev = Dict{String,Any}("auto_update" => false, "update_spec" => nothing)
    @test BT.worker_update_state(dev, spec) == (:current, "")

    same = Dict{String,Any}("auto_update" => true, "update_spec" => wire(spec))
    @test BT.worker_update_state(same, spec) == (:current, "")

    # Update feedback does not disappear after the replacement worker
    # reconnects. Every online state has a compact badge; offline cards keep
    # their existing offline pill and do not claim anything about freshness.
    badge = BT.worker_update_badge(true, :current)
    @test badge.label == "Up to date"
    @test occursin("bt-pill-online", badge.class)
    @test BT.worker_update_badge(true, :available, "new build").label == "Update available"
    @test BT.worker_update_badge(true, :reinstall, "too old").label == "Reinstall needed"
    @test isempty(BT.worker_update_badge(false, :current).label)
    @test occursin("bt-hidden", BT.worker_update_badge(false, :current).class)
    # A user could not tell an update in progress from one waiting for them or a
    # stuck one ("Updating…" with no motion, then "offline"). The steps that run
    # by themselves are `working` (a spinner and their time); the restart shows
    # while the worker is offline for it; a failure is red, not "available".
    for (st, label) in ((:requested, "Starting update"), (:installing, "Installing update"),
                        (:restarting, "Restarting"))
        b = BT.worker_update_badge(true, st, "msg")
        @test (b.label, b.working) == (label, true)
        @test occursin("bt-pill-syncing", b.class)
    end
    @test BT.worker_update_badge(false, :restarting).label == "Restarting"
    @test isempty(BT.worker_update_badge(false, :installing).label)
    @test BT.worker_update_badge(true, :waiting).label == "Update queued"
    @test !BT.worker_update_badge(true, :waiting).working
    @test occursin("bt-pill-error", BT.worker_update_badge(true, :failed).class)
    # Each note says whether anything is left to do.
    @test occursin("Nothing to do", BT.update_note(:installing))
    @test occursin("reconnects by itself", BT.update_note(:restarting))
    @test occursin("(2 running now)", BT.update_note(:waiting; busy = 2))
    @test !occursin("running now", BT.update_note(:waiting))       # a worker that sent no count
    @test occursin("Update now installs it right away", BT.update_note(:waiting; busy = 1))
    @test BT.update_note(:failed; error = "Pkg.add: no such rev.") ==
          "The update failed: Pkg.add: no such rev. The worker tries again in five minutes; Update now tries right away."
    @test occursin("cannot update itself: no update config.", BT.update_note(:reinstall; error = "no update config"))
    @test_throws ArgumentError BT.update_note(:dancing)

    older = Dict{String,Any}("auto_update" => true, "update_spec" => wire(merge(spec, Dict("rev" => "v0.2.0"))))
    st, msg = BT.worker_update_state(older, spec)
    @test st === :available
    @test occursin("Update now", msg)
    # A server that has not resolved its own build yet cannot judge either.
    @test BT.worker_update_state(older, nothing) == (:current, "")

    # Auto-update switched off does not make an outdated worker current.
    manual = Dict{String,Any}("auto_update" => false, "update_spec" => wire(merge(spec, Dict("rev" => "v0.2.0"))))
    st, msg = BT.worker_update_state(manual, spec)
    @test st === :available
    @test occursin("Auto-update is off", msg)

    # "Update now" means now: the worker cuts idle agent processes, so the one
    # thing the server refuses is a turn in flight, which only the server can
    # see. An open but idle chat is not "active work".
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    cwd = mktempdir()
    state.projects[]["proj"] = BT.ProjectInfo("proj", "name", "w1", cwd, cwd, BT.now(BT.UTC))
    model = BT.ChatModel(state, cwd; project_id = "proj", agent = BT.WorkerAgent(state, "w1", "/p"))
    state.chat_models["proj"] = model
    @test_throws BT.WorkerUnreachableError BT.force_worker_update!(state, "w1")  # not connected
    server_link, worker_link = link_pair()
    state.worker_links["w1"] = server_link
    @test !BT.worker_turn_in_flight(state, "w1")
    model.busy_active[] = true
    @test BT.worker_turn_in_flight(state, "w1")
    @test_throws ArgumentError BT.force_worker_update!(state, "w1")
    @test !BT.worker_turn_in_flight(state, "other-worker")

    # The card shows the worker's own account of an update, requested or its
    # own: queued behind its chats, installing, restarting, or failed with the
    # error. The time a step began comes from the worker, so a card rebuilt by a
    # reconnect keeps counting from then.
    state.workers[]["w1"] = BT.WorkerInfo("w1", "Desktop", nothing, "host", "/home/u",
                                          "julia", String[], "/home/u/projects", :online, BT.now(BT.UTC))
    w = state.workers[]["w1"]
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "waiting", "busy" => 3))
    @test w.update_state === :waiting
    @test occursin("(3 running now)", w.update_message)
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "installing", "elapsed" => 90.0))
    @test w.update_state === :installing
    @test occursin("Nothing to do", w.update_message)
    @test 89 < time() - w.update_since < 95
    # The badge's timer starts from there.
    html = sprint(show, BT.render_update_badge(w))
    @test occursin("bt-spinner", html) && occursin("Installing update", html)
    @test occursin("data-started=\"$(w.update_since)\"", html)
    @test occursin("1m30s", html)
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "restarting"))
    @test w.update_state === :restarting
    @test time() - w.update_since < 5                # a worker that sent no elapsed: from now
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "failed", "error" => "Pkg.add: no such rev."))
    @test w.update_state === :failed
    @test occursin("failed: Pkg.add: no such rev. The worker tries again", w.update_message)
    @test !occursin("bt-spinner", sprint(show, BT.render_update_badge(w)))
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "unsupported", "error" => "no update config"))
    @test w.update_state === :reinstall
    @test_logs (:warn, r"unknown status") match_mode=:any (@test !BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "dancing")))
    @test w.update_state === :reinstall              # unknown status changes nothing
    @test !BT.apply_update_status!(state, "nobody", Dict{String,Any}("status" => "installing"))

    # "Update now" shows as requested at once: set before the command goes out,
    # so the worker's answer lands after it instead of being overwritten.
    model.busy_active[] = false
    b = state.worker_build
    lock(() -> (b.spec = Dict{String,Any}(spec); b.tried_at = time()), b.lock)
    BT.force_worker_update!(state, "w1")
    @test w.update_state === :requested
    @test occursin("waiting for the worker", w.update_message)
    cmd = BT.decode_control(HTTP.WebSockets.receive(BT.WorkerLink.control_channel(worker_link)))
    @test (cmd["type"], cmd["immediate"], cmd["update_spec"]) == ("force_update", true, spec)
    BT.close_worker_links!(state)
    BT.WorkerLink.kill!(worker_link, "done")
end
