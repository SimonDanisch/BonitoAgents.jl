# The eval worker's package search path.
#
# A worker is spawned as `julia --project=<env_path>` and must resolve packages
# exactly as that command would in a clean shell. That is only true if nothing
# upstream exported `JULIA_LOAD_PATH`, and hosts do export it — `Pkg.test` runs
# its test process with `JULIA_LOAD_PATH="@:<testdir>"`, which has no `@stdlib`.
# A worker inheriting that cannot load a single stdlib: `using Markdown` fails
# with "Package Markdown not found in current path" against a project that
# legitimately expects stdlibs to come from `@stdlib`.
#
# `worker_env` repairs exactly that and nothing else. It does not GUESS a value;
# it restores Julia's DEFAULT, which is what "the project on the command line
# decides, with the usual fallbacks" means.

using Test
using BonitoMCP
const M = BonitoMCP

@testset "eval worker LOAD_PATH" begin

    @testset "worker_env: repair when inherited, no-op otherwise" begin
        # Nothing inherited → touch nothing at all. This is the normal case:
        # BonitoAgents passes `--project` on the worker's command line precisely
        # so it never has to export the variable.
        withenv("JULIA_LOAD_PATH" => nothing) do
            @test isempty(M.worker_env())
        end

        withenv("JULIA_LOAD_PATH" => "@:/leaked/from/a/parent") do
            e = M.worker_env()
            @test length(e) == 1
            entry = only(e)
            @test startswith(entry, "JULIA_LOAD_PATH=")
            value = entry[(length("JULIA_LOAD_PATH=") + 1):end]
            @test split(value, Sys.iswindows() ? ';' : ':') == ["@", "@v#.#", "@stdlib"]
            # The leaked entry is GONE and `@stdlib` is back — both halves matter.
            @test !occursin("/leaked/from/a/parent", entry)
            @test occursin("@stdlib", entry)
        end
    end

    @testset "a spawned worker gets the default path and can load a stdlib" begin
        # The polluted entry points at an EMPTY directory ON PURPOSE. Point it at
        # a real project and the test passes for the wrong reason — that project
        # supplies the packages itself, so the repair is never exercised.
        leaked = mktempdir()
        withenv("JULIA_LOAD_PATH" => "@:" * leaked) do
            sm = M.SessionManager()
            try
                env = mktempdir()
                write(joinpath(env, "Project.toml"),
                      "name = \"lpprobe\"\nuuid = \"e7a1d000-0000-4000-8000-0000000000fe\"\n\n[deps]\n")
                s = M.get_or_create!(sm, env)
                text_of(r) = join((String(get(b, "text", "")) for b in r.blocks), "\n")

                r1 = M.execute(s, "string(LOAD_PATH)")
                @test r1.status === :completed
                @test occursin("@stdlib", text_of(r1))
                @test !occursin(leaked, text_of(r1))

                # A stdlib the project never declares still loads.
                r2 = M.execute(s, "using Markdown; \"MDOK\"")
                @test !occursin("not found in current path", text_of(r2))
                @test occursin("MDOK", text_of(r2))

                # REPL semantics come from the same place: `helper_payload.jl`
                # resolves the soft-scope transform once per worker and used to
                # fall back to `identity` in silence, which swapped every eval to
                # FILE scope for the worker's life — a top-level `for` assigning a
                # global then died with "UndefVarError: acc not defined in local
                # scope", reading as a bug in the user's code.
                r3 = M.execute(s, "acc = 0\nfor i in 1:5\n    acc += i\nend\nacc")
                @test !occursin("local scope", text_of(r3))
                @test occursin("15", text_of(r3))
            finally
                M.shutdown!(sm)
            end
        end
    end
end
