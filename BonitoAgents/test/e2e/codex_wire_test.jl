# Tool cards must look the same whichever ACP agent produced them — driven with
# the mock speaking codex's dialect (no tool names anywhere, MCP calls wrapped in
# a server/tool/arguments envelope, every result out-of-band in `rawOutput`).
# See codex_wire.jl.
@testitem "e2e:codex_wire" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "codex_wire.jl"))
    run_suite(SharedServer.server())
end
