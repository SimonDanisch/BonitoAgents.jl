# Ports the chat_close_rename e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:chat_close_rename" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "chat_close_rename.jl"))
    run_suite(SharedServer.server())
end
