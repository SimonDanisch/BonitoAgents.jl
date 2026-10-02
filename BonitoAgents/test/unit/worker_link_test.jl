# The worker's ONE connection: a WorkerLink between BonitoWorker and the server.
#
# `LinkPair` gives unit tests a connected server/client link without a server:
# register the server end in `state.worker_links` and the worker counts as
# connected, and whatever the server sends arrives on the client end.
@testsetup module LinkPair
    using WorkerLink
    export link_pair

    # Handshake over an in-memory connection, the way `handle_worker_link`
    # (server) and `connect_once!` (worker) do it over a websocket.
    function link_pair(; server_kw...)
        ct, st = memory_pair()
        client = Link(:client)
        server_task = Threads.@spawn begin
            h = read_hello(st)
            server = Link(:server; id = h.link_id, server_kw...)
            welcome!(server, st, h, UInt8[]; resumed = false)
            server
        end
        connect!(client, ct, UInt8[])
        return fetch(server_task), client
    end
end

# A real server and a real worker, in process, over a real websocket: what a
# dropped connection does (nothing, once it is back) and what a server that
# forgot the worker does (the worker starts over and registers again).
@testitem "unit:worker_link" tags = [:unit] begin
    import BonitoAgents, BonitoWorker, WorkerLink
    const BA = BonitoAgents
    const BW = BonitoWorker
    using Test

    dir = mktempdir()
    state = BA.serve(; host = "127.0.0.1", port = 0,
                     state_dir = mkpath(joinpath(dir, "state")),
                     working_dir = mkpath(joinpath(dir, "working")))
    worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
        worker_id = "link-test", name = "link-test",
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
        projects_root = mkpath(joinpath(dir, "projects"))))
    task = Threads.@spawn BW.serve(worker; retry_delay = 0.2)
    try
        @test timedwait(() -> BA.worker_connected(state, "link-test"), 30.0) === :ok
        info = state.workers[]["link-test"]
        @test info.online[]

        @testset "a transfer survives a dropped connection" begin
            src = joinpath(dir, "big.bin")
            write(src, rand(UInt8, 40_000_000))
            dst = joinpath(dir, "on-worker", "big.bin")
            xfer = Threads.@spawn BA.send_file_to_worker!(state, "link-test", src, dst)
            sleep(0.2)
            link = BA.worker_link(state, "link-test")
            # Offline while away, but the SAME link: nothing was torn down. The
            # worker dials straight back, so the offline moment is recorded
            # rather than polled for (a poll can fall on either side of it).
            went_offline = Ref(false)
            watch = BA.Bonito.on(v -> v || (went_offline[] = true), info.online)
            WorkerLink.disconnect!(worker.link)
            @test timedwait(() -> went_offline[], 10.0) === :ok
            BA.Bonito.off(watch)
            @test timedwait(() -> BA.worker_connected(state, "link-test"), 30.0) === :ok
            @test BA.worker_link(state, "link-test") === link
            fetch(xfer)
            @test read(dst) == read(src)
        end

        @testset "a server that forgot the link makes the worker start over" begin
            old_link = BA.worker_link(state, "link-test")
            old_control = worker.control
            WorkerLink.kill!(old_link, "the server forgot it")
            @test timedwait(() -> BA.worker_connected(state, "link-test") &&
                                  BA.worker_link(state, "link-test") !== old_link, 30.0) === :ok
            # A new control channel … The server counts the worker connected once
            # it sent its welcome, the worker takes the new channel once that
            # arrived: a moment later (this failed now and then without the wait).
            @test timedwait(() -> worker.control !== old_control, 10.0) === :ok
            @test BA.list_worker_dir(state, "link-test", dir).path == dir   # … that works
        end

        @testset "a failure on the worker reaches the caller with its reason" begin
            err = try
                BA.fetch_file_from_worker(state, "link-test", joinpath(dir, "nope"), joinpath(dir, "x"))
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing && occursin("is not a file", err)
        end
    finally
        close(worker)
        wait(task)
        BA.close_worker_links!(state)
        close(state.srv)
    end
    @test isempty(state.worker_links)
end

# Behind the tunnel a worker's connection drops now and then without either end
# doing anything (production, 2026-10-01: Bosgame and Desktop one after the
# other, each back 12 s later). The link resumes; what must not happen is the
# server failing every request in those seconds ("worker is not connected",
# broken images), or the worker sitting out its retry delay before it redials.
@testitem "unit:worker_reconnect" tags = [:unit] begin
    import BonitoAgents, BonitoWorker, WorkerLink
    const BA = BonitoAgents
    const BW = BonitoWorker
    using Test

    dir = mktempdir()
    state = BA.serve(; host = "127.0.0.1", port = 0,
                     state_dir = mkpath(joinpath(dir, "state")),
                     working_dir = mkpath(joinpath(dir, "working")))
    worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
        worker_id = "reconnect-test", name = "reconnect-test",
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
        projects_root = mkpath(joinpath(dir, "projects"))))
    # A long retry delay, so a redial that waited for it is plain to see.
    task = Threads.@spawn BW.serve(worker; retry_delay = 10.0)
    try
        @test timedwait(() -> BA.worker_connected(state, "reconnect-test"), 30.0) === :ok

        @testset "a request while the connection is down waits for it" begin
            WorkerLink.disconnect!(BA.worker_link(state, "reconnect-test"))
            @test !BA.worker_connected(state, "reconnect-test")
            # Up for less than the retry delay: the worker redials after it.
            listing = BA.list_worker_dir(state, "reconnect-test", dir)
            @test listing.path == dir
            @test BA.worker_connected(state, "reconnect-test")
        end

        @testset "a connection that was up is dialed again at once" begin
            sleep(10.5)                       # up for longer than the retry delay
            WorkerLink.disconnect!(BA.worker_link(state, "reconnect-test"))
            t0 = time()
            @test timedwait(() -> BA.worker_connected(state, "reconnect-test"), 30.0) === :ok
            @test time() - t0 < 5.0
        end

        @testset "a worker that is gone is not waited for" begin
            @test !BA.reachable(state, "nobody")
            t0 = time()
            @test_throws ErrorException BA.list_worker_dir(state, "nobody", dir)
            @test time() - t0 < 1.0
        end
    finally
        close(worker)
        wait(task)
        BA.close_worker_links!(state)
        close(state.srv)
    end
end
