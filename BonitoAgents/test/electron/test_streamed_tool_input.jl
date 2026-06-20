# Streamed tool input, browser side — the DOM must grow the late-arriving
# affordances. Real claude-agent-acp sends tool arguments on a tool_call_update
# AFTER the initial tool_call (input streams), so:
#   • bt_julia_eval: the live code preview + ⏱ badge + ⊗ stop button appear
#     on the in-flight UPDATE, not the initial header — and the preview is
#     removed again on completion.
#   • Read: the ✎ edit button appears once rawInput.file_path lands, and the
#     resolved path is the REAL file (the display title "Read hello.jl" is
#     NOT a path) — clicking it opens the plotpane Monaco editor.
# Wire shapes copied from a captured real-session acp.jsonl.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]
# Mirror the real layout: claude (on the worker) reports the WORKER-side
# absolute path in rawInput.file_path; the server holds the mirrored copy
# under server_path. `show_server_path` maps one onto the other.
fpath = joinpath(proj.worker_path, "hello.jl")
write(joinpath(proj.server_path, "hello.jl"), "greet() = println(\"hi\")\n")

const EVALNAME = "mcp__btworker__bt_julia_eval"

scripted = [
    # ── eval: announcement (NO arguments), then args while running, result ──
    (0.05, TH.tool_call_update(
        id = "ev1", kind = "other", title = EVALNAME, status = "pending",
        tool_name = EVALNAME, raw_input = Dict{String,Any}())),
    (0.40, TH.tool_update(
        id = "ev1", title = EVALNAME, tool_name = EVALNAME,
        raw_input = Dict{String,Any}("code" => "sleep(2); 40 + 2",
                                      "timeout" => 60, "env_path" => "/tmp/p"))),
    (6.0, TH.tool_update(
        id = "ev1", status = "completed",
        content = [TH.tool_text("```julia\nsleep(2); 40 + 2\n```\n42")])),

    # ── read: display-title tool; the real path rides rawInput ──────────────
    (0.10, TH.tool_call_update(
        id = "rd1", kind = "read", title = "Read File", status = "pending",
        tool_name = "Read", raw_input = Dict{String,Any}())),
    (0.40, TH.tool_update(
        id = "rd1", kind = "read", title = "Read hello.jl", tool_name = "Read",
        raw_input = Dict{String,Any}("file_path" => fpath))),
    (0.40, TH.tool_update(
        id = "rd1", status = "completed",
        content = [TH.tool_text("greet() = println(\"hi\")\n")])),

    # ── agent message with a path in inline code → linkified ────────────────
    (0.20, TH.agent_chunk_update(
        "Edited `src/hello.jl` for you (`bash` is a command, not a path).")),
]

let model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport(; scripted))
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    @assert TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 5.0) "no sidebar row"
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("eval: extras appear on the in-flight update") do
        TH.type_into(ctx, ".bt-text-input", "go")
        TH.dom_click(ctx, ".bt-send-btn")
        # The pill arrives. (That the INITIAL header carries no code — the
        # wire had no arguments yet — is asserted deterministically on the
        # comm events in test_streamed_rawinput.jl; polling the DOM for the
        # preview-less moment races against the 0.4s args update.)
        record("eval pill arrives",
               @TH.test_true TH.wait_for(ctx, """
                   (() => [...document.querySelectorAll('.bt-tool-title')]
                       .some(t => t.innerText.indexOf('bt_julia_eval') !== -1))()
               """; timeout = 5.0))
        # The args update inserts preview + badge + stop WHILE running.
        record("live code preview appears on the args update",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const pv = document.querySelector('.bt-eval-preview pre');
                       return pv && pv.innerText.indexOf('sleep(2)') !== -1;
                   })()
               """; timeout = 5.0))
        record("⏱ badge inserted late",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const b = document.querySelector('.bt-tool-timeout');
                       return b && b.innerText.indexOf('60') !== -1;
                   })()
               """; timeout = 3.0))
        record("⊗ stop button inserted late",
               @TH.test_true TH.dom_exists(ctx, ".bt-tool-stop"))
        record("pill still live while preview shows",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const n = [...document.querySelectorAll('.bt-tool-msg')]
                           .find(x => x.querySelector('.bt-tool-body[data-tool-id="ev1"]'));
                       return n && n.classList.contains('bt-tool-live');
                   })()
               """))
        record("preview removed on completion",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const n = [...document.querySelectorAll('.bt-tool-msg')]
                           .find(x => x.querySelector('.bt-tool-body[data-tool-id="ev1"]'));
                       const s = n && n.querySelector('.bt-tool-status');
                       return s && s.textContent === 'completed' &&
                              document.querySelector('.bt-eval-preview') === null;
                   })()
               """; timeout = 12.0))
    end

    TH.section("read: title becomes a path link via late rawInput; click opens the editor") do
        record("title turns into a path link carrying the REAL path",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const n = [...document.querySelectorAll('.bt-tool-msg')]
                           .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                       const t = n && n.querySelector('.bt-tool-title.bt-path-link');
                       return t !== null && t !== undefined &&
                              t.dataset.path === $(repr(fpath));
                   })()
               """; timeout = 6.0))
        TH.eval_js(ctx, """
            (() => {
                const n = [...document.querySelectorAll('.bt-tool-msg')]
                    .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                const t = n && n.querySelector('.bt-tool-title.bt-path-link');
                if (t) t.click();
            })()
        """)
        record("title-link click does NOT expand the pill",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const n = [...document.querySelectorAll('.bt-tool-msg')]
                           .find(x => x.querySelector('.bt-tool-body[data-tool-id="rd1"]'));
                       const h = n && n.querySelector('.bt-tool-header');
                       return h && h.dataset.expanded === 'false';
                   })()
               """))
        record("path-link click opens editable Monaco in the plotpane",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const mount = document.getElementById('bt-plotpane-mount');
                       return mount && mount.querySelector('.bt-file-editor .monaco-editor') !== null;
                   })()
               """; timeout = 10.0))
        record("editor carries the file content (real path, not the title)",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const mount = document.getElementById('bt-plotpane-mount');
                       return mount && (mount.innerText || '').indexOf('greet') !== -1;
                   })()
               """; timeout = 5.0))
    end

    TH.section("agent message: path-looking code spans are linkified") do
        record("`src/hello.jl` code span becomes a path link",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const l = document.querySelector('.bt-agent-msg code.bt-path-link');
                       return l !== null && l.dataset.path === 'src/hello.jl';
                   })()
               """; timeout = 6.0))
        record("plain `bash` code span stays unlinked",
               @TH.test_true TH.eval_js(ctx, """
                   (() => [...document.querySelectorAll('.bt-agent-msg code')]
                       .some(c => c.textContent === 'bash' &&
                                  !c.classList.contains('bt-path-link')))()
               """))
    end

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "streamed tool input — final")
finally
    TH.report!("Streamed tool input", results)
    TH.shutdown(ctx)
end
