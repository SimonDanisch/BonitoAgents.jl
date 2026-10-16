# Temporary benchmark worker, started through an existing bt_julia_eval session.
# Uses the production worker implementation without touching its installed service.
module RelayWorkerBench
using BonitoWorker, RemoteSync, WorkerLink, Random, SHA

function process_sample()
    # Linux /proc counters: process CPU includes all its threads; RSS is current,
    # unlike maxrss which would retain compilation peaks from earlier runs.
    stat = split(last(split(read("/proc/self/stat", String), ") "; limit = 2)))
    ticks = ccall(:sysconf, Clong, (Cint,), 2) # Linux _SC_CLK_TCK
    pages = parse(Int, split(read("/proc/self/statm", String))[2])
    return (time = time(), cpu = (parse(Int, stat[12]) + parse(Int, stat[13])) / ticks,
            rss = pages * ccall(:getpagesize, Cint, ()))
end

function monitor()
    active = Ref(true)
    samples = [process_sample()]
    task = @async while active[]
        sleep(0.1)
        push!(samples, process_sample())
    end
    return (; active, samples, task)
end

function finish(m)
    m.active[] = false
    wait(m.task)
    return m.samples
end

function start(url, credential, name; root = mktempdir(; prefix = "bonito-relay-data-"))
    config = BonitoWorker.WorkerConfig(; server_url = url, credential,
        worker_id = "bench-$name", name = "bench-$name", projects_root = root,
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[])
    worker = BonitoWorker.Worker(config)
    task = errormonitor(@async BonitoWorker.serve(worker))
    return (; worker, task, root)
end

function stop(w)
    close(w.worker)
    timedwait(() -> istaskdone(w.task), 10.0) == :ok || error("benchmark worker did not stop")
    fetch(w.task)
    return nothing
end

function dataset(root, name, files, bytes)
    dir = joinpath(root, name)
    ispath(dir) && error("dataset already exists: $dir")
    mkpath(dir)
    rng = Xoshiro(42)
    block = Vector{UInt8}(undef, min(bytes, 1024 * 1024))
    for i in 1:files
        open(joinpath(dir, "file-$i.bin"), "w") do io
            remaining = bytes
            while remaining > 0
                rand!(rng, block)
                n = min(remaining, length(block))
                write(io, view(block, 1:n))
                remaining -= n
            end
        end
    end
    return dir
end

function tree_hash(root)
    io = IOBuffer()
    for e in RemoteSync.walk_directory(root)
        write(io, e.rel, '\0', open(sha256, joinpath(root, e.rel)))
    end
    return bytes2hex(sha256(take!(io)))
end
end
