# A returned App that errors at render surfaces the error in the result (probe
# render + errored descriptor), see render_error.jl.
@testitem "e2e:render_error" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "render_error.jl"))
    run_suite(SharedServer.server())
end
