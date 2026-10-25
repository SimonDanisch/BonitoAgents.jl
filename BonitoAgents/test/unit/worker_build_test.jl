# A worker's handshake is answered with the build the server offers
# (`worker_update_spec`). Finding that build out asks GitHub (`git ls-remote`),
# and the handshake used to do it itself: right after the tunnel came back from
# an outage (production, 2026-10-01) a worker got "the server did not answer the
# handshake within 30s". Now the build is resolved at startup and in the
# background, a handshake takes what is there, and git that waits on the
# network is cut off.
@testitem "unit:worker_build" tags = [:unit] begin
    import BonitoAgents, BonitoWorker, Sockets
    const BA = BonitoAgents
    const BW = BonitoWorker
    using Test

    spec(rev) = Dict{String,Any}("repo" => "r", "rev" => rev, "source_id" => rev * "-sha",
                                 "bonito_url" => "u", "bonito_rev" => "b")

    @testset "git that waits on a stalled network is cut off" begin
        # An origin that takes the connection and never answers.
        origin = Sockets.listen(Sockets.localhost, 0)
        held = Sockets.TCPSocket[]
        acceptor = @async try
            while true
                push!(held, Sockets.accept(origin))
            end
        catch e
            e isa Base.IOError || rethrow()      # `close(origin)` below
        end
        repo = mktempdir()
        run(pipeline(`git -C $repo init -q`; stdout = devnull))
        url = "http://127.0.0.1:$(Sockets.getsockname(origin)[2])/x.git"
        t0 = time()
        err = try
            BA.git_read(repo, "ls-remote", "--heads", url, "main"; timeout = 1.0)
            nothing
        catch e
            e
        end
        @test err isa ErrorException && occursin("did not finish within 1.0s", err.msg)
        @test time() - t0 < 10
        close(origin)
        foreach(close, held)
        wait(acceptor)
        # A git that fails says why.
        err = try
            BA.git_read(repo, "ls-remote", "/nonexistent/repo")
            nothing
        catch e
            e
        end
        @test err isa ErrorException && occursin("does not appear to be a git repository", err.msg)
    end

    @testset "a failed resolve keeps the last build" begin
        # Its fallback would name another rev, and every auto-updating worker
        # would reinstall to it and back.
        answers = Channel{Any}(Inf)
        b = BA.WorkerBuild(() -> (a = take!(answers); a isa Exception ? throw(a) : a))
        put!(answers, spec("one"))
        @test BA.resolve_worker_build!(b) == spec("one")
        put!(answers, ErrorException("offline"))
        @test_logs (:warn, r"could not resolve the worker build") BA.resolve_worker_build!(b)
        @test b.spec == spec("one")
        put!(answers, spec("two"))
        BA.resolve_worker_build!(b)
        @test b.spec == spec("two")
    end

    @testset "a handshake does not wait for the build" begin
        dir = mktempdir()
        state = BA.serve(; host = "127.0.0.1", port = 0,
                         state_dir = mkpath(joinpath(dir, "state")),
                         working_dir = mkpath(joinpath(dir, "working")))
        @test state.worker_build.spec isa Dict        # resolved at startup
        # From here on the network hangs: a resolve does not come back until let.
        let_through = Channel{Nothing}()
        state.worker_build = BA.WorkerBuild(() -> (take!(let_through); spec("late")))
        worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
            worker_id = "build-test", name = "build-test",
            mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
            projects_root = mkpath(joinpath(dir, "projects"))))
        task = Threads.@spawn BW.serve(worker; retry_delay = 0.2)
        install(path) = BA.HTTP.get("http://127.0.0.1:$(state.srv.port)$(path)"; status_exception = false)
        try
            @test timedwait(() -> BA.worker_connected(state, "build-test"), 20.0) === :ok
            @test state.workers[]["build-test"].update_state === :current
            # The resolve the handshake started is still hanging; no script names
            # a build before there is one.
            @test !istaskdone(state.worker_build.resolving)
            @test install("/install.jl").status == 503
            @test_throws ArgumentError BA.force_worker_update!(state, "build-test")
            put!(let_through, nothing)
            @test timedwait(() -> state.worker_build.spec == spec("late"), 10.0) === :ok
            r = install("/install.jl")
            @test r.status == 200 && occursin("late-sha", String(r.body))
        finally
            close(worker)
            wait(task)
            BA.close_worker_links!(state)
            close(state.srv)
        end
    end
end
