# Running Julia on another worker — the BonitoMCP half.
#
# Two sides live in this package: the chat's MCP, which forwards a call carrying
# `worker = …` to the server, and the EVAL HOST on the other worker, which runs
# the forwarded call and answers over the control channel. Neither needs a
# server to be exercised: the forward is refused loudly when there is no
# control channel (standalone BonitoMCP), and the host's frame handler answers
# on any object `WebSockets.send` accepts.

using Test
using BonitoMCP
using JSON
const M = BonitoMCP

txt(r) = r["content"][1]["text"]

# A socket stand-in that keeps what the host sends.
mutable struct RecordingWS
    frames::Vector{Dict{String,Any}}
    closed::Bool
end
RecordingWS() = RecordingWS(Dict{String,Any}[], false)
M.WebSockets.send(ws::RecordingWS, s::AbstractString) = push!(ws.frames, JSON.parse(String(s)))
Base.close(ws::RecordingWS) = (ws.closed = true; nothing)

wait_frames(ws, n; timeout = 60.0) = timedwait(() -> length(ws.frames) >= n, timeout) === :ok

@testset "running on another worker" begin
    @testset "without a server, `worker` is refused with the reason" begin
        # Standalone BonitoMCP has no control channel — the forward cannot go
        # anywhere, and the agent must be told that rather than see a hang.
        @test M.SERVER.control.ws === nothing
        r = M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "worker" => "MacBook"))
        @test r["isError"] === true
        @test occursin("no control channel", txt(r))
        # Every eval-family tool takes the same argument.
        for h in (M.julia_continue_handler, M.julia_interrupt_handler,
                  M.julia_restart_handler, M.julia_list_sessions_handler)
            r = h(Dict{String,Any}("worker" => "MacBook"))
            @test r["isError"] === true
            @test occursin("no control channel", txt(r))
        end
        r = M.sync_folder_handler(Dict{String,Any}("src" => "/tmp/x", "worker" => "MacBook"))
        @test r["isError"] === true
        @test occursin("no control channel", txt(r))
        # …and the argument is optional everywhere: an empty one means "here".
        @test M.remote_worker(Dict{String,Any}("worker" => "  ")) === nothing
        @test M.remote_worker(Dict{String,Any}()) === nothing
        @test M.remote_worker(Dict{String,Any}("worker" => " MacBook ")) == "MacBook"
        # Nothing was left registered as in flight by the refused forwards.
        @test isempty(M.SERVER.remote_inflight)
    end

    @testset "bt_sync_folder needs both a source and a worker" begin
        @test occursin("`src`", txt(M.sync_folder_handler(Dict{String,Any}("worker" => "x"))))
        @test occursin("`worker`", txt(M.sync_folder_handler(Dict{String,Any}("src" => "/tmp/x"))))
    end

    @testset "the eval host answers relayed calls on the control socket" begin
        ws = RecordingWS()
        # An eval: runs on THIS process's session manager, the result comes back
        # under the request id, in the tool-result shape the chat's MCP returns
        # verbatim. Off-loop, so the reply is awaited.
        M.handle_host_op!(ws, Dict{String,Any}("op" => "eval", "request_id" => "r1",
            "args" => Dict{String,Any}("code" => "40 + 2",
                                       # a `worker` that slipped through must be
                                       # dropped, or the host would forward for ever
                                       "worker" => "somewhere-else")))
        @test wait_frames(ws, 1)
        f = ws.frames[1]
        @test f["type"] == "eval_host_result" && f["request_id"] == "r1"
        @test f["result"]["isError"] === false
        @test occursin("42", f["result"]["content"][1]["text"])

        # Sessions: the temp session the eval just created is listed.
        M.handle_host_op!(ws, Dict{String,Any}("op" => "sessions", "request_id" => "r2"))
        @test wait_frames(ws, 2)
        @test occursin("[temp]", ws.frames[2]["result"]["content"][1]["text"])

        # An unknown op is an error reply, never silence (the caller waits on it).
        M.handle_host_op!(ws, Dict{String,Any}("op" => "dance", "request_id" => "r3"))
        @test wait_frames(ws, 3)
        @test occursin("unknown eval host op", ws.frames[3]["error"])

        # A handler that throws is a tool error, not a dropped reply.
        M.handle_host_op!(ws, Dict{String,Any}("op" => "continue", "request_id" => "r4",
            "args" => Dict{String,Any}("env_path" => "/nowhere/at/all")))
        @test wait_frames(ws, 4)
        @test ws.frames[4]["result"]["isError"] === true

        # Shutdown: acknowledged, then the control loop is told to stop and the
        # socket closed — the process exits through `run_eval_host`'s watch.
        M.handle_host_op!(ws, Dict{String,Any}("op" => "shutdown", "request_id" => "r5"))
        @test ws.frames[end]["request_id"] == "r5" && ws.frames[end]["ok"] === true
        @test M.SERVER.control.stop === true
        @test ws.closed
        M.SERVER.control.stop = false      # leave the process's channel as we found it
        M.restart!(M.manager(), nothing)   # and reap the temp session the eval started
    end

    @testset "run_eval_host refuses to start without its environment" begin
        withenv("BONITOAGENTS_SERVER_URL" => nothing, "BONITOAGENTS_SECRET" => nothing,
                "BONITOAGENTS_PROJECT_ID" => nothing, M.HOST_ENV_WORKER => nothing) do
            @test_throws ErrorException M.run_eval_host()
        end
        @test M.host_worker_id() == ""
    end
end
