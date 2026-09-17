# The update check must flag the worker that needs it most. A worker from
# before self-updating sends neither `auto_update` nor `update_spec`, and the
# old rule `auto_update && spec differs` showed exactly that worker as current
# and green (the Laptop worker, 2026-09-15). The decision is a pure function of
# the hello frame so it can be pinned here without a websocket.
@testitem "unit:worker_update_state" tags = [:unit] begin
    import BonitoAgents
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

    older = Dict{String,Any}("auto_update" => true, "update_spec" => wire(merge(spec, Dict("rev" => "v0.2.0"))))
    st, msg = BT.worker_update_state(older, spec)
    @test st === :available
    @test occursin("Update now", msg)

    # Auto-update switched off does not make an outdated worker current.
    manual = Dict{String,Any}("auto_update" => false, "update_spec" => wire(merge(spec, Dict("rev" => "v0.2.0"))))
    st, msg = BT.worker_update_state(manual, spec)
    @test st === :available
    @test occursin("Auto-update is off", msg)

    # "Update now" means now: the worker cuts idle agent processes, so the one
    # thing the server refuses is a turn in flight, which only the server can
    # see. An open but idle chat is not "active work".
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    cwd = mktempdir()
    state.projects[]["proj"] = BT.ProjectInfo("proj", "name", "w1", cwd, cwd, BT.now(BT.UTC))
    model = BT.ChatModel(state, cwd; project_id = "proj", agent = BT.WorkerAgent(state, "w1", "/p"))
    state.chat_models["proj"] = model
    @test_throws BT.WorkerUnreachableError BT.force_worker_update!(state, "w1")  # not connected
    state.worker_control_ws["w1"] = nothing
    @test !BT.worker_turn_in_flight(state, "w1")
    model.busy_active[] = true
    @test BT.worker_turn_in_flight(state, "w1")
    @test_throws ArgumentError BT.force_worker_update!(state, "w1")
    @test !BT.worker_turn_in_flight(state, "other-worker")

    # The card shows the worker's own account of a requested update: installing,
    # waiting for idle, or failed with the error. A failure returns the worker
    # to `:available`, so the button comes back instead of "Updating" for ever.
    state.workers[]["w1"] = BT.WorkerInfo("w1", "Desktop", "ws://x", "x", nothing, "host", "/home/u",
                                          "julia", String[], "/home/u/projects", :online, BT.now(BT.UTC))
    w = state.workers[]["w1"]
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "installing"))
    @test w.update_state === :updating
    @test occursin("restarts and reconnects", w.update_message)
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "waiting"))
    @test w.update_state === :updating
    @test occursin("once no chat runs", w.update_message)
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "failed", "error" => "Pkg.add: no such rev."))
    @test w.update_state === :available
    @test occursin("failed on the worker: Pkg.add: no such rev. It retries", w.update_message)
    @test BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "unsupported", "error" => "no update config"))
    @test w.update_state === :reinstall
    @test_logs (:warn, r"unknown status") match_mode=:any (@test !BT.apply_update_status!(state, "w1", Dict{String,Any}("status" => "dancing")))
    @test w.update_state === :reinstall              # unknown status changes nothing
    @test !BT.apply_update_status!(state, "nobody", Dict{String,Any}("status" => "installing"))
end
