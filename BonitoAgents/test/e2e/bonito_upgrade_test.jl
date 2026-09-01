# Version-mismatch upgrade card: a display value on a too-old-Bonito env shows the
# one-click [Update env] card, and clicking it submits the Pkg.add (see
# bonito_upgrade.jl).
@testitem "e2e:bonito_upgrade" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "bonito_upgrade.jl"))
    run_suite(SharedServer.server())
end
