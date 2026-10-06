# Server-path benchmark, not a UI/e2e test. Both endpoints must be real remote
# BonitoWorker instances. Excludes MCP/agent/browser overhead and checksum work.
module RelayServerBench
using BonitoAgents, RemoteSync, WorkerLink, Statistics
using Dates
const BT = BonitoAgents
const WS = BT.WebSockets

function completed(ch)
    try
        WS.receive(ch)
        error("unexpected data after transfer")
    catch e
        e isa WS.WebSocketError && WS.isok(e) || rethrow()
    end
end

function staged(state, source_id, target_id, src, dst, mirror)
    source = BT.transfer_channel(state, source_id,
        Dict("direction" => "from_worker", "src_path" => src); timeout = 30.0)
    try
        RemoteSync.receive_directory(mirror, RemoteSync.WebSocketIO(source);
            streaming = false, delete_extraneous = true)
        completed(source)
    finally
        close(source)
    end
    target = BT.transfer_channel(state, target_id,
        Dict("direction" => "to_worker", "dst_path" => dst); timeout = 30.0)
    try
        RemoteSync.send_directory(mirror, RemoteSync.WebSocketIO(target); streaming = false)
        completed(target)
    finally
        close(target)
    end
    return nothing
end

function measure(f, state, ids, probe_paths)
    # Ordinary control RPCs share the same two links as the bulk data. Record
    # their response time to detect throughput bought by starving other work.
    active = Ref(true)
    latency = Float64[]
    probe = @async while active[]
        probe_started_ns = time_ns()
        for (id, path) in zip(ids, probe_paths)
            BT.list_worker_dir(state, id, path; timeout = 10.0)
        end
        push!(latency, (time_ns() - probe_started_ns) / 1e9)
        sleep(0.1)
    end
    started = time()
    measurement = try
        @timed f()
    finally
        active[] = false
        wait(probe)
    end
    return (started = started, seconds = measurement.time,
        server_allocated_mib = measurement.bytes / 2.0^20, gc_seconds = measurement.gctime,
        control_pair_seconds = latency)
end

function run_suite(state, source_root, target_root, mirror_root; repeats = 3)
    source_id, target_id = "bench-source", "bench-destination"
    target = state.workers[][target_id]
    project = BT.ProjectInfo("relay-bench", "relay-bench", source_id,
        mirror_root, source_root, now(UTC))
    results = NamedTuple[]
    for scenario in ("large", "small", "unchanged-large", "unchanged-small", "delta")
        base = occursin("small", scenario) ? "small" : "large"
        for repetition in 0:repeats
            # Alternate order to reduce drift from Wi-Fi and other host work.
            modes = iseven(repetition) ? (:staged, :relay) : (:relay, :staged)
            for mode in modes
                label = "$scenario-$repetition-$mode"
                dst = joinpath(target_root, label)
                mirror = joinpath(mirror_root, label)
                copy_folder(src) = mode == :staged ?
                    staged(state, source_id, target_id, src, dst, mirror) :
                    BT.sync_folder!(state, project, target, src, dst)
                if startswith(scenario, "unchanged") || scenario == "delta"
                    copy_folder(joinpath(source_root, base))
                end
                src = joinpath(source_root, scenario == "delta" ? "delta" : base)
                m = measure(() -> copy_folder(src), state, (source_id, target_id),
                    (joinpath(source_root, "probe"), joinpath(target_root, "probe")))
                row = (; scenario, mode = String(mode), repetition, dst,
                    expected = scenario == "delta" ? "delta" : base, m...)
                push!(results, row)
                println(label, ": ", round(m.seconds; digits = 4), " s")
                flush(stdout)
            end
        end
    end
    return results
end

function direct_baselines(state, source_root, target_root, mirror_root; repeats = 3)
    ids = ("bench-source", "bench-destination")
    probes = (joinpath(source_root, "probe"), joinpath(target_root, "probe"))
    local_source = joinpath(mirror_root, "large-0-staged")
    results = NamedTuple[]
    for repetition in 0:repeats
        for direction in (:download, :upload)
            m = measure(state, ids, probes) do
                if direction == :download
                    BT.sync_dir_from_worker!(state, ids[1], joinpath(source_root, "large"),
                        joinpath(mirror_root, "direct-download-$repetition"))
                else
                    BT.sync_dir_to_worker!(state, ids[2], local_source,
                        joinpath(target_root, "direct-upload-$repetition"))
                end
            end
            push!(results, (; direction = String(direction), repetition, m...))
            println("direct $direction-$repetition: ", round(m.seconds; digits = 4), " s")
        end
    end
    return results
end

function headroom(state, source_root, target_root, mirror_root; repeats = 5)
    ids = ("bench-source", "bench-destination")
    probes = (joinpath(source_root, "probe"), joinpath(target_root, "probe"))
    project = BT.ProjectInfo("headroom", "headroom", ids[1], mirror_root, source_root, now(UTC))
    local_src = joinpath(mirror_root, "large-0-staged")
    results = NamedTuple[]
    for repetition in 1:repeats
        for mode in (iseven(repetition) ? (:relay, :direct) : (:direct, :relay))
            dst = joinpath(target_root, "headroom-$repetition-$mode")
            m = measure(state, ids, probes) do
                mode == :relay ?
                    BT.sync_folder!(state, project, state.workers[][ids[2]],
                        joinpath(source_root, "large"), dst) :
                    BT.sync_dir_to_worker!(state, ids[2], local_src, dst)
            end
            push!(results, (; repetition, mode = String(mode), m...))
        end
    end
    return results
end
end
