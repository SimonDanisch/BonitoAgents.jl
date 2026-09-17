# Its own dev_server AND its own 390×780 window: the shared browser is opened
# once at 1280×820, and `open_browser` sizes the window at open time, so the
# only way to see a phone layout is a window that was born one. See
# attach_mobile.jl's header.
@testitem "e2e:attach_mobile" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "attach_mobile.jl"))
    server = TestKit.dev_server()
    try
        TestKit.open_browser(server; width = 390, height = 780)
        run_suite(server)
    finally
        close(server)
    end
end
