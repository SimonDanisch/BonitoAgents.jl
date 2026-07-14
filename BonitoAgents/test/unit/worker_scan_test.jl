# The worker-side Claude-session scanner: `scan_claude_sessions` enumerates
# `~/.claude/projects/<encoded>/*.jsonl` on the WORKER's disk. Its one drop
# rule — "the project folder no longer exists" — must live HERE (the paths are
# worker-local; a server-side isdir would wrongly drop every row of a remote
# worker, which is exactly the regression this guards against).
@testitem "unit:worker_scan" tags = [:unit] begin
    import BonitoWorker
    using JSON

    # A fake ~/.claude layout: two sessions in one encoded project dir, whose
    # jsonls point (via their `cwd` field) at one EXISTING and one DELETED
    # project folder.
    home     = mktempdir()
    proj_dir = mkpath(joinpath(home, ".claude", "projects", "-sim-Fake"))
    alive    = mktempdir()
    gone     = mktempdir()   # removed below — the scanner must drop its session

    session_line(cwd, text) = JSON.json(Dict(
        "type" => "user", "cwd" => cwd,
        "message" => Dict("role" => "user", "content" => text))) * "\n"
    write(joinpath(proj_dir, "aaaa-alive.jsonl"), session_line(alive, "hello alive"))
    write(joinpath(proj_dir, "bbbb-gone.jsonl"),  session_line(gone,  "hello gone"))
    rm(gone; recursive = true)

    entries = BonitoWorker.scan_claude_sessions(; home = home)
    sids = [String(e["session_id"]) for e in entries]

    @testset "existing folder is listed, deleted folder is dropped" begin
        @test "aaaa-alive" in sids
        @test !("bbbb-gone" in sids)
        e = entries[findfirst(==("aaaa-alive"), sids)]
        @test e["path"] == alive
        @test e["kind"] == "session"
        @test occursin("hello alive", String(e["first_prompt"]))
    end
end
