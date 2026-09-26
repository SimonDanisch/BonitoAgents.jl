# The eval worker's environment contract.
#
# An eval worker is spawned as `julia --project=<env_path>` and resolves
# packages exactly as that command does in a clean shell: nothing in production
# sets `JULIA_LOAD_PATH` (the test side removes the one `Pkg.test` exports, see
# TestKit). It inherits no relay grant either: the MCP process takes that out of
# its own environment at startup.
#
# What broke when the load path was polluted, and what the last testset pins:
# no stdlib loaded (`using Markdown` → "Package Markdown not found in current
# path"), and `helper_payload.jl` silently fell back from the REPL soft-scope
# transform to `identity`, so `acc = 0; for i in 1:5; acc += i; end` died with
# "UndefVarError: acc not defined in local scope".
@testitem "unit:eval_worker_env" tags = [:unit] begin
    import BonitoMCP
    using Test

    @testset "the relay grant is taken out of the environment, not read" begin
        # The eval workers an MCP process starts inherit its environment and run
        # user code; the grant must not be there for them to find.
        grant = ("BONITOAGENTS_CONTROL_URL" => "ws://127.0.0.1:1",
                 "BONITOAGENTS_CONTROL_TOKEN" => "control-secret",
                 "BONITOAGENTS_EVAL_TOKEN" => "eval-secret")
        withenv(grant...) do
            try
                g = BonitoMCP.take_relay_grant!()
                @test (g.url, g.token, g.eval_token) == ("ws://127.0.0.1:1", "control-secret", "eval-secret")
                @test BonitoMCP.relay_grant() === g
                @test !any(k -> haskey(ENV, k), first.(grant))
            finally
                BonitoMCP.reset_ctrl_dialback!()     # and forget it again
            end
        end
        @test BonitoMCP.relay_grant() === nothing
        # A URL without tokens is a broken launch, not a standalone process.
        withenv("BONITOAGENTS_CONTROL_URL" => "ws://127.0.0.1:1",
                "BONITOAGENTS_CONTROL_TOKEN" => nothing, "BONITOAGENTS_EVAL_TOKEN" => nothing) do
            @test_throws ErrorException BonitoMCP.take_relay_grant!()
        end
        @test BonitoMCP.relay_grant() === nothing
    end

    # This half needs a REAL worker: the failure only exists in a process that has
    # not already loaded REPL, so asserting in-process proves nothing (Pkg/Test
    # pull REPL in, and the broken form then resolves it from the module cache).
    # Spawned through BonitoMCP's own session API, not by hand, so it exercises
    # `build_exeflags` + the helper payload exactly as production composes them.
    # Same approach as BonitoMCP/test/test_session_singleflight.jl.
    @testset "a spawned eval worker can reach the stdlib and keeps REPL semantics" begin
        # As in production, where nothing sets the variable.
        withenv("JULIA_LOAD_PATH" => nothing) do
            sm = BonitoMCP.SessionManager()
            try
                env = mktempdir()
                write(joinpath(env, "Project.toml"),
                      "name = \"wenvprobe\"\nuuid = \"e7a1d000-0000-4000-8000-0000000000ff\"\n\n[deps]\n")
                s = BonitoMCP.get_or_create!(sm, env)
                # `execute` returns pre-formatted block dicts; the rendered text of
                # all of them is what the agent (and the chat) actually sees.
                text_of(r) = join((String(get(b, "text", "")) for b in r.blocks), "\n")

                # The worker's search path is Julia's default.
                r1 = BonitoMCP.execute(s, "string(LOAD_PATH)")
                @test r1.status === :completed
                @test occursin("@stdlib", text_of(r1))

                # A stdlib the project never declares still loads — the symptom that
                # took `ty-markdown` down was exactly this `using` failing.
                r2 = BonitoMCP.execute(s, "using Markdown; \"MDOK\"")
                @test !occursin("not found in current path", text_of(r2))
                @test occursin("MDOK", text_of(r2))

                # REPL semantics survive: a top-level loop assigning a global is the
                # REPL's scope rule, and the silent `identity` fallback replaced it
                # with file scope ("UndefVarError: acc not defined in local scope").
                r3 = BonitoMCP.execute(s, "acc = 0\nfor i in 1:5\n    acc += i\nend\nacc")
                @test !occursin("local scope", text_of(r3))
                @test occursin("15", text_of(r3))

                # And a definition + call in ONE eval — the other half of the
                # per-top-level-statement contract `repl_eval` provides.
                r4 = BonitoMCP.execute(s, "dbl_(x) = 2x\ndbl_(21)")
                @test occursin("42", text_of(r4))
            finally
                BonitoMCP.shutdown!(sm)
            end
        end
    end
end
