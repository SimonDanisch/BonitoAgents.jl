# Ports the bt_eval e2e orphan (real bt_julia_eval through the dispatcher, its
# own isolated dev_server) onto the harness.
@testitem "e2e:bt_eval" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "test_bt_eval_e2e.jl"))
end
