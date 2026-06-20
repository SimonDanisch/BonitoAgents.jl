# Shared scaffolding for the electron-based end-to-end tests.
#
# Every test file:
#   include("helpers.jl")           # brings in TH alias + utilities
#   state = TH.make_state(; ...)
#   ctx   = TH.open_window(state)   # Electron window + live unified_app
#   ...assertions via TH.eval_js / TH.dom_count / TH.wait_for...
#   TH.shutdown(ctx)

# Bring BonitoAgents into the INCLUDING module (Main) too — nearly every test
# file references `BonitoAgents.…` directly, and relying on some earlier suite
# file having imported it makes files fail when run standalone.
using BonitoAgents

module TestHelpers

using Bonito, BonitoAgents, AgentClientProtocol, Dates, JSON
using ElectronCall  # ensures use_electron_display works
import HTTP
import Base64

# A few aliases so test files can stay terse.
const ACP = AgentClientProtocol

# ── Test fixtures ─────────────────────────────────────────────────────────────

"""
    make_state(; n_projects=0, n_workers=0)

Build a self-contained ServerState backed by tempdirs. Optionally seed with
N stub projects and/or workers so the dashboard / sidebar have content to
render. Project ids are `p-1`..`p-N`; worker names are `w-1`..`w-N`.
"""
function make_state(; n_projects::Int = 0, n_workers::Int = 0)
    state = BonitoAgents.ServerState(;
        state_dir     = mktempdir(),
        working_dir   = mktempdir(),
        worker_secret = "test-secret")

    for i in 1:n_workers
        name = "w-$i"
        w = BonitoAgents.WorkerInfo(
            name,                             # worker_id (stable UUID — uses name in tests)
            name,                             # display name
            "ws://localhost:$(8100+i)",       # url
            "test-secret",                    # secret
            nothing,                          # ssh_target
            "host-$i",                        # hostname
            "/home/agent",                    # home
            "/usr/bin/julia",                 # mcp_path (the julia binary)
            ["--project=@bonito-agents", "-e", "using BonitoMCP"],  # mcp_args
            "/tmp/worker-$i-projects",        # projects_root
            :offline,                         # status
            now(UTC))                         # last_check
        state.workers[][name] = w
    end
    n_workers > 0 && notify(state.workers)

    for i in 1:n_projects
        id = "p-$i"
        proj = BonitoAgents.ProjectInfo(
            id, "Project$i",
            n_workers > 0 ? "w-$((i-1) % n_workers + 1)" : "",
            mktempdir(),         # server_path (real dir, so chat persistence works)
            "/tmp/worker-side-$i",
            now())
        state.projects[][id] = proj
    end
    n_projects > 0 && notify(state.projects)

    return state
end

# ── Mock ACP transport ────────────────────────────────────────────────────────

"""
    mock_transport(; scripted = [], prompt_error = nothing) -> BonitoAgents.MockTransport

Build a `BonitoAgents.MockTransport` for `ChatModel(...; transport=...)`.
The transport carries an `on_setup(out, in)` closure that spawns the
loopback responder against its (outgoing, incoming) channel pair —
auto-responding to `initialize`, `session/new`, `session/prompt`, and
`session/cancel`.

`scripted` is a vector of `(delay_seconds, update_dict)` tuples. After a
`session/prompt` request lands, the responder emits each update in order
through the transport's incoming channel (which the ACP reader_loop
hands to `update_handler`), then completes the prompt request. Use this
to simulate streaming agent / thought / tool events without a real
claude subprocess.

`prompt_error` (if set) makes the responder reply to `session/prompt`
with a JSON-RPC error instead — exercises send_prompt_async!'s
banner-vs-inline-bubble error split.
"""
function mock_transport(; scripted::Vector = Tuple{Float64,Dict}[],
                          prompt_error::Union{AbstractString,Nothing} = nothing)
    on_setup = function(outgoing::Channel{String}, incoming::Channel{String})
        Base.errormonitor(@async try
            for line in outgoing
                msg = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)

                if method == "initialize" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                                   "result"=>Dict())))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                                   "result"=>Dict("sessionId"=>"mock-sess-1"))))
                elseif method == "session/prompt" && id !== nothing
                    @async try
                        for (delay, upd) in scripted
                            delay > 0 && sleep(delay)
                            put!(incoming, JSON.json(Dict(
                                "jsonrpc" => "2.0",
                                "method"  => "session/update",
                                "params"  => Dict("sessionId" => "mock-sess-1",
                                                   "update"    => upd))))
                        end
                        if prompt_error === nothing
                            put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                                           "result"=>Dict("stopReason"=>"end_turn"))))
                        else
                            put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                "error"=>Dict("code"=>-32000, "message"=>String(prompt_error)))))
                        end
                    catch e
                        @warn "mock prompt streamer failed" exception=e
                    end
                elseif id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                                   "result"=>nothing)))
                end
                # Notifications (no id) — `session/cancel` etc. — just drop.
            end
        catch e
            e isa InvalidStateException || @warn "mock responder failed" exception=e
        end)
        return nothing
    end
    return BonitoAgents.MockTransport(on_setup)
end

# Helper: build the four update payloads we care about. Shape mirrors what
# claude-agent-acp emits, so `parse_session_update` in AgentClientProtocol
# accepts them unchanged.
agent_chunk_update(text) = Dict(
    "sessionUpdate" => "agent_message_chunk",
    "content" => Dict("type" => "text", "text" => text))

thought_chunk_update(text) = Dict(
    "sessionUpdate" => "agent_thought_chunk",
    "content" => Dict("type" => "text", "text" => text))

# Initial tool announcement (sessionUpdate=tool_call). Despite its
# `tool_call_update` name (kept for backwards compat with existing tests),
# this produces the FIRST event for a given toolCallId. Use `tool_update`
# below for the partial-update follow-ups.
function tool_call_update(; id="t1", kind="execute", title="ls", status="completed",
                            content=[], tool_name=nothing, raw_input=nothing)
    d = Dict{String,Any}(
        "sessionUpdate" => "tool_call",
        "toolCallId" => id, "kind" => kind, "title" => title, "status" => status,
        "content" => content)
    tool_name === nothing ||
        (d["_meta"] = Dict("claudeCode" => Dict("toolName" => tool_name)))
    raw_input === nothing || (d["rawInput"] = raw_input)
    return d
end

# Partial update for an already-emitted toolCallId — re-renders the header
# in place. Pass only the fields you want to change. `tool_name`/`raw_input`
# mirror real claude-agent-acp behavior: tool input STREAMS, so the
# arguments usually ride one of these updates, not the initial tool_call.
function tool_update(; id, kind=nothing, title=nothing, status=nothing,
                       content=nothing, tool_name=nothing, raw_input=nothing)
    d = Dict{String,Any}(
        "sessionUpdate" => "tool_call_update",
        "toolCallId"    => id)
    kind    === nothing || (d["kind"]    = kind)
    title   === nothing || (d["title"]   = title)
    status  === nothing || (d["status"]  = status)
    content === nothing || (d["content"] = content)
    tool_name === nothing ||
        (d["_meta"] = Dict("claudeCode" => Dict("toolName" => tool_name)))
    raw_input === nothing || (d["rawInput"] = raw_input)
    return d
end

# Wrap a text block in the ACP envelope expected by parse_tool_content_item.
tool_text(text::AbstractString) = Dict(
    "type" => "content",
    "content" => Dict("type" => "text", "text" => text))

# Wrap a diff in the ACP envelope. Used to test the `edit` tool kind which
# renders DiffEditor stacks instead of plain text.
tool_diff(; path, old_text, new_text) = Dict(
    "type"    => "diff",
    "path"    => path,
    "oldText" => old_text,
    "newText" => new_text)

plan_update(entries::Vector) = Dict(
    "sessionUpdate" => "plan",
    "entries" => [Dict("content"=>e.content, "status"=>e.status,
                        "priority"=>get(e, :priority, "medium"))
                   for e in entries])

# ── Electron window lifecycle ─────────────────────────────────────────────────

"""
    open_window(state) -> ctx

Boot a Bonito Electron window pointed at `unified_app(state)`. Returns a
NamedTuple `(disp, app, session, state)` to pass to the rest of the helpers.
"""
function open_window(state::BonitoAgents.ServerState; devtools::Bool = false,
                     show::Bool = false)
    # `show: false` keeps the suite headless — important so the local dev
    # session isn't interrupted by a flurry of windows, and so CI doesn't
    # need a compositor. Width/height are still set explicitly so layout
    # behaves the same as the visible case (without these, on
    # offscreen-rendering setups the renderer's viewport doesn't follow
    # `setSize` calls later — `window.innerWidth` stays at whatever
    # Electron's default offscreen width is, breaking the @media-query
    # based mobile breakpoint test).
    # `--ozone-platform=x11`: Electron 28+ defaults to native Wayland in a
    # Wayland session, but `capturePage` on a `show:false` window only works
    # for the *first* call on Wayland — subsequent calls return a Promise
    # that never resolves (no persistent offscreen surface for hidden
    # windows). Forcing X11 (via XWayland when needed) gives a consistent
    # offscreen render path and repeat captures work fine.
    disp    = Bonito.use_electron_display(;
        devtools,
        options = Dict{String,Any}(
            "show"   => show,
            "width"  => 1280,
            "height" => 800,
            # Chromium throttles requestAnimationFrame to ~1 Hz in any window
            # that isn't focused/visible — which an automated window never is,
            # so frame-time profiling reads 1000 ms frames regardless of
            # `show`. Disabling background throttling forces real ~60 Hz rAF
            # so the profiler measures genuine paint/frame cost.
            "webPreferences" => Dict{String,Any}("backgroundThrottling" => false),
        ),
        electron_args = ["--ozone-platform=x11"],
    )
    app     = BonitoAgents.unified_app(state)
    display(disp, app)
    session = app.session[]
    # Install a JS error sink so individual tests can assert "no errors fired".
    run(disp.window, """
        window.__errs = [];
        window.addEventListener('error', e => window.__errs.push(String(e.message)));
    """)
    return (; disp, app, session, state)
end

shutdown(ctx) = (try close(ctx.disp) catch end; nothing)

"""
    set_window_size(ctx, w, h)

Resize the Electron window's renderer viewport. Uses Chromium's device-
emulation API rather than `BrowserWindow.setSize` — the latter only
shrinks the viewport on this Linux/offscreen setup (a 480→1280 resize-
back leaves `window.innerWidth` stuck at 480) and is generally subject
to OS / window-manager minimum-size constraints. Device emulation goes
straight to the compositor, so the renderer sees the exact viewport we
ask for regardless of frame state, which is what the CSS @media queries
read anyway.
"""
function set_window_size(ctx, w::Int, h::Int)
    win_id = ctx.disp.window.window.id
    run(ctx.disp.window.app, """
        const win = electron.BrowserWindow.fromId($win_id);
        // Force the renderer's reported viewport via device emulation —
        // bypasses the OS window-manager constraints that pin
        // `BrowserWindow.setSize` after a shrink.
        win.webContents.enableDeviceEmulation({
            screenPosition: 'desktop',
            screenSize:  { width: $w, height: $h },
            viewSize:    { width: $w, height: $h },
            deviceScaleFactor: 0,
            scale: 1,
        });
        // Keep the outer frame in sync (some tests read getBoundingClientRect
        // against the document; the frame size shouldn't be larger than
        // the viewport we just claimed).
        win.setMinimumSize(0, 0);
        win.setSize($w, $h);
        win.setContentSize($w, $h);
        null
    """)
    # Resize is async; wait for the renderer's reported size to catch up.
    deadline = time() + 2
    while time() < deadline
        try
            iw = run(ctx.disp.window, "window.innerWidth")
            iw isa Number && abs(iw - w) < 30 && break
        catch end
        sleep(0.05)
    end
end

"""
    seed_chat_history!(model, n; user_text="hi", agent_text="ok")

Push `n` (UserMsg, AgentMsg) pairs into `model.msgs_store` directly,
without going through the ACP path. Useful for virtual-scroll tests that
need a populated history at mount time.
"""
function seed_chat_history!(model, n::Int;
                              user_text::AbstractString = "hi",
                              agent_text::AbstractString = "ok")
    lock(model.lock) do
        for i in 1:n
            push!(model.msgs_store, BonitoAgents.UserMsg("$user_text $i"))
            push!(model.msgs_store, BonitoAgents.AgentMsg("agent-$i", "$agent_text $i"))
        end
    end
    return model
end

# ── JS evaluation / DOM probes ────────────────────────────────────────────────

"""
    eval_js(ctx, code) -> any

Run a JS expression in the renderer; return the value (must be JSON-able).
"""
eval_js(ctx, code::AbstractString) = run(ctx.disp.window, code)

"Number of elements matching `selector`."
dom_count(ctx, selector::AbstractString) =
    eval_js(ctx, "document.querySelectorAll($(JSON.json(selector))).length")

"Truthy iff at least one element matches `selector`."
dom_exists(ctx, selector::AbstractString) =
    eval_js(ctx, "document.querySelector($(JSON.json(selector))) !== null")

"BoundingClientRect of the first element matching `selector`, as Dict."
dom_rect(ctx, selector::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(selector)));
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return {x: r.x, y: r.y, w: r.width, h: r.height,
                top: r.top, bottom: r.bottom, left: r.left, right: r.right};
    })()
""")

"Inner text of the first element matching `selector` (or null)."
dom_text(ctx, selector::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(selector)));
        return el ? el.innerText : null;
    })()
""")

"Click the first element matching `selector`. No-op if absent."
dom_click(ctx, selector::AbstractString) = eval_js(ctx, """
    (() => { const el = document.querySelector($(JSON.json(selector)));
              if (el) el.click(); return el !== null; })()
""")

"""
    type_into(ctx, selector, text)

Set `.value` on the first input/textarea matching `selector` and dispatch
an `input` event so Bonito-side oninput handlers fire.
"""
function type_into(ctx, selector::AbstractString, text::AbstractString)
    eval_js(ctx, """
        (() => {
            const el = document.querySelector($(JSON.json(selector)));
            if (!el) return false;
            el.value = $(JSON.json(text));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            return true;
        })()
    """)
end

"""
    press_key(ctx, selector, key; shift=false, ctrl=false)

Dispatch a `keydown` event on the matched element.
"""
function press_key(ctx, selector::AbstractString, key::AbstractString;
                    shift::Bool=false, ctrl::Bool=false)
    eval_js(ctx, """
        (() => {
            const el = document.querySelector($(JSON.json(selector)));
            if (!el) return false;
            el.dispatchEvent(new KeyboardEvent('keydown', {
                key: $(JSON.json(key)), shiftKey: $(shift), ctrlKey: $(ctrl), bubbles: true}));
            return true;
        })()
    """)
end

"""
    wait_for(ctx, predicate_js; timeout=3.0, interval=0.05) -> Bool

Poll a JS expression that returns boolean; return true once it does, false
on timeout. Avoids hard-coded sleeps in tests.
"""
function wait_for(ctx, predicate_js::AbstractString;
                   timeout::Float64 = 3.0, interval::Float64 = 0.05)
    deadline = time() + timeout
    while time() < deadline
        try
            eval_js(ctx, "(() => { return ($predicate_js); })()") === true && return true
        catch
            # JS may throw mid-render; just keep polling.
        end
        sleep(interval)
    end
    return false
end

"Returns the JS error sink contents (empty if no errors fired)."
js_errors(ctx) = eval_js(ctx, "window.__errs || []")

# ── Screenshots ──────────────────────────────────────────────────────────────

"""
    screenshot(ctx; path=auto)

Capture the current Electron window contents to a PNG file. Returns the path.
Uses the main-process `webContents.capturePage()` API.
"""
function screenshot(ctx; path::AbstractString = tempname() * ".png")
    win_id = ctx.disp.window.window.id
    # `run(app, ...)` awaits Promises (since ElectronCall's main.js handles
    # async results in `runcode` target=`app`). Return the PNG base64 directly
    # so we don't have to round-trip through a flag file + polling.
    b64 = run(ctx.disp.window.app, """
        (async () => {
            const win = electron.BrowserWindow.fromId($win_id);
            const img = await win.webContents.capturePage();
            return img.toPNG().toString('base64');
        })()
    """)
    b64 isa AbstractString || error("screenshot returned non-string: \$(typeof(b64))")
    write(path, Base64.base64decode(b64))
    return path
end

"""
    emit_screenshot(ctx; label = "")

Capture a PNG of the current Electron window, save it to a tempfile, and
print the path. Returns the path so callers can do whatever they want
with it (open in an image viewer, attach to a CI artifact, etc.).
"""
function emit_screenshot(ctx; label::AbstractString = "")
    path = screenshot(ctx)
    println("--- ", isempty(label) ? "screenshot" : label, " saved → ", path, " ---")
    return path
end

# ── Test driver ──────────────────────────────────────────────────────────────

"""
    @test_eq actual expected

Print a PASS / FAIL line. Doesn't raise; we want every assertion to run so
one failure doesn't mask the rest.
"""
macro test_eq(actual, expected)
    actual_str  = string(actual)
    expected_str = string(expected)
    quote
        local a = $(esc(actual))
        local e = $(esc(expected))
        if isequal(a, e)
            println("  PASS  $($(actual_str)) == $($(expected_str))  ($(repr(a)))")
            true
        else
            println("  FAIL  $($(actual_str)) == $($(expected_str))")
            println("        actual:   $(repr(a))")
            println("        expected: $(repr(e))")
            false
        end
    end
end

"As above, but checks `actual` is truthy."
macro test_true(actual)
    actual_str = string(actual)
    quote
        local a = $(esc(actual))
        if a === true || (a isa Number && a > 0)
            println("  PASS  $($(actual_str))  ($(repr(a)))")
            true
        else
            println("  FAIL  $($(actual_str))")
            println("        actual: $(repr(a))")
            false
        end
    end
end

"Run a function under a banner. Use as `TH.section(\"label\") do ... end`."
function section(f, label::AbstractString)
    println("\n==> $label")
    f()
end

# The runtests.jl harness peeks at this after each include() to build a
# cross-tier summary. Test files call `TH.report!("Tier X — ...", results)`
# from their finally block; that pushes one entry per call.
const TIER_RESULTS = Tuple{String,Int,Int}[]   # (label, pass, fail)

"""
    report!(label, results)

Print the per-tier summary + per-failure breakdown, and append the tally
to `TH.TIER_RESULTS` so the harness can produce a cross-tier roll-up.
Test files call this from their `finally` block instead of hand-rolling
the summary section.
"""
function report!(label::AbstractString, results::AbstractVector)
    println("\n", "="^60)
    pass = count(p -> p.second, results)
    fail = length(results) - pass
    println("$label: $pass passed, $fail failed")
    for (name, ok) in results
        ok || println("  FAIL  $name")
    end
    push!(TIER_RESULTS, (String(label), pass, fail))
    return (pass, fail)
end

end # module TestHelpers

const TH = TestHelpers
