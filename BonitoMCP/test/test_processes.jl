# What this process tells the server about the processes it runs (processes.jl).
# The server's record of a chat's processes is built from these reports, and a
# restart of the chat kills from it: a Julia eval worker leads a process group of
# its own (Malt), so the worker's kill of the agent's group never reaches it.

using Test
using BonitoMCP
const M = BonitoMCP

# The server's end of the control channel: keeps every frame sent to it.
struct FramesToServer
    sent::Vector{Any}
end
M.WebSockets.send(ws::FramesToServer, x) = (push!(ws.sent, M.JSON.parse(String(x))); nothing)

@testset "process reports" begin
    ws = FramesToServer(Any[])
    prev = M.SERVER.control.ws
    M.SERVER.control.ws = ws
    reports() = [f for f in ws.sent if f["type"] == "process_update"]
    env = mktempdir()
    try
        t0 = time()
        M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))
        s = M.manager().sessions[M._key(env)]
        pid = M.worker_pid(s)

        @testset "an eval worker is reported when it starts" begin
            started = only(f for f in reports() if f["pid"] == pid)
            @test started["kind"] == "julia session" && started["alive"] === true
            @test started["label"] == env
            # The group it leads: what its code starts dies with it.
            @test started["pgid"] == s.pgid
            @test t0 <= started["recorded_at"] <= time()
        end

        @testset "on (re)connect: this process and every live eval worker again" begin
            n = length(reports())
            M.announce_processes()
            again = reports()[n+1:end]
            @test (getpid(), "mcp") in [(f["pid"], f["kind"]) for f in again]
            @test (pid, "julia session") in [(f["pid"], f["kind"]) for f in again]
        end

        @testset "its end is reported" begin
            M.restart!(M.manager(), env)
            gone = last(reports())
            @test gone["pid"] == pid && gone["alive"] === false
        end

        @testset "also when the worker was killed outright first" begin
            # Its process handle no longer knows the pid then (getpid throws).
            M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))
            s2 = M.manager().sessions[M._key(env)]
            pid2 = M.worker_pid(s2)
            @test pid2 > 0 && pid2 != pid
            ccall(:kill, Cint, (Cint, Cint), pid2, 9)
            @test timedwait(() -> !M.is_alive(s2), 10.0) === :ok
            M.kill_session!(s2)
            gone = last(reports())
            @test gone["pid"] == pid2 && gone["alive"] === false
            @test M.worker_pid(s2) == 0
        end
    finally
        M.SERVER.control.ws = prev
    end
end
