# Running Julia on another worker — the server's rules, headless.
#
# `bt_julia_eval(worker = …)` reaches the server as the `remote_eval` op over a
# chat's MCP control channel (remote_eval.jl). What the server decides before a
# single byte goes to a worker is testable without workers: the per-chat switch
# (off by default, persisted), how a worker is named, that a chat's own worker is
# refused, and that the switch turning off is remembered across a restart. The
# relay itself is covered end to end by `e2e:remote_eval`.
@testitem "unit:remote_eval" tags = [:unit] begin
    using Test, Dates
    import BonitoAgents as BT

    state_dir = mktempdir()
    st = BT.ServerState(; state_dir, working_dir = mktempdir(), worker_secret = "x")
    mkworker(id, name) = BT.WorkerInfo(id, name, "ws://x", "x", nothing, name * "-host",
                                       "/home/u", "julia", String[], "/home/u/projects/" * name,
                                       :online, now())
    wa = mkworker("wid-a", "Desktop"); wb = mkworker("wid-b", "MacBook")
    st.workers[]["wid-a"] = wa; st.workers[]["wid-b"] = wb
    p = BT.ProjectInfo("p1", "proj", "wid-a", joinpath(st.working_dir, "proj"),
                       "/home/u/projects/Desktop/proj", now(UTC))
    st.projects[]["p1"] = p

    eval_args(worker; op = "eval") = Dict{String,Any}(
        "worker" => worker, "op" => op, "args" => Dict{String,Any}("code" => "1 + 1"))

    @testset "off by default, and the refusal says where the switch is" begin
        @test p.remote_eval === false
        err = try; BT.dev_request(st, "remote_eval", eval_args("MacBook"), "p1"); ""
              catch e; sprint(showerror, e) end
        @test occursin("switched OFF", err) && occursin("chat header", err)
        # The companion tool is gated by the same switch.
        err = try
            BT.dev_request(st, "sync_folder", Dict{String,Any}("worker" => "MacBook", "src" => "/a"), "p1"); ""
        catch e; sprint(showerror, e) end
        @test occursin("switched OFF", err)
        # A request that names no chat (no project id on the channel) can't be granted.
        err = try; BT.dev_request(st, "remote_eval", eval_args("MacBook"), ""); ""
              catch e; sprint(showerror, e) end
        @test occursin("needs a chat", err)
        # Looking is allowed regardless: the listing says the switch is off and
        # names the OTHER workers only.
        r = BT.dev_request(st, "remote_workers", Dict{String,Any}(), "p1")
        @test r["enabled"] === false
        @test [w["name"] for w in r["workers"]] == ["MacBook"]
        @test r["workers"][1]["host_live"] === false
    end

    @testset "naming a worker" begin
        BT.set_remote_eval!(st, "p1", true)
        @test p.remote_eval === true
        @test BT.resolve_worker(st, "MacBook").worker_id == "wid-b"
        @test BT.resolve_worker(st, "macbook").worker_id == "wid-b"      # case-insensitive
        @test BT.resolve_worker(st, "wid-b").worker_id == "wid-b"        # or by id
        err = try; BT.resolve_worker(st, "Toaster"); "" catch e; sprint(showerror, e) end
        @test occursin("no worker named 'Toaster'", err) && occursin("MacBook", err)
        # The chat's own worker is not a remote target.
        err = try; BT.dev_request(st, "remote_eval", eval_args("Desktop"), "p1"); ""
              catch e; sprint(showerror, e) end
        @test occursin("own worker", err)
        # An offline worker is named as such, not spawned on.
        wb.online[] = false
        err = try; BT.dev_request(st, "remote_eval", eval_args("MacBook"), "p1"); ""
              catch e; sprint(showerror, e) end
        @test occursin("offline", err)
        wb.online[] = true
        # An unknown op is refused before anything is spawned.
        err = try; BT.dev_request(st, "remote_eval", eval_args("MacBook"; op = "dance"), "p1"); ""
              catch e; sprint(showerror, e) end
        @test occursin("unknown remote op", err)
        # With everything in order but no control socket to the worker, the
        # spawn is refused as unreachable — the message the agent relays.
        err = try; BT.dev_request(st, "remote_eval", eval_args("MacBook"), "p1"); ""
              catch e; sprint(showerror, e) end
        @test occursin("not connected", err)
        @test isempty(st.eval_hosts)
        r = BT.dev_request(st, "remote_workers", Dict{String,Any}(), "p1")
        @test r["enabled"] === true
    end

    @testset "the switch is remembered, and off closes the hosts" begin
        BT.set_remote_eval!(st, "p1", false)
        @test p.remote_eval === false
        BT.set_remote_eval!(st, "p1", true)
        # A fresh server over the same state dir reads the flag back; the
        # persisted form never assumes it.
        st2 = BT.ServerState(; state_dir, working_dir = st.working_dir, worker_secret = "x")
        BT.load_projects!(st2)
        @test st2.projects[]["p1"].remote_eval === true
        # `eval_hosts_of` / `close_eval_hosts!` are no-ops for a chat without hosts.
        @test isempty(BT.eval_hosts_of(st, "p1"))
        BT.close_eval_hosts!(st, "p1")
        BT.set_remote_eval!(st, "p1", false)
        @test isempty(st.eval_hosts)
    end

    @testset "stream routes on another worker carry its id" begin
        @test BT.eval_host_key("p1", "wid-b") == "p1\0wid-b"
        # A frame from a host is keyed under the worker, so the chat's sink for a
        # remote eval (`eval_route_key(state, m)`) is what it reaches — and a
        # local session on the same env_path is not.
        m = BT.JuliaEvalToolMsg(BT.Message("t1", "other", "bt_julia_eval", "bt_julia_eval", "pending", "", time(), nothing, nothing), "btworker")
        BT.apply_input!(m, Dict{String,Any}("code" => "1", "env_path" => "/tmp/env", "worker" => "MacBook"))
        @test m.worker == "MacBook"
        @test BT.eval_route_key(st, m) == "wid-b\0" * abspath("/tmp/env")
        local_m = BT.JuliaEvalToolMsg(BT.Message("t1", "other", "bt_julia_eval", "bt_julia_eval", "pending", "", time(), nothing, nothing), "btworker")
        BT.apply_input!(local_m, Dict{String,Any}("code" => "1", "env_path" => "/tmp/env"))
        @test BT.eval_route_key(st, local_m) == abspath("/tmp/env")
        @test BT.eval_env_summary(m) == "env /tmp/env · on MacBook"
    end
end
