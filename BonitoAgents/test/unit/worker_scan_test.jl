# The worker-side session scan: `scan_sessions` lists every agent's sessions on
# the WORKER's disk, Claude's from `~/.claude/projects/<encoded>/*.jsonl` and the
# others' over ACP `session/list`. Its one drop rule, "the folder no longer
# exists", lives there for all of them (the paths are worker-local; a server-side
# isdir would wrongly drop every row of a remote worker). It used to cover only
# Claude's sessions, so every other agent's deleted temp folders stayed listed.
@testitem "unit:worker_scan" tags = [:unit] begin
    import BonitoWorker
    using JSON

    # A fake ~/.claude layout: two sessions in one encoded project dir, whose
    # jsonls point (via their `cwd` field) at one EXISTING and one DELETED
    # project folder.
    home     = mktempdir()
    proj_dir = mkpath(joinpath(home, ".claude", "projects", "-sim-Fake"))
    alive    = mktempdir()
    gone     = mktempdir()   # removed below: the scan must drop its sessions

    session_line(cwd, text) = JSON.json(Dict(
        "type" => "user", "cwd" => cwd,
        "message" => Dict("role" => "user", "content" => text))) * "\n"
    write(joinpath(proj_dir, "aaaa-alive.jsonl"), session_line(alive, "hello alive"))
    write(joinpath(proj_dir, "bbbb-gone.jsonl"),  session_line(gone,  "hello gone"))
    # Another agent's sessions, in the row shape its `session/list` gives.
    acp_row(sid, path) = Dict{String,Any}("path" => path, "name" => basename(path), "session_id" => sid,
        "last_used" => 0.0, "kind" => "session", "provider" => "KimiCode")
    acp = [acp_row("kimi-alive", alive), acp_row("kimi-gone", gone)]
    rm(gone; recursive = true)

    entries = BonitoWorker.scan_sessions(; home, acp)
    sids = [String(e["session_id"]) for e in entries]

    @testset "existing folders are listed, deleted ones dropped, for every agent" begin
        @test "aaaa-alive" in sids && "kimi-alive" in sids
        @test !("bbbb-gone" in sids) && !("kimi-gone" in sids)
        e = entries[findfirst(==("aaaa-alive"), sids)]
        @test e["path"] == alive
        @test e["kind"] == "session"
        @test occursin("hello alive", String(e["first_prompt"]))
    end
end
