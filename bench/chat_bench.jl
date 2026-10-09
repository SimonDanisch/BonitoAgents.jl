# End-to-end benchmark of the chat pipeline on the real stack: dev_server (this
# process), a real BonitoWorker process, the mock agent (a real ACP process the
# worker spawns, scripted from here) and Electron. Not a test.
#
# Run in the BonitoAgents test env (TestKit and MockACP live there):
#     include("…/bench/chat_bench.jl"); r = ChatBench.run_all()
#
# Every workload reports wall time and, per process group, CPU seconds and
# context switches over its window: `server` is this process (the dev_server
# and the harness), `worker` the BonitoWorker process, `agents` the processes
# it started, `browser` Electron. The browser side also reports how long the
# chat's own message handler ran (`dispatch_ms`) and the long tasks it saw.
module ChatBench

const TEST_DIR = joinpath(@__DIR__, "..", "BonitoAgents", "test")
isdefined(Main, :TestKit) || Base.include(Main, joinpath(TEST_DIR, "testkit", "TestKit.jl"))
const TK = Main.TestKit

# ── process accounting ──────────────────────────────────────────────────────

children(pid::Integer) = [parse(Int, c) for t in readdir("/proc/$pid/task"; join = true)
                          for c in split(read(joinpath(t, "children"), String))]

function descendants(pid::Integer)
    out = Int[]
    todo = children(pid)
    while !isempty(todo)
        p = pop!(todo)
        isdir("/proc/$p") || continue
        push!(out, p)
        append!(todo, children(p))
    end
    return out
end

cmdline(pid::Integer) = replace(read("/proc/$pid/cmdline", String), '\0' => ' ')

function cpu_seconds(pid::Integer)
    s = split(last(split(read("/proc/$pid/stat", String), ") "; limit = 2)))
    return (parse(Int, s[12]) + parse(Int, s[13])) / 100
end

function switches(pid::Integer)
    n = 0
    for t in readdir("/proc/$pid/task"; join = true)
        for l in eachline(joinpath(t, "status"))
            (startswith(l, "voluntary_ctxt_switches") || startswith(l, "nonvoluntary_ctxt_switches")) &&
                (n += parse(Int, last(split(l))))
        end
    end
    return n
end

# The process groups of a running bench stack, resolved once per workload.
struct Groups
    pids::Dict{String,Vector{Int}}
end

function Groups(s::TK.TestServer)
    worker = getpid(s.h.worker_proc)
    agents = descendants(worker)
    browser = [p for p in descendants(getpid()) if p != worker && !(p in agents) &&
               occursin(r"electron|chrom"i, cmdline(p))]
    return Groups(Dict("server" => [getpid()], "worker" => [worker],
                       "agents" => agents, "browser" => browser))
end

function sample(g::Groups)
    out = Dict{String,Tuple{Float64,Int}}()
    for (name, pids) in g.pids
        alive = filter(p -> isdir("/proc/$p"), pids)
        out[name] = (sum(cpu_seconds, alive; init = 0.0), sum(switches, alive; init = 0))
    end
    return (t = time(), groups = out)
end

function delta(a, b)
    dt = b.t - a.t
    return Dict(name => (cpu_s = round(b.groups[name][1] - a.groups[name][1]; digits = 2),
                         cpu_pct = round(100 * (b.groups[name][1] - a.groups[name][1]) / dt; digits = 1),
                         switches_per_s = round(Int, (b.groups[name][2] - a.groups[name][2]) / dt))
                for name in keys(a.groups))
end

# ── browser instrumentation ─────────────────────────────────────────────────

# Wraps the visible chat's dispatch to time every message it handles, records
# long tasks, and stamps when a marker text first shows up in the transcript.
const INSTRUMENT_JS = """(() => {
    const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent);
    const chat = c.__bt_chat;
    const B = window.__bench = {calls: 0, ms: 0, max: 0, longtasks: 0, long_ms: 0, seen: {}};
    if (!chat.__benchWrapped) {
        const orig = chat.dispatch.bind(chat);
        chat.dispatch = function (msg) {
            const t0 = performance.now();
            try { return orig(msg); }
            finally {
                const d = performance.now() - t0;
                const b = window.__bench; b.calls++; b.ms += d; if (d > b.max) b.max = d;
            }
        };
        chat.__benchWrapped = true;
    }
    if (!window.__benchLT) {
        window.__benchLT = new PerformanceObserver(list => {
            for (const e of list.getEntries()) { window.__bench.longtasks++; window.__bench.long_ms += e.duration; }
        });
        window.__benchLT.observe({entryTypes: ['longtask']});
    }
    return true;
})()"""

watch_js(marker) = """(() => {
    const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent);
    const B = window.__bench;
    const check = () => {
        if (B.seen[$(repr(marker))]) return true;
        if ((c.innerText || '').includes($(repr(marker)))) { B.seen[$(repr(marker))] = Date.now(); return true; }
        return false;
    };
    if (!check()) {
        const mo = new MutationObserver(() => { if (check()) mo.disconnect(); });
        mo.observe(c, {childList: true, subtree: true, characterData: true});
    }
    return true;
})()"""

# Waits for the marker without asking the page more than twice a second; the
# page stamps the moment itself.
function wait_marker(s, marker; timeout = 300)
    t0 = time()
    while time() - t0 < timeout
        # A number of milliseconds once seen; `false` before (Bool is a Number).
        at = TK.eval_js(s, "(() => { const v = window.__bench.seen[$(repr(marker))]; return typeof v === 'number' ? v : false; })()")
        at isa Bool || return Float64(at) / 1000
        sleep(0.5)
    end
    error("marker $(marker) did not show up within $(timeout)s")
end

browser_stats(s) = TK.eval_js(s, "(() => { const b = window.__bench; return {calls: b.calls, ms: Math.round(b.ms), max_ms: Math.round(b.max), longtasks: b.longtasks, long_ms: Math.round(b.long_ms)}; })()")
reset_browser!(s) = TK.eval_js(s, "(() => { const b = window.__bench; b.calls = 0; b.ms = 0; b.max = 0; b.longtasks = 0; b.long_ms = 0; return true; })()")

# ── the scripted agent ──────────────────────────────────────────────────────

# What the agent does for each prompt, chosen by the harness before it sends one.
mutable struct Script
    events::Vector{Any}
end
const SCRIPT = Script(Any[])
agent(_prompt) = SCRIPT.events

function stream_events(n; marker)
    evs = Any[TK.text("stream chunk $(i) lorem ipsum dolor sit amet. ") for i in 1:n]
    push!(evs, TK.text(marker), TK.end_turn())
    return evs
end

function burst_events(n; marker, output_bytes = 1024)
    out = repeat("x", output_bytes)
    evs = Any[]
    for i in 1:n
        push!(evs, TK.text("burst message $(i): a short paragraph of agent prose."))
        push!(evs, TK.tool(kind = "read", title = "read file $(i)", id = "b$(i)-$(rand(UInt32))",
                           content = Any[Dict("type" => "text", "text" => out)]))
    end
    push!(evs, TK.text(marker), TK.end_turn())
    return evs
end

function background_events(paths)
    evs = Any[]
    for (i, f) in enumerate(paths)
        push!(evs, TK.tool(kind = "execute", tool_name = "Bash", title = "sleep $(i)",
                           id = "bg$(i)-$(rand(UInt32))",
                           raw_input = Dict("command" => "sleep 600", "run_in_background" => true),
                           content = Any[Dict("type" => "text", "text" =>
                               "Command running in background with ID: bg$(i). Output is being written to: $(f)")]))
    end
    push!(evs, TK.text("launched"), TK.end_turn())
    return evs
end

# ── workloads ───────────────────────────────────────────────────────────────

function timed(f, s)
    g = Groups(s)
    reset_browser!(s)
    a = sample(g)
    wall = f()
    b = sample(g)
    return (wall_s = round(wall; digits = 2), cpu = delta(a, b), browser = browser_stats(s))
end

function send_and_wait(s, events, marker)
    SCRIPT.events = events
    TK.eval_js(s, watch_js(marker))
    t0 = time()
    # Not the marker itself: the user's bubble would show it at once.
    TK.send_message(s, "go")
    return wait_marker(s, marker) - t0
end

stream(s; n = 2000) = timed(s) do
    m = "END-STREAM-$(rand(UInt32))"
    send_and_wait(s, stream_events(n; marker = m), m)
end

burst(s; n = 300, output_bytes = 1024) = timed(s) do
    m = "END-BURST-$(rand(UInt32))"
    send_and_wait(s, burst_events(n; marker = m, output_bytes), m)
end

# Whatever the stack does on its own while K background shells sit in the bar.
function idle_with_background(s; k = 3, seconds = 20.0)
    dir = mktempdir()
    paths = [joinpath(dir, "bg$(i).output") for i in 1:k]
    procs = [run(pipeline(`sleep 600`; stdout = p, append = true); wait = false) for p in paths]
    try
        SCRIPT.events = background_events(paths)
        TK.send_message(s, "launch background shells")
        TK.wait_for(s, "$(k) background tasks in the bar",
            "document.querySelectorAll('.bt-taskbar-slot').length >= $(k)"; timeout = 60)
        sleep(3.0)
        return timed(s) do
            sleep(seconds); seconds
        end
    finally
        foreach(kill, procs)
        TK.wait_for(s, "the bar empties", "document.querySelectorAll('.bt-taskbar-slot').length == 0"; timeout = 60)
    end
end

idle(s; seconds = 20.0) = timed(s) do
    sleep(seconds); seconds
end

# Reload the page with the chat's history; time until its last message is back.
function reload_history(s, marker)
    return timed(s) do
        t0 = time()
        TK.eval_js(s, "location.reload(); true")
        sleep(1.0)
        TK.wait_for(s, "the chat is back", "(() => { const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent); return !!c && !!c.__bt_chat; })()"; timeout = 120)
        TK.eval_js(s, INSTRUMENT_JS)
        TK.eval_js(s, watch_js(marker))
        wait_marker(s, marker) - t0
    end
end

function setup(; width = 1280, height = 900)
    s = TK.dev_server(agent = agent, browser_width = width, browser_height = height)
    TK.open_browser(s)
    TK.new_chat(s; cwd = mkpath(joinpath(mktempdir(), "benchchat")))
    TK.wait_for(s, "the chat", "(() => { const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent); return !!c && !!c.__bt_chat; })()"; timeout = 60)
    TK.eval_js(s, INSTRUMENT_JS)
    return s
end

function run_all(; stream_n = 2000, burst_n = 300, background_k = 3)
    s = setup()
    try
        results = Dict{String,Any}()
        sleep(10.0)        # past the startup work of the worker and the chat
        results["idle"] = idle(s)
        results["idle_with_background"] = idle_with_background(s; k = background_k)
        results["stream"] = stream(s; n = stream_n)
        m = "END-BURST-HISTORY"
        results["burst"] = timed(s) do
            send_and_wait(s, burst_events(burst_n; marker = m), m)
        end
        results["reload_history"] = reload_history(s, m)
        return results
    finally
        close(s)
    end
end

end # module
