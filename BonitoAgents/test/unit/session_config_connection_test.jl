@testitem "unit:session_config_connection" tags = [:unit] begin
    using BonitoAgents, JSON
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    mutable struct SettingsTransport <: ACP.Transport
        requests::Channel{Any}
        incoming::Channel{String}
    end
    SettingsTransport() = SettingsTransport(Channel{Any}(8), Channel{String}(8))
    ACP.send(t::SettingsTransport, line::AbstractString) = put!(t.requests, JSON.parse(line))
    ACP.recv(t::SettingsTransport) = take!(t.incoming)
    ACP.transport_eof(t::SettingsTransport) = !isopen(t.incoming)
    Base.close(t::SettingsTransport) = close(t.incoming)
    option(name) = Dict("id" => "model", "name" => "Model", "category" => "model", "type" => "select",
        "currentValue" => name, "options" => [Dict("value" => name, "name" => name)])
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    model = BT.ChatModel(st, mktempdir(); agent = BT.WorkerAgent(st, "offline", "/project"))
    old = ACP.Client(ACP.Connection(SettingsTransport(), ACP.DiscardHandler()), "old", "/project")
    fresh = ACP.Client(ACP.Connection(SettingsTransport(), ACP.DiscardHandler()), "new", "/project")
    try
        model.agent.client = old
        model.session_meta[] = Any[ACP.parse_config_options(Dict("configOptions" => [option("old")]))...]
        BT.apply_config_pick!(model, "model", "old")
        @test timedwait(() -> isready(old.conn.transport.requests), 5) === :ok
        req = take!(old.conn.transport.requests)
        # The reply belongs to the old connection even though the shared model
        # now points to a new provider. It must never restore the old menu.
        model.agent.client = fresh
        model.session_meta[] = Any[ACP.parse_config_options(Dict("configOptions" => [option("new")]))...]
        put!(old.conn.transport.incoming, JSON.json(Dict("jsonrpc" => "2.0", "id" => req["id"],
            "result" => Dict("configOptions" => [option("old")]))))
        lock(model.config_lock) do
            @test only(model.session_meta[]).current_value == "new"
            @test only(only(model.session_meta[]).choices).value == "new"
        end
        # A saved choice from a previous provider is ignored if this provider
        # does not advertise it, so it cannot poison either its menu or startup.
        st.default_session_config[] = Dict("model" => "old")
        BT.apply_session_config!(model; wait = true)
        @test !isready(fresh.conn.transport.requests)
        @test only(model.session_meta[]).current_value == "new"
        @test !BT.apply_config_pick!(model, "model", "old")
        @test !isready(fresh.conn.transport.requests)
        @test_throws ACP.ConnectionClosed ACP.set_config_option!(fresh, "model", "new"; timeout = 0.02)
        @test isempty(fresh.conn.pending)
        # Stop must release a prompt waiting on settings, even when the
        # settings task is blocked and there is no ACP prompt to cancel yet.
        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        holding = @async lock(model.config_lock) do
            put!(entered, nothing)
            take!(release)
        end
        take!(entered)
        BT.send_message!(model, BT.UserMsg("cancel before the prompt"))
        entry = BT.next_submission(model)
        waiting = @async BT.while_busy(model) do
            BT.apply_session_config!(model; wait = true, submission = entry)
        end
        @test timedwait(() -> BT.busy(model), 5) === :ok
        BT.drop_queued_sends!(model)
        @test timedwait(() -> istaskdone(waiting), 1) === :ok
        @test fetch(waiting) === false
        @test !BT.busy(model)
        put!(release, nothing)
        wait(holding)
    finally
        close(old)
        close(fresh)
        close(model)
    end
end
