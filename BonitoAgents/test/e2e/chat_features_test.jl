# Ports the chat_features e2e suite onto the shared soak server. The suite file
# defines `agent_script` + `run_suite(server)` and skips re-including TestKit
# when `TestKit` is already bound — so we bind SharedServer's TestKit (same
# module → same TestServer type) and drive the one shared server.
@testitem "e2e:chat_features" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "chat_features.jl"))
    run_suite(SharedServer.server())
end
