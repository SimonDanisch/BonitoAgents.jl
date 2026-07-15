@testitem "unit:worker_state" tags = [:unit] begin

# Headless unit tests for worker-level state mutations that don't need a live
# server (no WS, no Electron). Currently: `remove_worker!` — the "remove a
# worker" UI action. Asserts it drops the worker, removes ITS projects (but
# leaves other workers' projects untouched), evicts the cached ChatModels,
# fans out a notification, and persists the change to workers.json/projects.json.

using Test
using BonitoAgents
const BT = BonitoAgents
using BonitoAgents: now, UTC
using Bonito: on
import JSON

@testset "remove_worker!" begin
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir,
                          working_dir = joinpath(dir, "work"),
                          worker_secret = "s")

    wid = "worker-uuid-1"
    st.workers[][wid] = BT.WorkerInfo(wid, "Laptop", "<inbound-ws>", "s", nothing,
                                      "host", "/home/u", "julia", String[],
                                      "/home/u/projects", :offline, now(UTC))
    mk(id, name, w) = BT.ProjectInfo(id, name, w,
                                     joinpath(dir, "work", name),
                                     "/home/u/projects/$name", now(UTC))
    p1 = mk("p1", "ProjA", wid)
    p2 = mk("p2", "ProjB", wid)
    p3 = mk("p3", "Other", "worker-2")        # different worker → must survive
    for p in (p1, p2, p3); st.projects[][p.id] = p; end
    # Real ChatModels (not Symbol stand-ins): worker eviction now close()s each
    # model and stop!s its agent, which needs the real type. A never-started model
    # (no agent subprocess, no consumer/poller) evicts cleanly. Each carries a
    # WorkerAgent for its worker — the only agent kind now (no local default).
    c1 = mktempdir(); c3 = mktempdir()
    st.chat_models["p1"] = BT.ChatModel(st, c1; project_id = "p1",
                                        agent = BT.WorkerAgent(st, wid, c1))
    st.chat_models["p3"] = BT.ChatModel(st, c3; project_id = "p3",
                                        agent = BT.WorkerAgent(st, "worker-2", c3))
    BT.save_workers!(st); BT.save_projects!(st)

    notified = Ref(0)
    on(_ -> (notified[] += 1), st.workers)

    BT.remove_worker!(st, wid)

    # In-memory state
    @test !haskey(st.workers[], wid)
    @test !haskey(st.projects[], "p1")
    @test !haskey(st.projects[], "p2")
    @test haskey(st.projects[], "p3")              # other worker's project kept
    @test !haskey(st.chat_models, "p1")            # evicted
    @test haskey(st.chat_models, "p3")             # untouched
    @test notified[] >= 1                          # sidebar/dashboard fan-out

    # Persisted to disk
    wjson = JSON.parsefile(joinpath(dir, "workers.json"))
    pjson = JSON.parsefile(joinpath(dir, "projects.json"))
    @test !any(w -> w["worker_id"] == wid, wjson)
    @test Set(p["id"] for p in pjson) == Set(["p3"])

    # Removing an unknown worker is a no-op, not an error.
    @test (BT.remove_worker!(st, "does-not-exist"); true)

    # remove_projects=false keeps the project rows (just evicts the worker +
    # its live ChatModels).
    wid2 = "worker-uuid-2"
    st.workers[][wid2] = BT.WorkerInfo(wid2, "Box", "<inbound-ws>", "s", nothing,
                                       "h2", "/home/v", "julia", String[],
                                       "/home/v/projects", :offline, now(UTC))
    p4 = mk("p4", "Keep", wid2)
    st.projects[][p4.id] = p4
    c4 = mktempdir()
    st.chat_models["p4"] = BT.ChatModel(st, c4; project_id = "p4",
                                        agent = BT.WorkerAgent(st, wid2, c4))
    BT.remove_worker!(st, wid2; remove_projects = false)
    @test !haskey(st.workers[], wid2)
    @test haskey(st.projects[], "p4")              # row kept
    @test !haskey(st.chat_models, "p4")            # but live model evicted
end

@testset "thread identity (folder hosts multiple threads)" begin
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir,
                          working_dir = joinpath(dir, "work"),
                          worker_secret = "s")
    st.workers[]["wX"] = BT.WorkerInfo("wX", "Box", "<ws>", "s", nothing,
                                       "h", "/home", ".", String[],
                                       "/home/u/projects", :online, now(UTC))
    imp(path; sess = nothing) = BT.create_project_from_worker!(
        st, "wX", path; resume_session_id = sess, start_session = false)

    # Two different claude sessions of the SAME folder → two sibling threads.
    a = imp("/home/u/projects/MyApp"; sess = "sessA")
    b = imp("/home/u/projects/MyApp"; sess = "sessB")
    @test a.id != b.id
    @test length(st.projects[]) == 2
    @test a.name == b.name && a.server_path == b.server_path   # same folder/files
    @test (a.resume_session_id, b.resume_session_id) == ("sessA", "sessB")

    # Re-importing the same session reuses its thread (idempotent).
    @test imp("/home/u/projects/MyApp"; sess = "sessA").id == a.id
    @test length(st.projects[]) == 2

    # No-session imports always start a fresh thread (never collapse).
    n1 = imp("/home/u/projects/Fresh")
    n2 = imp("/home/u/projects/Fresh")
    @test n1.id != n2.id

    # find_thread keys on the session id.
    @test BT.find_thread(st, "wX", "/home/u/projects/MyApp", "sessB") === b
    @test BT.find_thread(st, "wX", "/home/u/projects/MyApp", "nope") === nothing
    @test BT.find_thread(st, "wX", "/home/u/projects/MyApp", nothing) === nothing
end

@testset "dedup keeps sibling threads, collapses true dupes" begin
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir,
                          working_dir = joinpath(dir, "work"),
                          worker_secret = "s")
    folder = "/home/u/projects/Repo"
    mk(id) = BT.ProjectInfo(id, "Repo", "wY",
                            joinpath(dir, "work", "wY-Repo"), folder, now(UTC))
    # Same folder, three threads: two distinct sessions + a no-session thread.
    p1 = mk("id1"); p1.resume_session_id = "S1"
    p2 = mk("id2"); p2.resume_session_id = "S2"
    p3 = mk("id3")                                            # no session
    # A genuine duplicate of p1 (same session id) — must collapse.
    p1b = mk("id1b"); p1b.resume_session_id = "S1"
    for p in (p1, p2, p3, p1b); st.projects[][p.id] = p; end

    BT.dedup_projects!(st)
    ids = Set(keys(st.projects[]))
    @test "id2" in ids && "id3" in ids                        # distinct threads kept
    @test ("id1" in ids) ⊻ ("id1b" in ids)                    # exactly one S1 kept
    @test length(ids) == 3                                    # 4 → 3 (one dupe dropped)
end

@testset "discovered scan persistence" begin
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir,
                          working_dir = joinpath(dir, "work"),
                          worker_secret = "s")
    st.discovered[]["wA"] = [Dict{String,Any}(
        "session_id" => "s1", "path" => "/p/App",
        "first_prompt" => "fix the bug", "last_used" => 1.7e9, "kind" => "session")]
    BT.save_discovered!(st)
    @test isfile(joinpath(dir, "discovered.json"))

    # A fresh state over the same dir reloads the cache (survives restart).
    st2 = BT.ServerState(; state_dir = dir,
                           working_dir = joinpath(dir, "work"),
                           worker_secret = "s")
    @test haskey(st2.discovered[], "wA")
    @test st2.discovered[]["wA"][1]["first_prompt"] == "fix the bug"

    # scan_and_store! against a disconnected worker stores an error row rather
    # than throwing (the panel surfaces it), and persists.
    res = BT.scan_and_store!(st2, "ghost")
    @test length(res) == 1 && haskey(res[1], "error")
    @test haskey(st2.discovered[], "ghost")
    @test JSON.parsefile(joinpath(dir, "discovered.json")) |> d -> haskey(d, "ghost")
end

@testset "teardown_worker_control! identity guard" begin
    # Regression: two control sockets sharing a worker_id (duplicate worker
    # process, or a reconnect that re-registered before the old socket's
    # `finally` ran) must not destroy each other. The stale socket's teardown
    # must be a no-op; only the socket that is STILL the registered one tears
    # down the worker. Per #28 the chat model is KEPT for reconnect (only the
    # dead agent session is torn down) — it must NOT be evicted.
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir,
                          working_dir = joinpath(dir, "work"),
                          worker_secret = "s")
    wid = "dup-worker"
    st.workers[][wid] = BT.WorkerInfo(wid, "Box", "<inbound-ws>", "s", nothing,
                                      "h", "/home/u", "julia", String[],
                                      "/home/u/projects", :online, now(UTC))
    st.projects[][ "pp" ] = BT.ProjectInfo("pp", "Proj", wid,
                                joinpath(dir, "work", "Proj"),
                                "/home/u/projects/Proj", now(UTC))
    cpp = mktempdir()
    st.chat_models["pp"] = BT.ChatModel(st, cpp; project_id = "pp",
                                        agent = BT.WorkerAgent(st, wid, cpp))

    # Sockets are compared by `===`, so any two distinct objects stand in for
    # two real WebSockets here.
    ws_old = Ref(:old)
    ws_new = Ref(:new)

    # Worker connects (old), then reconnects (new) — last writer wins.
    st.worker_control_ws[wid] = ws_old
    st.worker_control_ws[wid] = ws_new

    # The OLD socket's loop now ends and runs teardown. It is NOT the current
    # registration → must be a no-op: live socket, worker, and chat model intact.
    @test BT.teardown_worker_control!(st, wid, ws_old) == false
    @test st.worker_control_ws[wid] === ws_new
    @test st.workers[][wid].online[] == true
    @test haskey(st.chat_models, "pp")

    # The NEW (current) socket dropping DOES tear down: the worker goes offline
    # and its registration is dropped, but the chat model is KEPT (#28) so the
    # chat survives the disconnect and rebinds on the worker's next reconnect.
    @test BT.teardown_worker_control!(st, wid, ws_new) == true
    @test !haskey(st.worker_control_ws, wid)
    @test st.workers[][wid].online[] == false
    @test haskey(st.chat_models, "pp")            # #28: kept for reconnect, not evicted
end

@testset "workers.json round-trips (persistent rig restart)" begin
    # Regression: after `online` became an Observable, `load_workers!` still
    # fed the legacy `:unknown` Symbol to the RAW 13-arg constructor and threw
    # convert(Bool, ::Symbol) — every persisted worker was silently dropped as
    # a "malformed worker entry" on restart. On a persistent dev rig
    # (`dev_server(dir = ...)`) that orphaned all projects until the local
    # worker happened to re-register.
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir,
                          working_dir = joinpath(dir, "work"),
                          worker_secret = "s")
    wid = "worker-roundtrip-1"
    st.workers[][wid] = BT.WorkerInfo(wid, "Studio", "<inbound-ws>", "s", nothing,
                                      "host", "/home/u", "julia", String["--project"],
                                      "/home/u/projects", :online, now(UTC))
    BT.save_workers!(st)

    st2 = BT.ServerState(; state_dir = dir,
                           working_dir = joinpath(dir, "work"),
                           worker_secret = "s")
    @test haskey(st2.workers[], wid)              # NOT dropped as malformed
    w = st2.workers[][wid]
    @test w.name == "Studio"
    @test w.projects_root == "/home/u/projects"
    @test w.online[] == false                     # offline until the WS dials in
end

end
