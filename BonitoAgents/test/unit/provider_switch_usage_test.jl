# A provider switch starts a FRESH session, so the context meter must not keep
# the old provider's numbers: a codex window ("125.5k/258.4k") stayed on screen
# under "model: Opus (1M context)" until the new session's first usage_update.
@testitem "unit:provider_switch_usage" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    const BT = BonitoAgents

    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                          worker_secret = "x")
    # No worker behind the agent: the session restart fails fast and is
    # swallowed by `restart_chat_session!` (the chat object survives), which is
    # all the switch's bookkeeping needs.
    model = BT.ChatModel(st, mktempdir(); project_id = "proj",
                         agent = BT.WorkerAgent(st, "w1", "/p"))
    model.usage[] = (used = 125_500, size = 258_400, cost = nothing, origin = nothing)
    from = model.provider[]
    to = BT.find_provider(BT.provider_name(from) == "OpenCode" ? "KimiCode" : "OpenCode")
    failure = BT.switch_provider!(model, to)
    @test failure isa String
    @test model.provider[] === from
    @test model.usage[] === nothing
    @test isempty(model.session_meta[])

    codex = BT.find_provider("Codex")
    detail = BT.provider_startup_detail(model, codex,
        "failed to spawn agent (codex-acp): no such file")
    @test startswith(detail, "failed to spawn agent")
    @test occursin("worker \"w1\"", detail)
    @test occursin("npm install -g @agentclientprotocol/codex-acp", detail)
    @test occursin("codex login", detail)
    @test occursin("CODEX_API_KEY or OPENAI_API_KEY", detail)
end
