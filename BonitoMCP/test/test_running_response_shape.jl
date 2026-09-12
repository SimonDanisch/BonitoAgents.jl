# Wire contract v3: a `running` checkpoint is ONE terminal-faithful text block —
# the stdout captured so far plus a footer naming the next tools. No code echo
# (the agent has its own tool input and the chat has the typed `code` field) and
# no in-band labels for anyone to sniff. A checkpoint never carries a result
# descriptor; only a completed response does.

using Test
using BonitoMCP
const M = BonitoMCP

@testset "running_response is one terminal-faithful block (wire v3)" begin
    r = M.running_response("/tmp/x", "hello\n", 3.14)

    @test r["isError"] === false
    @test r["_meta"]["status"] == "running"
    @test r["_meta"]["elapsed_s"] == 3.14
    @test length(r["content"]) == 1

    out = r["content"][1]["text"]
    @test startswith(out, "hello\n")        # stdout verbatim, no label prefix
    @test occursin("still running (3.14s", out)
    @test occursin("env=/tmp/x", out)
    @test occursin("bt_julia_continue / bt_julia_interrupt / bt_julia_restart", out)
    # No code echo and no descriptor — those belong to the tool input / a
    # completed response respectively.
    @test !occursin("```julia", out)
    @test !occursin("remote_ref", out)
end

@testset "running_response with no output yet says so" begin
    r = M.running_response(nothing, "", 0.5)
    out = r["content"][1]["text"]
    @test startswith(out, "(no output captured yet)")
    @test !occursin("env=", out)            # temp session → no env in the footer
end

@testset "running variant carries `code` so callers can echo it" begin
    s = M.JuliaSession(nothing; is_temp = true)
    try
        r = M.execute(s, """
        println("partial")
        flush(stdout)
        sleep(5)
        99
        """; timeout = 1.0)
        @test r.status == :running
        @test :code in propertynames(r)
        @test occursin("partial", r.code)
    finally
        try M.interrupt!(s) catch end
        M.kill_session!(s)
    end
end
