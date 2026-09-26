# The eval worker's package search path.
#
# A worker is spawned as `julia --project=<env_path>` and must resolve packages
# exactly as that command would in a clean shell. Nothing in production sets
# `JULIA_LOAD_PATH`; `Pkg.test` does (`"@:<testdir>"`, no `@stdlib`), which is
# why runtests.jl removes it. A worker inheriting that could not load a single
# stdlib, and silently lost REPL scoping.

using Test
using BonitoMCP
const M = BonitoMCP

@testset "eval worker LOAD_PATH" begin

    @testset "a spawned worker gets the default path and can load a stdlib" begin
        # As in production, where nothing sets the variable.
        withenv("JULIA_LOAD_PATH" => nothing) do
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
