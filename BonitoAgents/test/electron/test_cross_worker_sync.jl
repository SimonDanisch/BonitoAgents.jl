# Backend integration test for the explicit cross-worker sync flow.
#
# Two workers (A, B) each carry a project with the SAME display name
# ("BonitoAgents"). Because `compute_server_path` prefixes the worker name,
# their server-side mirrors live side-by-side instead of colliding. This
# test exercises the reconcile path that replaced the old import-time
# collision modal:
#
# 1. `same_name_siblings` pairs A's project with B's (and only across a
#    DIFFERENT worker).
# 2. `compare_projects` returns live summaries for both sides.
# 3. `sync_across_workers!(A, B)` is a directional overwrite — B's tree
#    ends up matching A (adds AND deletions), the source is untouched, and
#    the server mirror is left consistent with the target.
#
# No claude / no Electron — like test_worker_move.jl this drives the real
# server + RemoteSync over loopback with in-process mock workers. The mock
# here additionally answers `inspect_path` so `compare_projects` works.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using HTTP, JSON, BonitoAgents, BonitoAgents.RemoteSync
using HTTP.WebSockets
using UUIDs, Dates

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

const XS_PORT   = 18000 + rand(1:999)
const XS_SECRET = "xsync-test-secret"

# ── Mock worker ───────────────────────────────────────────────────────────────
# Speaks the control protocol; handles `open_transfer` (RemoteSync) and
# `inspect_path` (defers to BonitoWorker.inspect_path_summary). Distinct
# names from test_worker_move.jl's MockWorker so both can load in one suite.
mutable struct XSyncWorker
    name      :: String
    root      :: String
    ws        :: Union{Nothing, HTTP.WebSockets.WebSocket}
    task      :: Union{Nothing, Task}
    server_url :: String
end

function start_xsync_worker!(name, server_url; root = mktempdir())
    mw = XSyncWorker(name, root, nothing, nothing, server_url)
    ready = Channel{Bool}(1)
    mw.task = Base.errormonitor(@async try
        ws_url = replace(server_url, "http://" => "ws://") * "/worker-ws"
        WebSockets.open(ws_url) do ws
            mw.ws = ws
            WebSockets.send(ws, JSON.json(Dict(
                "secret"        => XS_SECRET,
                "name"          => name,
                "hostname"      => "mock-$name",
                "home"          => "/home/agent",
                "mcp_path"      => "",
                "projects_root" => root)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            put!(ready, get(ack, "ok", false) == true)
            for frame in ws
                cmd = try JSON.parse(String(frame)) catch _; nothing end
                cmd === nothing && continue
                t = String(get(cmd, "type", ""))
                if t == "open_transfer"
                    Base.errormonitor(@async handle_xsync_transfer(mw, cmd))
                elseif t == "inspect_path"
                    Base.errormonitor(@async handle_xsync_inspect(mw, cmd))
                end
            end
        end
    catch e
        @warn "xsync worker connection ended" name exception=e
        put!(ready, false)
    end)
    take!(ready) || error("xsync worker '$name' failed to connect")
    return mw
end

function handle_xsync_transfer(mw::XSyncWorker, cmd::AbstractDict)
    sync_id   = String(get(cmd, "sync_id", ""))
    direction = String(get(cmd, "direction", ""))
    transfer_url = replace(mw.server_url, "http://" => "ws://") * "/transfer-ws"
    WebSockets.open(transfer_url) do ws
        WebSockets.send(ws, JSON.json(Dict("secret" => XS_SECRET, "sync_id" => sync_id)))
        ack = JSON.parse(String(WebSockets.receive(ws)))
        get(ack, "ok", false) || error("server rejected transfer: $ack")
        wsio = RemoteSync.WebSocketIO(ws)
        if direction == "to_worker"
            # Honor quick_check like the real BonitoWorker: the server sends
            # quick_check=false for directional overwrites so same-size
            # same-mtime divergent files are still delta-checked.
            dst = String(cmd["dst_path"]); mkpath(dst)
            qc  = get(cmd, "quick_check", true) === true
            RemoteSync.receive_directory(dst, wsio; quick_check = qc)
        elseif direction == "from_worker"
            src = String(cmd["src_path"])
            isdir(src) || error("src_path is not a directory: $src")
            RemoteSync.send_directory(src, wsio)
        end
    end
end

function handle_xsync_inspect(mw::XSyncWorker, cmd::AbstractDict)
    rid = String(get(cmd, "request_id", ""))
    path = String(get(cmd, "path", ""))
    resp = try
        Dict("type" => "inspect_path_response", "request_id" => rid,
             "path" => path, "summary" => BonitoAgents.BonitoWorker.inspect_path_summary(path))
    catch e
        Dict("type" => "inspect_path_response", "request_id" => rid,
             "error" => sprint(showerror, e))
    end
    WebSockets.send(mw.ws, JSON.json(resp))
end

stop_xsync_worker!(mw::XSyncWorker) = (try mw.ws !== nothing && close(mw.ws) catch end)

function wait_xsync_worker(state, name; timeout = 5.0)
    deadline = time() + timeout
    while time() < deadline
        haskey(state.workers[], name) && state.workers[][name].online[] && return
        sleep(0.05)
    end
    error("worker '$name' never came online")
end

function xsync_files(dir)
    out = Dict{String,String}()
    isdir(dir) || return out
    for (root, _, files) in walkdir(dir), f in files
        full = joinpath(root, f)
        out[relpath(full, dir)] = read(full, String)
    end
    return out
end

# ── Fixture ────────────────────────────────────────────────────────────────────

server_state = nothing
server       = nothing
worker_a     = nothing
worker_b     = nothing

try
    server_state = BonitoAgents.serve(;
        host          = "127.0.0.1",
        port          = XS_PORT,
        public_url    = "http://127.0.0.1:$XS_PORT",
        worker_secret = XS_SECRET,
        state_dir     = mktempdir(),
        working_dir   = mktempdir())
    server = server_state.srv
    sleep(0.3)

    worker_a = start_xsync_worker!("worker-a", "http://127.0.0.1:$XS_PORT")
    worker_b = start_xsync_worker!("worker-b", "http://127.0.0.1:$XS_PORT")
    wait_xsync_worker(server_state, "worker-a")
    wait_xsync_worker(server_state, "worker-b")

    # Same name on BOTH workers, different content.
    nm = "BonitoAgents"
    dir_a = joinpath(worker_a.root, nm); mkpath(dir_a)
    write(joinpath(dir_a, "README.md"), "FROM A\n")
    write(joinpath(dir_a, "a_only.txt"), "exists on A\n")
    dir_b = joinpath(worker_b.root, nm); mkpath(dir_b)
    write(joinpath(dir_b, "README.md"), "FROM B\n")
    write(joinpath(dir_b, "b_only.txt"), "exists on B\n")

    sp_a = BonitoAgents.compute_server_path(server_state, "worker-a", nm)
    sp_b = BonitoAgents.compute_server_path(server_state, "worker-b", nm)
    p_a = BonitoAgents.ProjectInfo(string(uuid4())[1:8], nm, "worker-a", sp_a, dir_a, now(UTC))
    p_b = BonitoAgents.ProjectInfo(string(uuid4())[1:8], nm, "worker-b", sp_b, dir_b, now(UTC))
    server_state.projects[][p_a.id] = p_a
    server_state.projects[][p_b.id] = p_b
    BonitoAgents.safe_notify!(server_state.projects)
    BonitoAgents.save_projects!(server_state)

    TH.section("same-named projects coexist via compute_server_path") do
        record("server paths differ by worker", @TH.test_true sp_a != sp_b)
    end

    TH.section("same_name_siblings pairs across workers only") do
        sibs = BonitoAgents.same_name_siblings(server_state, p_a.id)
        record("A sees exactly one sibling",  @TH.test_eq length(sibs) 1)
        record("sibling is B",                @TH.test_true !isempty(sibs) && sibs[1].id == p_b.id)
        record("unknown project → no siblings",
               @TH.test_true isempty(BonitoAgents.same_name_siblings(server_state, "nope")))
    end

    TH.section("compare_projects summarises both live workers") do
        cmp = BonitoAgents.compare_projects(server_state, p_a, p_b)
        record("A side inspected live",  @TH.test_eq cmp.a_source :worker)
        record("B side inspected live",  @TH.test_eq cmp.b_source :worker)
        record("A has 2 files",          @TH.test_eq Int(cmp.a["total_files"]) 2)
        record("B has 2 files",          @TH.test_eq Int(cmp.b["total_files"]) 2)
    end

    TH.section("sync_across_workers! A→B is a directional overwrite") do
        BonitoAgents.sync_across_workers!(server_state, p_a, p_b)
        files_b = xsync_files(dir_b)
        record("B README is now A's",
               @TH.test_eq get(files_b, "README.md", "") "FROM A\n")
        record("B gained A's a_only.txt",
               @TH.test_true haskey(files_b, "a_only.txt"))
        record("B's b_only.txt removed (mirror, not additive)",
               @TH.test_true !haskey(files_b, "b_only.txt"))
        record("source A untouched",
               @TH.test_true isfile(joinpath(dir_a, "a_only.txt")) &&
                             read(joinpath(dir_a, "README.md"), String) == "FROM A\n")
        record("target marked :stale after push",
               @TH.test_eq p_b.backup_status :stale)
        record("server mirror of source matches B",
               @TH.test_eq xsync_files(sp_a) xsync_files(dir_b))
    end

finally
    TH.report!("Tier 4d — cross-worker sync", results)
    try worker_a !== nothing && stop_xsync_worker!(worker_a) catch end
    try worker_b !== nothing && stop_xsync_worker!(worker_b) catch end
    try close(server) catch end
end
