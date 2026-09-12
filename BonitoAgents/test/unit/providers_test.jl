# The provider registry is the single source of truth shared by server and
# worker, so its per-provider contract is worth pinning: every offered provider
# must have a unique wire name the dropdown can round-trip through
# `find_provider`, and its `elicitation` block must be the shape THAT agent
# accepts in `initialize`.
#
# The elicitation shape is a real footgun, not a style choice: `kimi acp`
# validates `clientCapabilities` strictly and answers Claude's `form => true`
# with `-32602 Invalid params` ("expected object, received boolean"), which
# kills the bind before `session/new`. OpenCode wants the same object shape.
@testitem "unit:providers" tags = [:unit] begin
    using AgentProviders
    import JSON

    saved_mock = get(ENV, "BT_ENABLE_MOCK_AGENT", nothing)
    try
        delete!(ENV, "BT_ENABLE_MOCK_AGENT")
        provs = refresh_providers!()          # production list: no mocks

        # Every provider is reachable by its own wire name, and the names are
        # unique — a collision would make `find_provider` return the wrong
        # singleton for whichever entry lost the race.
        names = provider_name.(provs)
        @test length(unique(names)) == length(names)
        for p in provs
            @test find_provider(provider_name(p)) === p
            @test !isempty(label(p))
            @test !isempty(icon(p))
        end
        @test_throws ErrorException find_provider("NoSuchProvider")

        # The mock is offered only behind its env var.
        @test !("MockCode" in names)
        ENV["BT_ENABLE_MOCK_AGENT"] = "1"
        @test "MockCode" in provider_name.(refresh_providers!())

        @test issubset(["ClaudeCode", "MiMoCode", "OpenCode", "KimiCode", "Codex"], names)

        # EVERY provider must declare `elicitation.form` as an OBJECT. The ACP
        # schema reads it via `defaultOnError(z.object({…}).nullish(), …)`, so a
        # boolean is not an error — it is silently swapped for `undefined` and
        # the form capability vanishes, disabling AskUserQuestion with nothing
        # in any log. Kimi is the only agent that rejects it loudly (-32602).
        # This shipped broken once; the assertion is what stops it recurring.
        ENV["BT_ENABLE_MOCK_AGENT"] = "1"
        for p in refresh_providers!()
            @test p.elicitation["form"] isa AbstractDict
            @test !(p.elicitation["form"] isa Bool)
        end
        delete!(ENV, "BT_ENABLE_MOCK_AGENT")
        refresh_providers!()

        kimi = find_provider("KimiCode")
        @test kimi isa KimiAgent
        @test label(kimi) == "Kimi Code"
        # `kimi` is a multi-command CLI: the bare binary launches its TUI, the
        # ACP server lives under `acp`.
        @test kimi.args == ["acp"]
        # Object, NOT `true` — see the header comment.
        @test kimi.elicitation["form"] isa AbstractDict
        @test find_provider("OpenCode").elicitation["form"] isa AbstractDict

        # Codex is the other provider whose ACP server is a SEPARATE adapter
        # binary (`codex-acp`, like claude-agent-acp) rather than a subcommand
        # of the CLI — the `codex` CLI speaks its own app-server protocol and
        # has no `acp` subcommand, so an args list here would be a bug.
        codex = find_provider("Codex")
        @test codex isa CodexAgent
        @test label(codex) == "Codex"
        @test isempty(codex.args)
        @test codex.elicitation["form"] isa AbstractDict
        # The MCP startup grace is load-bearing, not tuning: without it codex
        # drops btworker from the tool catalogue whenever the Julia MCP process
        # is still starting, and the only symptom is the agent claiming it has
        # no such tool. Pinned so it can't be dropped as noise.
        cfg = JSON.parse(codex.env["CODEX_CONFIG"])
        @test cfg["mcp_optional_startup_grace_ms"] >= 30000

        # `KIMI_AGENT_ACP` / `CODEX_AGENT_ACP` override the resolved binary, like
        # every other provider's `*_AGENT_ACP` (used to point a worker at a
        # custom build).
        for (var, name, path) in (("KIMI_AGENT_ACP", "KimiCode", "/custom/kimi"),
                                  ("CODEX_AGENT_ACP", "Codex", "/custom/codex-acp"))
            saved_bin = get(ENV, var, nothing)
            try
                ENV[var] = path
                refresh_providers!()   # the list is memoised; ENV is read on build
                @test find_provider(name).bin == path
            finally
                saved_bin === nothing ? delete!(ENV, var) : (ENV[var] = saved_bin)
            end
        end
    finally
        saved_mock === nothing ? delete!(ENV, "BT_ENABLE_MOCK_AGENT") :
                                 (ENV["BT_ENABLE_MOCK_AGENT"] = saved_mock)
        refresh_providers!()   # leave the memo consistent with the restored ENV
    end
end
