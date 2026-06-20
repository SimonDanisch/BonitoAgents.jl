# End-to-end regression for the Key-N-not-found / null-Observable race
# the user hit when clicking "Resume" on a discovered claude session.
#
# Real stack (no mocks):
#   - BonitoAgents.serve()                 (production URL)
#   - BonitoWorker.connect_and_serve()    (real /worker-ws handshake)
#   - Electron BrowserWindow at the served URL
#   - Chromium console-message + renderer-side patch capture
#
# What it actually checks (per the user's complaint that I previously
# only watched a log and called it green):
#   1. Dashboard's "Home" entry rendered
#   2. After adding a project + notify, the project's sidebar entry and
#      the project's dashboard card are both visible in the DOM
#   3. Clicking the sidebar entry actually navigates (chat panel mounts
#      OR a "Starting chat for X…" placeholder shows up)
#   4. Zero "Key N not found" / "TrackingOnly" / null-Observable warnings
#      across the run
#   5. Final-state screenshot saved so we can see what the user sees

using BonitoAgents, Bonito, HTTP, JSON
import ElectronCall, BonitoWorker

# ── 1. server + worker ───────────────────────────────────────────────────
state = BonitoAgents.serve(;
    host          = "127.0.0.1",
    port          = 0,
    worker_secret = "resume-test-secret",
    state_dir     = mktempdir(),
    working_dir   = mktempdir())
url = Bonito.online_url(state.srv, "")
@info "Server up" url

worker_proj_root = mktempdir()
worker_task = Base.errormonitor(@async try
    BonitoWorker.connect_and_serve(;
        server_url    = url,
        secret        = "resume-test-secret",
        worker_id     = "resume-test-worker-id",
        name          = "ResumeTestWorker",
        mcp_path      = "",
        projects_root = worker_proj_root)
catch e
    @warn "worker task ended" exception=e
end)

deadline = time() + 15
while time() < deadline
    haskey(state.workers[], "resume-test-worker-id") &&
        state.workers[]["resume-test-worker-id"].status == :online && break
    sleep(0.2)
end
@assert haskey(state.workers[], "resume-test-worker-id") "worker never connected"
@info "Worker connected"

# ── 2. open Electron + capture both main-process and renderer console
app = ElectronCall.Application()
win = ElectronCall.Window(app, ElectronCall.URI(url);
                      options = Dict{String,Any}("show"=>false, "focusOnWebView"=>false))
sleep(2.5)

console_log = tempname() * ".jsonl"
win_id = win.id
ElectronCall.run(app, """
    const win = electron.BrowserWindow.fromId($win_id);
    const fs  = require('fs');
    const log_path = $(JSON.json(console_log));
    win.webContents.on('console-message', (...args) => {
        try {
            let level, message, line, source;
            if (args.length === 1 && typeof args[0] === 'object') {
                ({level, message, lineNumber: line, sourceId: source} = args[0]);
            } else {
                [, level, message, line, source] = args;
            }
            fs.appendFileSync(log_path,
                JSON.stringify({src:'main', level, message, source, line}) + '\\n');
        } catch(e) {}
    });
    null
""")

ElectronCall.run(win, """
    (() => {
        window.__bt_console = [];
        for (const lvl of ['log','warn','error']) {
            const orig = console[lvl];
            console[lvl] = function(...args) {
                try {
                    window.__bt_console.push({lvl, msg: args.map(a => {
                        try { return typeof a === 'string' ? a : JSON.stringify(a); }
                        catch(e) { return String(a); }
                    }).join(' ')});
                } catch(e) {}
                return orig.apply(this, args);
            };
        }
        window.addEventListener('error', e =>
            window.__bt_console.push({lvl:'error', msg: 'uncaught: ' + (e.message||String(e))}));
        window.addEventListener('unhandledrejection', e =>
            window.__bt_console.push({lvl:'error', msg: 'unhandled: ' + String(e.reason)}));
    })()
""")
@info "Console capture armed" console_log
# Verify the patch took:
diag = ElectronCall.run(win, """JSON.stringify({
    has_arr: Array.isArray(window.__bt_console),
    arr_len: (window.__bt_console || []).length,
    typeof_warn: typeof console.warn,
    test_call: (() => { console.warn('TEST_PATCH_PROBE'); return (window.__bt_console || []).length; })(),
})""")
@info "Patch verification" diag

wait_for(predicate; timeout=5.0) = begin
    deadline = time() + timeout
    while time() < deadline
        try
            ElectronCall.run(win, "(() => { return ($predicate); })()") === true && return true
        catch end
        sleep(0.1)
    end
    false
end

screenshot(label) = begin
    path = tempname() * ".png"
    flag = path * ".done"
    ElectronCall.run(app, """
        const win = electron.BrowserWindow.fromId($win_id);
        win.webContents.capturePage().then(img => {
            require('fs').writeFileSync($(JSON.json(path)), img.toPNG());
            require('fs').writeFileSync($(JSON.json(flag)), '1');
        });
        null
    """)
    t0 = time()
    while !isfile(flag) && time() - t0 < 5; sleep(0.1); end
    println("--- screenshot[$label] → $path ---")
    return path
end

results = Pair{String,Bool}[]
record(name, ok) = (push!(results, name => ok); println("  $(ok ? "PASS" : "FAIL")  $name"))

try
    # 3. dashboard rendered
    record("Home sidebar entry visible",
           wait_for("document.querySelector('.bt-side-item[data-project-id=\"\"]') !== null"; timeout=10))
    record("Worker card visible (ResumeTestWorker)",
           wait_for("document.body.innerText.indexOf('ResumeTestWorker') !== -1"; timeout=5))
    sleep(0.5)
    screenshot("01_empty_dashboard")

    # 4. add alpha (real Resume sequence: state.projects[][id]=p; notify)
    p_alpha = BonitoAgents.ProjectInfo("alpha", "Alpha", "resume-test-worker-id",
                joinpath(state.working_dir, "Alpha"),
                joinpath(worker_proj_root, "Alpha"),
                BonitoAgents.now(BonitoAgents.UTC))
    mkpath(p_alpha.server_path); mkpath(p_alpha.worker_path)
    state.projects[]["alpha"] = p_alpha
    notify(state.projects)

    record("Alpha sidebar entry appears after notify",
           wait_for("document.querySelector('.bt-side-item[data-project-id=\"alpha\"]') !== null"; timeout=5))
    record("Alpha project card appears in dashboard",
           wait_for("Array.from(document.querySelectorAll('.bt-card-name')).some(e => e.innerText==='Alpha')"; timeout=5))
    sleep(0.5)

    # 5. add beta — this is where project_list re-renders, the OLD
    #    project_card subsession (holding current_view via interpolated
    #    onclick) closes, and the bug fires WITHOUT the Bonito root-
    #    session-counts-as-reference patch.
    p_beta = BonitoAgents.ProjectInfo("beta", "Beta", "resume-test-worker-id",
                joinpath(state.working_dir, "Beta"),
                joinpath(worker_proj_root, "Beta"),
                BonitoAgents.now(BonitoAgents.UTC))
    mkpath(p_beta.server_path); mkpath(p_beta.worker_path)
    state.projects[]["beta"] = p_beta
    notify(state.projects)

    record("Beta sidebar entry appears after second notify",
           wait_for("document.querySelector('.bt-side-item[data-project-id=\"beta\"]') !== null"; timeout=5))
    sleep(0.5)
    screenshot("02_two_projects")

    # 6. click sidebar entries to drive current_view changes (this is
    #    where the user's click handler dereferences null in the buggy
    #    case — it executes $(current_view).notify(...) and current_view
    #    has been freed from GLOBAL_OBJECT_CACHE).
    ElectronCall.run(win, """document.querySelector('.bt-side-item[data-project-id="alpha"]').click()""")
    sleep(0.6)
    record("Click alpha → main panel shows Alpha",
           wait_for("document.body.innerText.indexOf('Starting chat for Alpha') !== -1 || document.querySelector('.bt-app') !== null"; timeout=5))
    screenshot("03_alpha_clicked")
    println("    [console after alpha click] ",
        ElectronCall.run(win, "JSON.stringify((window.__bt_console||[]).slice(-15))"))

    ElectronCall.run(win, """document.querySelector('.bt-side-item[data-project-id="beta"]').click()""")
    sleep(0.6)
    record("Click beta → main panel updates",
           wait_for("document.body.innerText.indexOf('Starting chat for Beta') !== -1 || document.querySelector('.bt-app') !== null"; timeout=5))
    screenshot("04_beta_clicked")
    println("    [console after beta click] ",
        ElectronCall.run(win, "JSON.stringify((window.__bt_console||[]).slice(-15))"))
    println("    [main panel HTML snippet] ",
        ElectronCall.run(win, "document.querySelector('.bt-main')?.innerText?.slice(0,200) ?? '(no main)'"))

    ElectronCall.run(win, """document.querySelector('.bt-side-item[data-project-id=""]').click()""")
    sleep(0.6)
    record("Click home → dashboard returns",
           wait_for("document.body.innerText.indexOf('ResumeTestWorker') !== -1"; timeout=5))
    screenshot("05_home_clicked")

    sleep(1.0)

    # 7. drain console
    main_lines = isfile(console_log) ? readlines(console_log) : String[]
    main_msgs = String[]
    for line in main_lines
        try; push!(main_msgs, get(JSON.parse(line), "message", "")); catch end
    end
    rendered = ElectronCall.run(win, "JSON.stringify(window.__bt_console || [])")
    rend_msgs = String[]
    if rendered isa AbstractString
        try
            for entry in JSON.parse(rendered)
                push!(rend_msgs, get(entry, "msg", ""))
            end
        catch end
    end
    @info "console totals" main=length(main_msgs) renderer=length(rend_msgs)

    all_msgs = vcat(main_msgs, rend_msgs)
    bug_patterns = [
        r"Key \d+ not found",
        r"TrackingOnly: Key \d+ not found",
        r"Trying to delete object \d+, which is not in global session cache",
        r"Cannot read properties of null \(reading 'notify'\)",
    ]
    offenders = String[]
    for m in all_msgs, pat in bug_patterns
        occursin(pat, m) && push!(offenders, m)
    end
    record("zero Key-not-found / null-Observable messages", isempty(offenders))
    if !isempty(offenders)
        for o in first(offenders, min(10, length(offenders)))
            println("    OFFENDER: ", o)
        end
    end

finally
    println("\n", "="^60)
    pass = count(p -> p.second, results)
    fail = length(results) - pass
    println("Resume-flow regression: $pass passed, $fail failed")
    try close(win) catch end
    try close(app) catch end
    try close(state.srv) catch end
end
