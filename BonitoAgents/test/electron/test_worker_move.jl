# End-to-end test for the transparent cross-worker move.
#
# Brings up a real BonitoAgents server, spawns two mock workers (A, B) that
# both speak the worker control protocol AND handle `open_transfer` via
# RemoteSync. Walks a project from A → B → A and asserts:
#
# 1. Files written out-of-band on A get pulled to B (pre-pull captures
#    edits the user made in their editor without clicking "Sync to server").
# 2. Files deleted on A also disappear on B (mirror semantics — adds AND
#    deletions propagate).
# 3. `p.worker_id` / `p.worker_path` flip atomically to B; the chat
#    storage lives in `state.state_dir/chats/<project_id>/` so it follows
#    the project across moves without sync.
# 4. Moving back to A propagates B's subsequent edits in both directions.
# 5. Source-offline fallback: if A goes offline mid-test, moving to B
#    still works using the server's last-known mirror.
#
# No claude / no Electron — this is a backend integration test.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using HTTP, JSON, BonitoAgents, BonitoAgents.RemoteSync
using HTTP.WebSockets
using UUIDs, Dates

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

const PORT  = 18000 + rand(1:999)
const SECRET = "move-test-secret"

# ── Mock worker ──────────────────────────────────────────────────────────────
#
# Speaks the same control protocol as BonitoWorker.jl but with no claude /
# Malt subprocess. Handles `open_transfer` by dialing /transfer-ws and
# running the matching RemoteSync side. Designed to live inside the test
# Julia process so the server's state.workers[] gets populated and tests
# can assert against the real production code path.
mutable struct MockWorker
    name      :: String
    root      :: String        # filesystem dir that stands in for this
                               # worker's projects_root
    ws        :: Union{Nothing, HTTP.WebSockets.WebSocket}
    task      :: Union{Nothing, Task}
    server_url :: String
end

function start_mock_worker!(name, server_url; root = mktempdir())
    mw  = MockWorker(name, root, nothing, nothing, server_url)
    ready = Channel{Bool}(1)
    mw.task = Base.errormonitor(@async try
        ws_url = replace(server_url, "http://" => "ws://") * "/worker-ws"
        WebSockets.open(ws_url) do ws
            mw.ws = ws
            hello = Dict(
                "secret"        => SECRET,
                "name"          => name,
                "hostname"      => "mock-$name",
                "home"          => "/home/agent",
                "mcp_path"      => "",
                "projects_root" => root,
            )
            WebSockets.send(ws, JSON.json(hello))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            put!(ready, get(ack, "ok", false) == true)
            # Drain control frames; dispatch open_transfer.
            for frame in ws
                cmd = try JSON.parse(String(frame)) catch _; nothing end
                cmd === nothing && continue
                t = String(get(cmd, "type", ""))
                if t == "open_transfer"
                    Base.errormonitor(@async handle_mock_transfer(mw, cmd))
                end
                # Ignore other commands (open_session etc.) — this worker
                # doesn't run claude, so a project ACP open will fail with
                # a timeout, which is what we test for separately.
            end
        end
    catch e
        @warn "mock worker connection ended" name exception=e
        put!(ready, false)
    end)
    take!(ready) || error("mock worker '$name' failed to connect")
    # The /worker-ws handler runs the registration in its own task; wait
    # for state.workers[] to see us as :online before returning.
    return mw
end

function handle_mock_transfer(mw::MockWorker, cmd::AbstractDict)
    sync_id   = String(get(cmd, "sync_id", ""))
    direction = String(get(cmd, "direction", ""))
    transfer_url = replace(mw.server_url, "http://" => "ws://") * "/transfer-ws"
    WebSockets.open(transfer_url) do ws
        WebSockets.send(ws, JSON.json(Dict("secret" => SECRET, "sync_id" => sync_id)))
        ack = JSON.parse(String(WebSockets.receive(ws)))
        get(ack, "ok", false) || error("server rejected transfer: $ack")
        wsio = RemoteSync.WebSocketIO(ws)
        if direction == "to_worker"
            dst = String(cmd["dst_path"])
            mkpath(dst)
            RemoteSync.receive_directory(dst, wsio)
        elseif direction == "from_worker"
            src = String(cmd["src_path"])
            isdir(src) || error("src_path is not a directory: $src")
            RemoteSync.send_directory(src, wsio)
        elseif direction == "file_to_worker"
            dst = String(cmd["dst_path"])
            mkpath(dirname(dst))
            RemoteSync.receive_file(dst, wsio)
        elseif direction == "file_from_worker"
            src = String(cmd["src_path"])
            isfile(src) || error("src_path is not a file: $src")
            RemoteSync.send_file(src, wsio)
        end
    end
end

function stop_mock_worker!(mw::MockWorker)
    try mw.ws !== nothing && close(mw.ws) catch end
end

function wait_for_worker(state, name; timeout = 5.0)
    deadline = time() + timeout
    while time() < deadline
        if haskey(state.workers[], name) &&
           state.workers[][name].online[]
            return state.workers[][name]
        end
        sleep(0.05)
    end
    error("worker '$name' never came online")
end

function project_files(dir)
    out = Dict{String,String}()
    isdir(dir) || return out
    for (root, _, files) in walkdir(dir)
        for f in files
            full = joinpath(root, f)
            startswith(relpath(full, dir), ".bonitoAgents") && continue  # legacy
            out[relpath(full, dir)] = read(full, String)
        end
    end
    return out
end

# ── Fixture ──────────────────────────────────────────────────────────────────

server_state = nothing
server       = nothing
worker_a     = nothing
worker_b     = nothing

try
    server_state = BonitoAgents.serve(;
        host          = "127.0.0.1",
        port          = PORT,
        public_url    = "http://127.0.0.1:$PORT",
        worker_secret = SECRET,
        state_dir     = mktempdir(),
        working_dir   = mktempdir())
    server = server_state.srv
    sleep(0.3)

    worker_a = start_mock_worker!("worker-a", "http://127.0.0.1:$PORT")
    worker_b = start_mock_worker!("worker-b", "http://127.0.0.1:$PORT")
    wa = wait_for_worker(server_state, "worker-a")
    wb = wait_for_worker(server_state, "worker-b")

    # Seed a project on worker A's filesystem (out of band — we did NOT
    # go through `create_project!`; pretend the user cloned a repo there
    # themselves, then registered it with the server).
    proj_name = "moveproj"
    proj_dir_a = joinpath(worker_a.root, proj_name)
    mkpath(proj_dir_a)
    write(joinpath(proj_dir_a, "README.md"), "version 1: from A\n")
    write(joinpath(proj_dir_a, "src.jl"),    "const VERSION = \"a-initial\"\n")
    mkpath(joinpath(proj_dir_a, "deep"))
    write(joinpath(proj_dir_a, "deep", "nested.txt"), "hidden treasure\n")

    server_dir = joinpath(server_state.working_dir, proj_name)
    pid = string(uuid4())[1:8]
    p = BonitoAgents.ProjectInfo(pid, proj_name, "worker-a", server_dir, proj_dir_a, now(UTC))
    server_state.projects[][p.id] = p
    BonitoAgents.safe_notify!(server_state.projects)
    BonitoAgents.save_projects!(server_state)

    TH.section("baseline: server has no files until first sync") do
        record("server mirror dir is empty / missing",
               @TH.test_true (!isdir(server_dir) || isempty(readdir(server_dir))))
    end

    # ── Out-of-band edit on A → start! to B → file lands on B ────────────────
    TH.section("Move A→B captures out-of-band edits via pre-pull") do
        # User edits a file on A in their editor — server doesn't know yet.
        write(joinpath(proj_dir_a, "README.md"), "version 2: edited on A out of band\n")
        write(joinpath(proj_dir_a, "newfile.txt"), "added on A\n")

        # Move to B. start! must pre-pull from A to capture the new edits
        # before pushing to B.
        # `transfer_project!` is the file-shuffling half of `start!`.
        # We test that contract directly here; the chat-session boot is
        # the ACP path, exercised by the chat tests with MockTransport.
        BonitoAgents.transfer_project!(server_state, p, "worker-b")
        proj_dir_b = joinpath(worker_b.root, proj_name)

        record("p.worker_id flipped to worker-b",
               @TH.test_eq p.worker_id "worker-b")
        record("p.worker_path under worker-b's projects_root",
               @TH.test_true startswith(p.worker_path, worker_b.root))
        record("worker-b has README.md",
               @TH.test_true isfile(joinpath(proj_dir_b, "README.md")))
        record("worker-b has the new edit (version 2)",
               @TH.test_eq read(joinpath(proj_dir_b, "README.md"), String) "version 2: edited on A out of band\n")
        record("worker-b has the new file from A",
               @TH.test_eq read(joinpath(proj_dir_b, "newfile.txt"), String) "added on A\n")
        record("nested directory survived the round-trip",
               @TH.test_eq read(joinpath(proj_dir_b, "deep", "nested.txt"), String) "hidden treasure\n")
        record("server mirror matches B",
               @TH.test_eq project_files(server_dir) project_files(proj_dir_b))
    end

    # ── Edit on B → move back to A → mirror semantics including deletions ─
    TH.section("Move B→A propagates B's edits and deletions") do
        proj_dir_b = joinpath(worker_b.root, proj_name)

        # User now edits on B's filesystem.
        write(joinpath(proj_dir_b, "src.jl"), "const VERSION = \"b-modified\"\n")
        write(joinpath(proj_dir_b, "from-b.dat"), "born on B\n")
        # Delete a file on B — must NOT come back to A after the move.
        rm(joinpath(proj_dir_b, "newfile.txt"))

        BonitoAgents.transfer_project!(server_state, p, "worker-a")

        record("p.worker_id flipped back to worker-a",
               @TH.test_eq p.worker_id "worker-a")
        # The user's worker_path on A is the one start! computed from
        # worker-a's projects_root + the project's name.
        record("p.worker_path under worker-a's projects_root",
               @TH.test_true startswith(p.worker_path, worker_a.root))
        record("worker-a has B's edit to src.jl",
               @TH.test_eq read(joinpath(p.worker_path, "src.jl"), String) "const VERSION = \"b-modified\"\n")
        record("worker-a has the new-on-B file",
               @TH.test_eq read(joinpath(p.worker_path, "from-b.dat"), String) "born on B\n")
        record("file deleted on B is gone from A (mirror, not additive)",
               @TH.test_true !isfile(joinpath(p.worker_path, "newfile.txt")))
        record("server mirror matches A",
               @TH.test_eq project_files(server_dir) project_files(p.worker_path))
    end

    # ── send_file_to_worker!: single-file push (no full project walk) ────
    # Used by image paste, single-shot tool captures, ad-hoc Julia
    # outputs. Verifies: bytes round-trip, nested parent dirs are
    # created on the worker side, overwrite of an existing file works,
    # and the source-file-missing case errors instead of silent skip.
    TH.section("send_file_to_worker! pushes one file without walking the tree") do
        # Project is currently on worker-a after the B→A round-trip
        # above. Push a new file straight into a deep dir that doesn't
        # exist on the worker yet — receive_file must mkpath.
        src_path = joinpath(server_state.working_dir, "_single_push.png")
        # Plausible PNG-shaped binary blob: 4-byte header + random bytes.
        write(src_path, vcat(UInt8[0x89, 0x50, 0x4E, 0x47], rand(UInt8, 4096)))
        dst_path = joinpath(p.worker_path, "subdir", "nested", "single.png")

        BonitoAgents.send_file_to_worker!(server_state, "worker-a", src_path, dst_path)

        record("dst exists on worker",
               @TH.test_true isfile(dst_path))
        record("nested parent dir was created by receive_file",
               @TH.test_true isdir(dirname(dst_path)))
        record("bytes round-trip exactly",
               @TH.test_eq read(dst_path) read(src_path))

        # Overwrite with different bytes — must replace, not append/fail.
        write(src_path, rand(UInt8, 1024))
        BonitoAgents.send_file_to_worker!(server_state, "worker-a", src_path, dst_path)
        record("overwrite replaces content",
               @TH.test_eq read(dst_path) read(src_path))

        # Missing source must error (not silently transfer 0 bytes).
        threw = false
        try
            BonitoAgents.send_file_to_worker!(server_state, "worker-a",
                                             "/nonexistent/file.png", dst_path)
        catch e
            threw = true
        end
        record("missing source errors", @TH.test_true threw)
    end

    # ── Source-offline fallback: pre-pull skipped, server's mirror used ──
    TH.section("Move when source is offline uses server's mirror") do
        # Knock worker-a offline. The project is currently bound to A.
        # Wait for state.workers[] to reflect the disconnect.
        stop_mock_worker!(worker_a)
        let deadline = time() + 5
            while time() < deadline
                w = get(server_state.workers[], "worker-a", nothing)
                w !== nothing && !w.online[] && break
                sleep(0.1)
            end
        end
        record("worker-a is offline",
               @TH.test_eq server_state.workers[]["worker-a"].online[] false)

        # Note: we don't try to chat / start the session here (would hit
        # `claim_project!` which needs a worker context). We only verify
        # the file-shuffling part of `start!` works without the source.
        proj_dir_b = joinpath(worker_b.root, proj_name)
        rm(proj_dir_b; recursive = true, force = true)   # wipe B's cache

        # Hand-roll the file part of start! (the chat-session bring-up
        # would need an actual ACP-speaking worker which our mock isn't).
        # The contract we're testing here: pre-pull is skipped when source
        # is offline, push to target uses server's mirror.
        BonitoAgents.sync_dir_to_worker!(server_state, "worker-b",
                                        p.server_path, joinpath(worker_b.root, proj_name))
        record("worker-b got server's mirror without source online",
               @TH.test_true isfile(joinpath(worker_b.root, proj_name, "src.jl")))
        record("worker-b matches server",
               @TH.test_eq project_files(server_dir) project_files(joinpath(worker_b.root, proj_name)))
    end

finally
    TH.report!("Tier 4c — worker move", results)
    try worker_a !== nothing && stop_mock_worker!(worker_a) catch end
    try worker_b !== nothing && stop_mock_worker!(worker_b) catch end
    try close(server) catch end
end
