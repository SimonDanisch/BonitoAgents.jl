# Headless BonitoMCP RemoteProxy ↔ BonitoAgents EvalBridge bridge test, run from
# here (RemoteProxy is a path-source dep of this test env). Sourced from
# BonitoMCP's own test file so there's a single copy.
@testitem "unit:remote_proxy" tags = [:unit] begin
    include(joinpath(@__DIR__, "..", "..", "..", "BonitoMCP", "test", "test_remote_proxy.jl"))
end
