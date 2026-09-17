# A chat's bring-up finishing must not re-broadcast `current_view`. The overlay
# used to be kicked with `safe_notify!(current_view)`, which also ships the pid
# to the browser; a user who clicked Home while the bring-up ran had set "" on
# their side (never echoed back), so the late pid re-opened the chat on screen
# while the server said Home. `e2e:header_collapse` hit exactly that between its
# two chats. The overlay now re-renders off `LoadingState.settled`.
@testitem "unit:loading_settled" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    using Dates
    const BT = BonitoAgents

    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                          worker_secret = "x")
    # An "online" worker with no control socket: the bring-up registers the
    # chat model for real and its session start fails fast (swallowed by
    # `restart_chat_session!`, which keeps the chat object), so the loading
    # view's completion path runs without any worker.
    st.workers[]["wid-a"] = BT.WorkerInfo("wid-a", "Desktop", "ws://x", "x", nothing,
                                          "Desktop-host", "/home/u", "julia", String[],
                                          "/home/u/projects/Desktop", :online, now())
    st.projects[]["p1"] = BT.ProjectInfo("p1", "proj", "wid-a",
                                         joinpath(st.working_dir, "proj"),
                                         "/home/u/projects/Desktop/proj", now(UTC))

    session = Bonito.Session()
    current_view = Observable("")
    ls = BT.LoadingState()
    seen = String[]
    on(v -> push!(seen, v), current_view)
    BT.unified_main(session, st, current_view, ls)

    current_view[] = "p1"    # the loading overlay spawns the bring-up
    current_view[] = ""      # …and the user goes Home while it runs
    deadline = time() + 30
    while (("p1" in ls.inflight) || ls.settled[] == 0) && time() < deadline
        sleep(0.05)
    end
    @test !("p1" in ls.inflight)
    @test ls.settled[] >= 1                 # the overlay was told to re-render
    @test haskey(st.chat_models, "p1")      # the bring-up completed
    @test seen == ["p1", ""]                # the navigation observable was NOT re-broadcast
    @test current_view[] == ""
end
