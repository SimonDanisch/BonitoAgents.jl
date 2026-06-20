# Tests for provider switching (MockCode, ClaudeCode, MiMoCode, OpenCode).
# Headless — no Electron, no real agent binary. Uses MockTransport for
# restart-based tests and unit checks for transport/enum plumbing.

using Test
using BonitoAgents
using BonitoAgents.AgentClientProtocol
using JSON
isdefined(Main, :BT) || (const BT = BonitoAgents)

@testset "provider enum and plumbing" begin
    @test BT.MockCode isa BT.AgentProvider
    @test BT.provider_label(BT.MockCode) == "Mock Agent"
    @test BT.provider_icon(BT.MockCode) == "bt-provider-mock"

    bin = BT.find_provider_bin(BT.MockCode)
    @test isfile(bin)
    @test occursin("mock_claude_agent_acp", bin)

    for p in instances(BT.AgentProvider)
        @test !isempty(BT.provider_label(p))
        @test !isempty(BT.provider_icon(p))
    end
end

@testset "switch_provider! on LocalTransport" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                           worker_secret = "x")
    cwd = mktempdir()
    ENV["MOCK_AGENT_ACP"] = BT.find_provider_bin(BT.MockCode)

    model = BT.ChatModel(state, cwd; project_id = "switch-local",
                         transport = BT.LocalTransport(cwd; provider = BT.MockCode))
    @test model.provider[] == BT.MockCode
    @test model.transport.provider == BT.MockCode

    BT.switch_provider!(model, BT.ClaudeCode)
    @test model.provider[] == BT.ClaudeCode
    @test model.transport isa BT.LocalTransport
    @test model.transport.provider == BT.ClaudeCode

    BT.switch_provider!(model, BT.MockCode)
    @test model.provider[] == BT.MockCode
    @test model.transport.provider == BT.MockCode
    @test model.transport.agent_bin == BT.find_provider_bin(BT.MockCode)
end

@testset "switch_provider! on WorkerTransport" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                           worker_secret = "x")
    cwd = mktempdir()
    wt = BT.WorkerTransport(state, "w1", cwd; provider = BT.ClaudeCode)
    model = BT.ChatModel(state, cwd; project_id = "switch-worker", transport = wt)
    @test model.provider[] == BT.ClaudeCode

    BT.switch_provider!(model, BT.MockCode)
    @test model.provider[] == BT.MockCode
    @test wt.provider == BT.MockCode

    BT.switch_provider!(model, BT.MiMoCode)
    @test model.provider[] == BT.MiMoCode
    @test wt.provider == BT.MiMoCode

    BT.switch_provider!(model, BT.OpenCode)
    @test model.provider[] == BT.OpenCode
    @test wt.provider == BT.OpenCode
end

@testset "restart_chat_session! with MockTransport" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                           worker_secret = "x")
    upd(t) = JSON.json(Dict("jsonrpc" => "2.0", "method" => "session/update",
        "params" => Dict("sessionId" => "s",
            "update" => Dict("sessionUpdate" => "agent_message_chunk",
                             "content" => Dict("type" => "text", "text" => t)))))
    r(id, res) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => res))

    on_setup = (out::Channel{String}, inc::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in out
                msg = JSON.parse(line)
                m = get(msg, "method", ""); id = get(msg, "id", nothing)
                if m == "initialize" && id !== nothing
                    put!(inc, r(id, Dict()))
                elseif m == "session/new" && id !== nothing
                    put!(inc, r(id, Dict("sessionId" => "s")))
                elseif m == "session/prompt" && id !== nothing
                    for i in 1:3; put!(inc, upd("c$i ")); end
                    put!(inc, r(id, Dict("stopReason" => "end_turn")))
                end
            end
        catch e
            e isa InvalidStateException || rethrow()
        end)
        return nothing
    end

    transport = BT.MockTransport(on_setup)
    model = BT.ChatModel(state, mktempdir(); transport = transport)
    BT.start_chat_client!(model)
    @test model.client[] !== nothing

    BT.restart_chat_session!(model)
    @test model.session_alive[] == true
    @test isempty(model.last_error[])
    @test model.client[] !== nothing

    BT.restart_chat_session!(model)
    @test model.session_alive[] == true
    @test isempty(model.last_error[])
end

@testset "switch_provider! with MockTransport creates fresh transport" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                           worker_secret = "x")
    upd(t) = JSON.json(Dict("jsonrpc" => "2.0", "method" => "session/update",
        "params" => Dict("sessionId" => "s",
            "update" => Dict("sessionUpdate" => "agent_message_chunk",
                             "content" => Dict("type" => "text", "text" => t)))))
    r(id, res) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => res))

    on_setup = (out::Channel{String}, inc::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in out
                msg = JSON.parse(line)
                m = get(msg, "method", ""); id = get(msg, "id", nothing)
                if m == "initialize" && id !== nothing
                    put!(inc, r(id, Dict()))
                elseif m == "session/new" && id !== nothing
                    put!(inc, r(id, Dict("sessionId" => "s")))
                elseif m == "session/prompt" && id !== nothing
                    put!(inc, upd("ok")); put!(inc, r(id, Dict("stopReason" => "end_turn")))
                end
            end
        catch e
            e isa InvalidStateException || rethrow()
        end)
        return nothing
    end

    model = BT.ChatModel(state, mktempdir();
                         transport = BT.MockTransport(on_setup),
                         project_id = "switch-mock")
    BT.start_chat_client!(model)
    @test model.session_alive[] == true

    old_transport = model.transport

    BT.switch_provider!(model, BT.MockCode)
    @test model.provider[] == BT.MockCode
    @test model.transport isa BT.MockTransport
    @test model.transport !== old_transport
    @test model.session_alive[] == true
    @test isempty(model.last_error[])
end
