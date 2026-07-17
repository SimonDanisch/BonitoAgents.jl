# Live embeds must survive a browser page reload (see app_reload.jl).
@testitem "e2e:app_reload" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "app_reload.jl"))
    run_suite(SharedServer.server())
end
