# @testitem wrapper for the worker-file-download regression. The suite lives in
# `file_download.jl` and drives `download_response` directly (no browser), so we
# just stand up a throwaway dev_server + worker and run it.
@testitem "e2e:file_download" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "file_download.jl"))
    server = TestKit.dev_server()
    try
        run_suite(server)
    finally
        close(server)
    end
end
