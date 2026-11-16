# An eval's result is shown with the methods the eval itself defined or loaded.
# The statements run one by one in ever newer worlds, while the formatting ran in
# the world the eval started in: a type and its `show` defined in one eval
# printed as the default `Foo()`, and `using WGLMakie; scatter(1:10)` could not
# show its figure ("method too new to be called from this world context").

using Test
using BonitoMCP
const M = BonitoMCP

@testset "an eval's value and error show with methods the eval defined" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-world-age-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    try
        r = M.execute(s, """
            struct WorldFoo end
            Base.show(io::IO, ::WorldFoo) = print(io, "custom WorldFoo")
            WorldFoo()"""; timeout = 120.0)
        @test r.status == :completed
        @test r.echo == "custom WorldFoo"

        r = M.execute(s, """
            struct WorldErr <: Exception end
            Base.showerror(io::IO, ::WorldErr) = print(io, "custom WorldErr message")
            throw(WorldErr())"""; timeout = 60.0)
        @test r.status == :completed
        @test occursin("custom WorldErr message", r.echo)
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end
