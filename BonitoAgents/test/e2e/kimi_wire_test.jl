# Tool cards must look the same whichever ACP agent produced them — driven with
# the mock speaking kimi's dialect (no `_meta`, name only in the opening title,
# arguments streamed as content). See kimi_wire.jl.
@testitem "e2e:kimi_wire" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "kimi_wire.jl"))
    run_suite(SharedServer.server())
end
