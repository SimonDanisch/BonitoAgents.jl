# The eval worker's environment contract, and the one thing that silently broke
# when it was violated.
#
# An eval worker is spawned as `julia --project=<env_path>` and is supposed to
# resolve packages exactly as that command would in a clean shell. A parent
# process that exports `JULIA_LOAD_PATH` breaks that, and `Pkg.test` is such a
# parent: it runs the test process with `JULIA_LOAD_PATH="@:<testdir>"`, which
# has no `@stdlib`. An eval worker inheriting it cannot load ANY stdlib —
# `using Markdown` inside an eval fails with "Package Markdown not found in
# current path" against an env that legitimately expects stdlibs to come from
# `@stdlib`.
#
# The nastier half of the same bug had nothing to do with the user's code:
# `helper_payload.jl` resolves the REPL soft-scope transform once per worker and
# falls back to `identity` if it can't. Under that LOAD_PATH the fallback fired
# silently, so every eval switched to FILE (hard) scope for the worker's whole
# life and `acc = 0; for i in 1:5; acc += i; end` died with
# "UndefVarError: acc not defined in local scope" — which reads as a bug in the
# user's code, not as "REPL didn't load".
@testitem "unit:eval_worker_env" tags = [:unit] begin
    import BonitoMCP
    using Test

    @testset "worker_env: repairs an inherited JULIA_LOAD_PATH, otherwise no-op" begin
        # Nothing to repair → touch nothing. This is the normal case: BonitoAgents
        # passes `--project` on the worker's command line precisely so it never
        # has to export the variable.
        withenv("JULIA_LOAD_PATH" => nothing) do
            @test isempty(BonitoMCP.worker_env())
        end
        # Inherited → restore Julia's DEFAULT search path. Not a guess: `@` is the
        # `--project` we pass, and the two fallbacks are what a clean shell has.
        withenv("JULIA_LOAD_PATH" => "@:/some/test/dir") do
            e = BonitoMCP.worker_env()
            @test length(e) == 1
            entry = only(e)
            @test startswith(entry, "JULIA_LOAD_PATH=")
            value = entry[length("JULIA_LOAD_PATH=") + 1:end]
            parts = split(value, Sys.iswindows() ? ';' : ':')
            @test parts == ["@", "@v#.#", "@stdlib"]
            # The whole point: the inherited entry is GONE, `@stdlib` is back.
            @test !occursin("/some/test/dir", entry)
        end
    end

    # This half needs a REAL worker: the failure only exists in a process that has
    # not already loaded REPL, so asserting in-process proves nothing (Pkg/Test
    # pull REPL in, and the broken form then resolves it from the module cache).
    # Spawned through BonitoMCP's own session API, not by hand, so it exercises
    # `worker_env` + `build_exeflags` + the helper payload exactly as production
    # composes them. Same approach as BonitoMCP/test/test_session_singleflight.jl.
    @testset "a spawned eval worker can reach the stdlib and keeps REPL semantics" begin
        # Force the exact condition `Pkg.test` creates for its children. (Under
        # `Pkg.test` this is already true — set it explicitly so the test means the
        # same thing when run any other way.)
        withenv("JULIA_LOAD_PATH" => "@:" * abspath(joinpath(@__DIR__, ".."))) do
            sm = BonitoMCP.SessionManager()
            try
                env = mktempdir()
                write(joinpath(env, "Project.toml"),
                      "name = \"wenvprobe\"\nuuid = \"e7a1d000-0000-4000-8000-0000000000ff\"\n\n[deps]\n")
                s = BonitoMCP.get_or_create!(sm, env)
                # `execute` returns pre-formatted block dicts; the rendered text of
                # all of them is what the agent (and the chat) actually sees.
                text_of(r) = join((String(get(b, "text", "")) for b in r.blocks), "\n")

                # The worker's search path is Julia's default, NOT the inherited one.
                r1 = BonitoMCP.execute(s, "string(LOAD_PATH)")
                @test r1.status === :completed
                @test occursin("@stdlib", text_of(r1))
                @test !occursin(abspath(joinpath(@__DIR__, "..")), text_of(r1))

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
