# An Edit card keeps its diff instead of rendering the terminal "updated
# successfully" rawOutput (see edit_diff.jl).
@testitem "e2e:edit_diff" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "edit_diff.jl"))
    run_suite(SharedServer.server())
end
