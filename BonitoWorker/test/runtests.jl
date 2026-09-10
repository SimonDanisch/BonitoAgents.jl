# Cross-platform regression suite for BonitoWorker. Focus on the surfaces we
# burned ourselves on: Windows `.cmd` shims, scan_claude_sessions invariants
# (cwd from jsonl content, not folder name), and worker_id / worker_name
# derivation.

using Test
using BonitoWorker
import AgentProviders
const BW = BonitoWorker

# A WebSocket stand-in that drops sends — handle_* helpers write their JSON
# response to the WS, which the unit tests don't need to read. Reach the
# exact `send` the worker calls (`HTTP.WebSockets.send`) through the module
# so HTTP needn't be a direct test dep.
struct NullWS end
BonitoWorker.WebSockets.send(::NullWS, ::Any) = nothing

@testset "BonitoWorker" begin

# ── which_executable ──────────────────────────────────────────────────────────
# Tests the contract directly via a planted file on a temp PATH dir — avoids
# depending on real-world PATH layout (Pkg.test sandboxes PATH; CI machines
# may or may not have `npm` etc.).
@testset "which_executable" begin
    mktempdir() do dir
        old_path = get(ENV, "PATH", "")
        sep = Sys.iswindows() ? ';' : ':'
        ENV["PATH"] = dir * sep * old_path
        try
            @test BW.which_executable("definitely-not-a-real-bin-xyz-9999") === nothing

            if Sys.iswindows()
                # The whole reason which_executable exists: Sys.which on
                # Windows doesn't walk PATHEXT for .cmd/.bat shims, so
                # plain `Sys.which("foo")` returns nothing for a .cmd file
                # but `which_executable("foo")` must find it.
                cmd_file = joinpath(dir, "fake_helper_xyz.cmd")
                write(cmd_file, "@echo off\r\necho ok\r\n")
                @test Sys.which("fake_helper_xyz") === nothing            # contract baseline
                hit = BW.which_executable("fake_helper_xyz")
                @test hit !== nothing
                @test endswith(lowercase(String(hit)), ".cmd")
                # Also: .bat variant resolves.
                bat_file = joinpath(dir, "another_helper_xyz.bat")
                write(bat_file, "@echo off\r\necho ok\r\n")
                @test endswith(lowercase(String(BW.which_executable("another_helper_xyz"))), ".bat")
            else
                # On Unix `Sys.which` already walks PATH correctly; the
                # wrapper just delegates. Plant an executable and verify
                # the wrapper returns the same path.
                bin = joinpath(dir, "fake_helper_xyz")
                write(bin, "#!/bin/sh\necho ok\n")
                chmod(bin, 0o755)
                @test BW.which_executable("fake_helper_xyz") == Sys.which("fake_helper_xyz")
            end
        finally
            ENV["PATH"] = old_path
        end
    end
end

# ── scan_claude_sessions ──────────────────────────────────────────────────────
@testset "scan_claude_sessions" begin
    # Empty home → empty results, no error (don't crash on a fresh machine).
    mktempdir() do home
        @test BW.scan_claude_sessions(home = home) == Dict{String,Any}[]
    end

    # Build a fake ~/.claude/projects/ with two subprojects and verify the
    # dict shape + descending sort by last_used. The encoded folder name is
    # NOT parsed by the new scanner — we read `cwd` directly from the jsonl
    # content. So the folder name is arbitrary; the jsonl payload is what
    # matters.
    mktempdir() do home
        proj_a = joinpath(home, "proj-a")
        proj_b = joinpath(home, "proj-b")
        mkpath(proj_a); mkpath(proj_b)

        claude_root = joinpath(home, ".claude", "projects")
        # Arbitrary folder names; deliberately NOT a valid encoding of the
        # cwd — this proves we don't rely on folder-name decoding anymore.
        mkpath(joinpath(claude_root, "enc-a"))
        mkpath(joinpath(claude_root, "enc-b"))

        # Two jsonls. First line carries the cwd field; that's all the
        # scanner needs. Touch B's after A so B sorts first by mtime.
        a_jsonl = joinpath(claude_root, "enc-a", "11111111-1111-1111-1111-111111111111.jsonl")
        b_jsonl = joinpath(claude_root, "enc-b", "22222222-2222-2222-2222-222222222222.jsonl")
        write(a_jsonl, """{"cwd":"$(escape_string(proj_a))"}\n""")
        sleep(0.05)
        write(b_jsonl, """{"cwd":"$(escape_string(proj_b))"}\n""")

        results = BW.scan_claude_sessions(home = home)

        # Both projects discovered, sorted newest-first.
        @test length(results) == 2
        @test results[1]["name"] == "proj-b"
        @test results[2]["name"] == "proj-a"
        @test results[1]["path"] == proj_b
        @test results[2]["path"] == proj_a

        # Required keys present + types right.
        for r in results
            @test haskey(r, "path") && r["path"] isa AbstractString
            @test haskey(r, "name") && !isempty(r["name"])
            @test haskey(r, "session_id") && length(r["session_id"]) == 36  # uuid-ish
            @test haskey(r, "last_used") && r["last_used"] isa Number
        end

        # New optional fields are present with their default values: no
        # sessions/<pid>.json in the fake home → not running; no user
        # message in the jsonl → no preview; no subagents/ dir → kind=session.
        for r in results
            @test r["kind"] == "session"
            @test r["running"] === false
            @test r["pid"] === nothing
            @test r["first_prompt"] === nothing
            @test r["agent_type"] === nothing
            @test r["parent_session_id"] === nothing
        end

        # Unique paths (the scanner never duplicates).
        @test length(unique(r["path"] for r in results)) == length(results)
    end
end

# ── first_prompt extraction ──────────────────────────────────────────────────
# The discover preview must show what the user TYPED, not the pseudo-XML context
# Claude Code injects into the first user messages (ide_opened_file, system
# reminders, slash-command wrappers, local-command caveats). meaningful_prompt
# strips leading context blocks and skips wholly-injected messages (→ nothing,
# so the scan keeps looking for a real prompt).
@testset "first_prompt extraction (skip injected context)" begin
    # Wholly injected / tooling-noise messages → nothing (scan skips them).
    @test BW.meaningful_prompt("<ide_opened_file>The user opened /x/a.md in the IDE.</ide_opened_file>") === nothing
    @test BW.meaningful_prompt("Caveat: The messages below were generated by the user while running local commands. DO NOT respond") === nothing
    @test BW.meaningful_prompt("<command-name>/compact</command-name><command-message>compact</command-message>") === nothing
    @test BW.meaningful_prompt("<system-reminder>As you answer…</system-reminder>") === nothing
    @test BW.meaningful_prompt("   ") === nothing
    # Unknown / future tag names must NOT leak through — the stripper is generic.
    @test BW.meaningful_prompt("<local-command-caveat>Caveat: …</local-command-caveat>") === nothing
    @test BW.meaningful_prompt("<future_unknown_wrapper>noise</future_unknown_wrapper>") === nothing
    # Bare opener with no closer (system commentary like `<ide_opened_file>The
    # user opened …` followed by free text) is treated as commentary, not prose.
    @test BW.meaningful_prompt("<ide_selection>The user selected lines 1 to 227 …") === nothing
    @test BW.meaningful_prompt("<ide_opened_file>The user opened /x/a.md") === nothing

    # Real prose survives, and leading context blocks are stripped off it.
    @test BW.meaningful_prompt("fix the parser bug") == "fix the parser bug"
    @test BW.meaningful_prompt("<ide_selection>lines 1-2</ide_selection>Ich arbeite am Plan!") == "Ich arbeite am Plan!"
    @test BW.meaningful_prompt("<ide_opened_file>opened X</ide_opened_file>\n\nrun the tests") == "run the tests"
    # Multiple adjacent leading blocks (slash-command lines) are all consumed,
    # and an unknown leading tag is stripped just like a known one.
    @test BW.meaningful_prompt("<local-command-caveat>x</local-command-caveat><ide_opened_file>y</ide_opened_file>do the thing") == "do the thing"

    # Regression: this copy of the stripper used to bail at the first space in
    # the opener, so an attributed or self-closing wrapper leaked into the
    # preview whole. The server's copy had been fixed and this one had not —
    # which is why both now share AgentProviders.meaningful_prompt.
    @test BW.meaningful_prompt("<ide_selection file=\"a.jl\">lines 1-2</ide_selection>fix the parser bug") == "fix the parser bug"
    @test BW.meaningful_prompt("<command-args foo=\"x\"/>\nthe rest") == "the rest"
    @test BW.meaningful_prompt("<system-reminder kind=\"foo\">no closer here") === nothing

    # first_user_text: returns nothing for non-user / injected records, prose
    # (clean_preview-collapsed) for real ones.
    mkrec(content) = Dict("type"=>"user", "message"=>Dict("role"=>"user","content"=>content))
    @test BW.first_user_text(mkrec("<ide_opened_file>opened</ide_opened_file>")) === nothing
    @test BW.first_user_text(mkrec("hello   world")) == "hello world"
    @test BW.first_user_text(mkrec([Dict("type"=>"text","text"=>"<system-reminder>x</system-reminder>")])) === nothing
    @test BW.first_user_text(mkrec([Dict("type"=>"text","text"=>"real question?")])) == "real question?"
    @test BW.first_user_text(Dict("type"=>"assistant","message"=>Dict("role"=>"assistant","content"=>"hi"))) === nothing
end

# ── default_worker_name + generate_worker_id ─────────────────────────────────
@testset "default_worker_name" begin
    name = BW.default_worker_name("abcd-1234-5678-9012-345678901234")
    @test !isempty(name)
    @test !isnothing(name)
end

@testset "generate_worker_id" begin
    id = BW.generate_worker_id()
    @test length(id) == 36            # 8-4-4-4-12
    @test count(==('-'), id) == 4
    parts = split(id, '-')
    @test length.(parts) == [8, 4, 4, 4, 12]
    @test all(c -> isdigit(c) || ('a' <= lowercase(c) <= 'f'),
              filter(!=( '-'), id))
    # Two calls produce distinct ids (overlap → seed is wrong).
    @test BW.generate_worker_id() != BW.generate_worker_id()
end

# ── singleton pidfile guard ──────────────────────────────────────────────────
# A duplicate worker sharing the persisted worker_id fights the original over
# the server's control-WS registration. The pidfile guard makes start()/
# spawn_worker refuse when a live worker already holds the slot. We test the
# path-injectable predicates against a temp file so the real scratch pidfile is
# never touched (which would block the user's actual worker).
# ── ACP session discovery ────────────────────────────────────────────────────
# Discovery used to be Claude-only (a walk of ~/.claude/projects). Agents that
# implement ACP's `session/list` can be asked directly — kimi and opencode both
# advertise it. These guard the parts that don't need an agent installed.
@testset "acp session discovery" begin
    # ISO-8601 → epoch, matching the mtime the file scan reports.
    @test BW.acp_epoch("2026-07-29T10:04:35.131Z") ==
          BW.datetime2unix(BW.DateTime(2026, 7, 29, 10, 4, 35))
    # A session with no/garbage timestamp sorts last instead of throwing.
    @test BW.acp_epoch("") == 0.0
    @test BW.acp_epoch(nothing) == 0.0
    @test BW.acp_epoch("not-a-date") == 0.0
    # Newer sorts after older, so the UI's descending sort works.
    @test BW.acp_epoch("2026-07-29T10:04:35Z") > BW.acp_epoch("2026-07-27T13:02:47Z")

    # session/list returns the RAW first prompt, so a session started by a
    # provider switch is titled with the whole replayed transcript. The user's
    # real text follows the prelude's divider.
    @test BW.acp_title("hi what model are you using?") == "hi what model are you using?"
    @test BW.acp_title("Below is a transcript…\n\nMy new message:\n\nwhat model?") == "what model?"
    @test BW.acp_title("") == ""
    @test BW.acp_title(nothing) == ""
    # Divider with nothing after it has no user prose to show.
    @test BW.acp_title("Below is a transcript…\n\nMy new message:\n\n") == ""
    # Agents truncate the title (kimi ~200 chars), so the divider is often cut
    # off entirely — drop it rather than title the row with our own prelude.
    @test BW.acp_title("Below is a transcript of our previous conversation on this " *
                       "project. I'm continuing where we left off --- PREVIOUS CONVER") == ""

    # A provider whose binary isn't installed is skipped, not an error — a
    # machine with only Claude must still scan cleanly.
    withenv("KIMI_AGENT_ACP" => "/nonexistent/kimi",
            "MIMO_AGENT_ACP" => "/nonexistent/mimo",
            "OPENCODE_AGENT_ACP" => "/nonexistent/opencode") do
        AgentProviders.refresh_providers!()
        @test BW.scan_acp_providers() == Dict{String,Any}[]
    end
    AgentProviders.refresh_providers!()
end

@testset "pidfile singleton guard" begin
    mktempdir() do dir
        pf = joinpath(dir, "sub", "worker.pid")   # nested → also tests mkpath

        # Empty slot: no file → free.
        @test BW.read_pidfile(pf) === nothing
        @test BW.running_worker_pid(pf) === nothing

        # Our own pid recorded → not "another" worker (re-entry is fine).
        mkpath(dirname(pf))
        write(pf, string(getpid()))
        @test BW.read_pidfile(pf) == getpid()
        @test BW.running_worker_pid(pf) === nothing

        # Stale file pointing at a dead pid → slot free (overwritable).
        write(pf, "999999")
        @test BW.pid_running(999999) === false
        @test BW.running_worker_pid(pf) === nothing

        # A live OTHER pid → blocked. pid 1 (init/launchd) is always alive and
        # never us; on Unix kill(1,0) → EPERM which pid_running maps to true.
        write(pf, "1")
        @test BW.pid_running(1) === true
        @test BW.running_worker_pid(pf) == 1

        # Garbage content → nothing (never throws).
        write(pf, "not-a-pid")
        @test BW.read_pidfile(pf) === nothing
        @test BW.running_worker_pid(pf) === nothing

        # claim_pidfile! records our pid and creates parent dirs…
        rm(pf; force = true)
        BW.claim_pidfile!(pf)
        @test BW.read_pidfile(pf) == getpid()
        # …and WHICH julia we run on, so a re-install can tell a live worker on
        # another Julia from one on its own.
        @test BW.pidfile_julia(pf) == BW.julia_bin()

        # A pidfile from before that second line existed still yields its pid,
        # and says it doesn't know the julia.
        write(pf, "1")
        @test BW.read_pidfile(pf) == 1
        @test BW.pidfile_julia(pf) === nothing
        write(pf, "1\n")
        @test BW.read_pidfile(pf) == 1
        @test BW.pidfile_julia(pf) === nothing
    end
end

# The bug: `juliaup default 1.13`, install; trouble; `juliaup default 1.12`,
# re-install — and the 1.13 worker (with the 1.13 BonitoMCP launch command it
# had told the server about) stayed up, because "did the code change" was the
# only thing the installer looked at before deciding to leave it running.
@testset "re-install replaces a worker on another Julia" begin
    me = BW.julia_bin()
    @test BW.replace_reason(; force_restart = false, recorded_julia = me,
                              current_julia = me) === nothing
    r = BW.replace_reason(; force_restart = false,
                            recorded_julia = "/j/julia-1.13.0/bin/julia", current_julia = me)
    @test r isa String && occursin("1.13.0", r) && occursin(me, r)
    # Unknown (a pidfile predating the record) counts as different.
    @test BW.replace_reason(; force_restart = false, recorded_julia = nothing,
                              current_julia = me) isa String
    # Updated code restarts regardless.
    @test BW.replace_reason(; force_restart = true, recorded_julia = me,
                              current_julia = me) == "loading updated code"
end

# ── systemd service: unit rendering + run-mode decision ──────────────────────
# Only the PURE pieces are tested here — we never invoke `systemctl` (that would
# touch the real user systemd). render_service_unit is a pure string builder;
# decide_run_mode is the pure answer→mode map factored out of the tty IO.
@testset "service unit rendering" begin
    u = BW.render_service_unit(; julia = "/opt/julia/bin/julia",
                                 projects_root = "/home/u/projs",
                                 memory_max = "80%",
                                 path_env = "/usr/bin:/home/u/.local/bin")
    # ExecStart launches start() in the shared env.
    @test occursin("ExecStart=/opt/julia/bin/julia --project=@bonito-agents", u)
    @test occursin("BonitoWorker.start()", u)
    # PATH is baked in (systemd --user doesn't inherit the shell PATH; without
    # this the worker can't find claude-agent-acp/node/git at runtime).
    @test occursin("Environment=PATH=/usr/bin:/home/u/.local/bin", u)
    # Crash-restart, memory cap, boot target, workdir.
    @test occursin("Restart=on-failure", u)
    @test occursin("MemoryMax=80%", u)
    @test occursin("WantedBy=default.target", u)
    @test occursin("WorkingDirectory=/home/u/projs", u)
    # Pure: identical inputs → byte-identical output (so install can diff for
    # idempotency — only rewrite+reload when the unit actually changed).
    @test u == BW.render_service_unit(; julia = "/opt/julia/bin/julia",
                                        projects_root = "/home/u/projs",
                                        memory_max = "80%",
                                        path_env = "/usr/bin:/home/u/.local/bin")
end

# Which julia the worker launches its own processes with — the systemd unit, a
# respawn, and the BonitoMCP server claude-agent-acp starts per chat. All three
# used to bake `Sys.BINDIR`, which under juliaup is a VERSION-specific directory
# the next `juliaup update` deletes — systemd then restart-loops on a missing
# binary until someone re-runs the installer, with the worker absent throughout
# (41 failed EXECs in 2.5 minutes, observed), and every new chat's `bt_*` tools
# fail to start until the worker is restarted.
@testset "julia launcher" begin
    channel = BW.julia_channel()
    # A CHANNEL, not a patch version: juliaup registers `1.12`, so `+1.12.7` is
    # rejected with "not installed" while `+1.12` follows the channel forward.
    @test occursin(r"^\d+\.\d+$", channel)
    @test channel == "$(VERSION.major).$(VERSION.minor)"

    # The probe is the whole safety of this: writing a launch command we never
    # ran is the mistake being undone here, and a wrong one stays invisible until
    # the next restart.
    @test BW.launcher_resolves_here("/nonexistent/julia-xyz", channel) === false
    # Exists and is executable, but is not a launcher — exits 0 and prints the
    # wrong thing, so the BINDIR comparison is what rejects it, not the status.
    Sys.isunix() && @test BW.launcher_resolves_here("/bin/echo", channel) === false
    # The version-pinned binary we are RUNNING is not a launcher either: a plain
    # julia reads `+1.12` as a script name and exits non-zero. Important, or the
    # fallback would dress the old pinned path up as a fixed one.
    @test BW.launcher_resolves_here(BW.julia_bin(), channel) === false
    # A launcher asked for a channel that isn't registered must not pass.
    for exe in BW.juliaup_launcher_candidates()
        isfile(exe) && @test BW.launcher_resolves_here(exe, "0.1") === false
    end

    launcher = BW.julia_launcher()
    exe  = BW.mcp_exe(launcher)
    args = BW.mcp_args(launcher)
    @test isfile(exe)
    if launcher.exec == [BW.julia_bin()]
        # No launcher on this machine (a plain install). That is the documented
        # fallback and it does not have the problem either — nothing deletes a
        # plain install's bindir out from under it.
        @test startswith(args[1], "--project=")
    else
        # A launcher was found AND probed. It must be pinned to the channel,
        # otherwise `juliaup default <other>` silently moves the worker onto a
        # different Julia — the failure mode a bare launcher trades for.
        @test launcher.exec == [exe, "+" * channel]
        # And it must NOT be the version-specific path, which is the whole point.
        @test exe != BW.julia_bin()
        @test !occursin(string(VERSION), exe)
        # The pin rides FIRST in the MCP argv — julialauncher only reads it there.
        @test args[1] == "+" * channel
        @test startswith(args[2], "--project=")
    end
    @test args[end-1:end] == ["-e", "using BonitoMCP; BonitoMCP.run_stdio()"]

    # The composed command — command + argv exactly as the MCP config carries
    # them, minus the `-e` payload — has to land on THIS julia. The probe checked
    # `exe +channel` alone; this checks what actually gets exec'd.
    bindir = read(`$(exe) $(args[1:end-2]) -e $("print(Sys.BINDIR)")`, String)
    @test strip(bindir) == Sys.BINDIR

    # The unit execs the same thing, as text.
    cmd = BW.service_julia_cmd()
    @test cmd == join(launcher.exec, ' ')
    @test occursin("ExecStart=$(cmd) --project=@bonito-agents",
                   BW.render_service_unit(; projects_root = "/tmp", memory_max = "80%",
                                            path_env = "/usr/bin"))
end

# ── the debug checkout: BonitoAgents' source, on this worker ─────────────────
# The "Debug BonitoAgents" chat runs on a worker and needs the source THERE. It
# used to assume the server's own checkout path existed on the worker — true on
# one developer's machine and nowhere else.
@testset "source checkout" begin
    @test !BW.is_monorepo_root(mktempdir())
    root = BW.source_checkout_root()
    if root === nothing
        @info "not running from a checkout — skipping the running-checkout case"
    else
        # This suite runs from the monorepo (BonitoWorker is a path dep), so the
        # worker knows its own checkout…
        @test ispath(joinpath(root, ".git"))
        @test isfile(joinpath(root, "BonitoWorker", "Project.toml"))
        @test isfile(joinpath(root, "BonitoAgents", "Project.toml"))
        # …answers with it, and clones nothing (the repo url is unreachable on
        # purpose: touching it would be the failure).
        r = BW.debug_checkout(; repo = "https://example.invalid/none.git", rev = "main",
                                packages = ["BonitoWorker"])
        @test r.mode == "running" && r.path == root && !r.created
    end

    if Sys.which("git") === nothing
        @info "git not on PATH — skipping the clone case"
    else
        mktempdir() do dir
            # A stand-in monorepo: one tiny package, two commits, as a repo to
            # clone from. `rev` asks for the FIRST commit, so the checkout has
            # to land on the requested revision rather than the branch head.
            src = joinpath(dir, "src-repo")
            mkpath(joinpath(src, "Tiny", "src"))
            write(joinpath(src, "Tiny", "Project.toml"),
                  "name = \"Tiny\"\nuuid = \"1b3e1b6e-1a2b-4c3d-9e8f-0123456789ab\"\nversion = \"0.1.0\"\n")
            tiny_src = joinpath(src, "Tiny", "src", "Tiny.jl")
            write(tiny_src, "module Tiny\nanswer() = 1\nend\n")
            gitq(args...) = run(pipeline(
                `git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -C $src $(collect(args))`;
                stdout = devnull, stderr = devnull))
            gitq("init", "-q")
            gitq("add", "-A"); gitq("commit", "-q", "-m", "first")
            first_sha = strip(read(`git -C $src rev-parse HEAD`, String))
            write(tiny_src, "module Tiny\nanswer() = 2\nend\n")
            gitq("commit", "-q", "-a", "-m", "second")

            # The environment to develop into: a throwaway project, like a
            # worker's `@bonito-agents` before this.
            env  = joinpath(dir, "env")
            proj = joinpath(env, "Project.toml")
            mkpath(env); write(proj, "")
            log  = joinpath(dir, "develop.log")
            kw   = (; repo = src, rev = first_sha, packages = ["Tiny", "NotThere"],
                      project = proj, running_root = nothing, logfile = log)
            r = BW.debug_checkout(; kw...)
            @test r.mode == "developed" && r.created
            # `dev --local`: next to the project, under dev/, named after the repo.
            @test r.path == joinpath(env, "dev", "BonitoAgents")
            @test strip(read(`git -C $(r.path) rev-parse HEAD`, String)) == first_sha
            @test occursin("answer() = 1", read(joinpath(r.path, "Tiny", "src", "Tiny.jl"), String))
            # …and developed: the environment's manifest tracks it by path.
            manifest = Base.parsed_toml(joinpath(env, "Manifest.toml"))
            tiny = only(manifest["deps"]["Tiny"])
            @test endswith(replace(tiny["path"], '\\' => '/'), "dev/BonitoAgents/Tiny")
            @test isfile(log)

            # A repeat finds the checkout, does not re-clone, and leaves the
            # user's edits alone — a debugging session's work must survive the
            # button being pressed again.
            write(joinpath(r.path, "Tiny", "src", "Tiny.jl"), "module Tiny\nanswer() = 42\nend\n")
            r2 = BW.debug_checkout(; kw...)
            @test !r2.created && r2.path == r.path && r2.mode == "developed"
            @test occursin("answer() = 42", read(joinpath(r.path, "Tiny", "src", "Tiny.jl"), String))

            # Something that is not a checkout in the way is an error, not a
            # deletion: only a clone WE made is ever removed.
            env2 = joinpath(dir, "env2"); mkpath(joinpath(env2, "dev", "BonitoAgents"))
            write(joinpath(env2, "dev", "BonitoAgents", "keep.txt"), "mine")
            write(joinpath(env2, "Project.toml"), "")
            @test_throws ErrorException BW.debug_checkout(; kw..., project = joinpath(env2, "Project.toml"))
            @test isfile(joinpath(env2, "dev", "BonitoAgents", "keep.txt"))

            # A clone that fails says why (git's own words) and leaves nothing
            # behind for the retry to trip on.
            env3 = joinpath(dir, "env3"); mkpath(env3); write(joinpath(env3, "Project.toml"), "")
            err = try
                BW.debug_checkout(; kw..., repo = joinpath(dir, "no-such-repo"),
                                  project = joinpath(env3, "Project.toml")); ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("git clone", err) && occursin("no-such-repo", err)
            @test !ispath(joinpath(env3, "dev", "BonitoAgents"))
        end
    end
end

# ── Session state transport ("continue this chat on another worker") ─────────
# The worker's half of carrying an agent's conversation across machines: stage
# a session's record out of the provider's transcript dir, install a staged one
# under a NEW working directory with the recorded cwd rewritten, and refuse any
# staging path outside the transfer folder.
@testset "session state transport" begin
    AP = BW.AgentProviders
    fmt = AP.session_state_format(AP.ClaudeCodeAgent())
    @test fmt isa AP.JsonlTranscripts
    @test AP.session_state_format(AP.KimiAgent()) === nothing
    # Claude Code's folder encoding: everything outside [A-Za-z0-9] becomes '-'.
    @test AP.claude_project_key("/home/u/Foo.jl/my_pkg") == "-home-u-Foo-jl-my-pkg"
    @test AP.transcript_dir(fmt, "/h", "/a/b") == joinpath("/h", ".claude", "projects", "-a-b")

    mktempdir() do dir
        home_a = joinpath(dir, "home-a"); home_b = joinpath(dir, "home-b")
        cwd_a  = joinpath(dir, "proj.jl"); cwd_b = joinpath(dir, "elsewhere", "proj.jl")
        sid    = "11111111-2222-3333-4444-555555555555"
        tdir_a = AP.transcript_dir(fmt, home_a, cwd_a)
        mkpath(tdir_a)
        # The transcript names its cwd on most lines, in compact JSON like Claude
        # Code writes it; one line carries a path with a JSON-escaped character so
        # the rewrite is checked in encoded form, not on raw text.
        line(t, cwd) = "{\"type\":\"$(t)\",\"cwd\":$(BW.JSON.json(cwd)),\"sessionId\":\"$(sid)\"}"
        write(joinpath(tdir_a, sid * ".jsonl"),
              join([line("user", cwd_a), "{\"type\":\"queue-operation\",\"cwd\":null}",
                    line("assistant", cwd_a)], "\n") * "\n")
        mkpath(joinpath(tdir_a, sid, "subagents"))
        write(joinpath(tdir_a, sid, "subagents", "agent-1.jsonl"), line("user", cwd_a) * "\n")
        mkpath(joinpath(tdir_a, "memory"))
        write(joinpath(tdir_a, "memory", "MEMORY.md"), "- moved fact\n")
        write(joinpath(tdir_a, "memory", "a.md"), "A")
        # An unrelated session in the same dir must NOT travel.
        write(joinpath(tdir_a, "other.jsonl"), line("user", cwd_a) * "\n")

        # Staging must sit under the transfer folder — anything else is refused
        # before a byte is touched.
        @test_throws ErrorException BW.stage_session(; provider = "ClaudeCode", cwd = cwd_a,
            session_id = sid, staging = joinpath(dir, "loose"), home = home_a)
        @test !ispath(joinpath(dir, "loose"))
        @test_throws ErrorException BW.discard_staging(; staging = joinpath(dir, "proj.jl"))
        @test isdir(cwd_a) || !ispath(cwd_a)   # untouched either way

        staging_a = joinpath(dir, "root-a", AP.TRANSFER_DIRNAME, "pid1")
        # A provider without a record, and a session without a transcript, both say so.
        @test_throws ErrorException BW.stage_session(; provider = "KimiCode", cwd = cwd_a,
            session_id = sid, staging = staging_a, home = home_a)
        err = try
            BW.stage_session(; provider = "ClaudeCode", cwd = cwd_a, session_id = "nope",
                               staging = staging_a, home = home_a); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("no transcript", err)
        @test !ispath(staging_a)

        r = BW.stage_session(; provider = "ClaudeCode", cwd = cwd_a, session_id = sid,
                               staging = staging_a, home = home_a)
        @test r.path == staging_a
        @test sort(r.entries) == sort([sid * ".jsonl", sid, "memory"])
        @test r.bytes > 0
        @test isfile(joinpath(staging_a, sid * ".jsonl"))
        @test isfile(joinpath(staging_a, sid, "subagents", "agent-1.jsonl"))
        @test isfile(joinpath(staging_a, "memory", "MEMORY.md"))
        @test !ispath(joinpath(staging_a, "other.jsonl"))
        # The source keeps its copy (the move may still fail later).
        @test isfile(joinpath(tdir_a, sid * ".jsonl"))

        # Land it on "worker B" under a different cwd, where a memory dir already
        # exists: merged, with the moved files winning on a name clash.
        staging_b = joinpath(dir, "root-b", AP.TRANSFER_DIRNAME, "pid1")
        mkpath(dirname(staging_b)); mv(staging_a, staging_b)
        tdir_b = AP.transcript_dir(fmt, home_b, cwd_b)
        mkpath(joinpath(tdir_b, "memory"))
        write(joinpath(tdir_b, "memory", "a.md"), "B")
        write(joinpath(tdir_b, "memory", "b.md"), "only here")
        r2 = BW.install_session(; provider = "ClaudeCode", cwd = cwd_b, old_cwd = cwd_a,
                                  session_id = sid, staging = staging_b, home = home_b)
        @test r2.path == tdir_b
        @test sort(r2.entries) == sort([sid * ".jsonl", sid, "memory"])
        @test !ispath(staging_b)
        moved = read(joinpath(tdir_b, sid * ".jsonl"), String)
        @test count("\"cwd\":" * BW.JSON.json(cwd_b), moved) == 2
        @test !occursin(BW.JSON.json(cwd_a), moved)
        @test occursin("\"cwd\":null", moved)                 # untouched lines survive
        @test occursin(BW.JSON.json(cwd_b),
                       read(joinpath(tdir_b, sid, "subagents", "agent-1.jsonl"), String))
        @test read(joinpath(tdir_b, "memory", "MEMORY.md"), String) == "- moved fact\n"
        @test read(joinpath(tdir_b, "memory", "a.md"), String) == "A"
        @test read(joinpath(tdir_b, "memory", "b.md"), String) == "only here"

        # Discard removes the staging dir — and the transfer folder itself once
        # it is empty, so nothing is left under the projects root. Another
        # move's staging keeps the folder.
        @test !ispath(dirname(staging_b))          # install cleaned B's up too
        again = BW.stage_session(; provider = "ClaudeCode", cwd = cwd_a, session_id = sid,
                                   staging = staging_a, home = home_a)
        @test isdir(again.path)
        other = joinpath(dirname(staging_a), "pid2"); mkpath(other)
        BW.discard_staging(; staging = staging_a)
        @test !ispath(staging_a) && isdir(dirname(staging_a))
        rm(other)
        BW.discard_staging(; staging = staging_a)   # nothing to remove, folder now empty
        @test !ispath(dirname(staging_a))

        # Same cwd on both sides (a worker whose projects root matches): no rewrite.
        @test BW.relocate_transcripts!(fmt, tdir_b, cwd_b, cwd_b) == 0
    end
end

@testset "run-mode decision" begin
    # Explicit answers.
    @test BW.decide_run_mode("1", false) == :service
    @test BW.decide_run_mode("1", true)  == :service
    @test BW.decide_run_mode("2", false) == :background
    @test BW.decide_run_mode("2", true)  == :background
    @test BW.decide_run_mode("", false)  == :service       # bare Enter → default
    @test BW.decide_run_mode("yes", true) == :service      # anything not "2" → service
    # No answer (no tty / timed out): keep an existing service, else background —
    # never silently enable a boot service in a non-interactive context, never
    # silently downgrade an existing one.
    @test BW.decide_run_mode(nothing, true)  == :service
    @test BW.decide_run_mode(nothing, false) == :background
end

# ── file_writer_pids / kill_file_writers (background-shell stop) ────────────
# The direct stop for a background bash: the shell holds its `>> output`
# redirect open until it exits, so the file's writers ARE the shell. Linux
# only (/proc scan); other OSes report no holders (the caller still
# finalizes the UI).
@testset "file_writer_pids + kill" begin
    if Sys.islinux()
        mktempdir() do dir
            path = joinpath(dir, "held.output")
            write(path, "seed\n")
            # A child shell that holds `path` open (append) and sleeps.
            proc = run(pipeline(`bash -c "exec sleep 30"`; stdout = path, append = true);
                       wait = false)
            # Give it a moment to open the fd.
            sleep(0.5)
            pids = BW.file_writer_pids(path)
            @test getpid(proc) in pids
            @test !(getpid() in pids)        # never our own process

            BW.handle_kill_file_writers(NullWS(), Dict("request_id" => "r",
                                                       "path" => path))
            @test timedwait(() -> !process_running(proc), 5.0) === :ok
            @test isempty(BW.file_writer_pids(path))
        end
    else
        @test isempty(BW.file_writer_pids(tempname()))
    end
end

# The review tab's repository scan. Pure filesystem work on temp trees — no
# subprocess, no git binary needed (a `.git` entry is all `find_repos` looks for,
# which is also all git itself looks for).
include("test_find_repos.jl")

end  # BonitoWorker

# Stability regressions (M1 clone_repo data-loss guard, M8/M12/M13). Pure unit
# tests — no subprocess, no network.
include("test_stability.jl")

# Agent subprocess reaping (process group + startup stray sweep). Spawns
# short-lived `sleep`/`bash` children only — no agent, no network.
include("test_agent_reaping.jl")

# Real-agent integration test — separate file because it boots a subprocess
# and stands up an HTTP+WS server. Skipped automatically when
# claude-agent-acp isn't on PATH (so unit-only environments stay green).
include("test_real_agent.jl")

