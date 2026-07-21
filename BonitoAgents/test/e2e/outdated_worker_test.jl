# An outdated (pre-v3) worker's eval result triggers the "update your worker"
# banner instead of a mangled card (see outdated_worker.jl).
@testitem "e2e:outdated_worker" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "outdated_worker.jl"))
    run_suite(SharedServer.server())
end
