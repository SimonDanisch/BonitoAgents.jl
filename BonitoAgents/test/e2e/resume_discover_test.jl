# Ports the discover → Resume → chat e2e orphan (the resume/discovery gap that
# had no e2e equivalent) onto the harness; isolated dev_server.
@testitem "e2e:resume_discover" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "test_resume_discover_e2e.jl"))
end
