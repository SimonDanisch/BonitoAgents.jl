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
    @test occursin("idle", msg)

    # Auto-update switched off does not make an outdated worker current.
    manual = Dict{String,Any}("auto_update" => false, "update_spec" => wire(merge(spec, Dict("rev" => "v0.2.0"))))
    st, msg = BT.worker_update_state(manual, spec)
    @test st === :available
    @test occursin("Auto-update is off", msg)
end
