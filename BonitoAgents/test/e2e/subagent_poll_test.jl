# Deterministic subagent-pill completion via the transcript outputFile (fd-close),
# on the shared soak server. See subagent_poll.jl.
@testitem "e2e:subagent_poll" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "subagent_poll.jl"))
    run_suite(SharedServer.server())
end
