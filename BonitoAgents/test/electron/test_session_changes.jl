# In-window verification for the batch of dev changes shipped this session.
# Boots a real serve()-style setup against a `MockTransport` and exercises:
#
#   #1 centered SummaryMsg renders with `.bt-summary-msg` class + html body
#   #2 tool pill's wide-mode toggle (`.bt-tool-fullwidth` button) adds
#       `.bt-tool-wide-active` (independent of expand/collapse — clicking the
#       button does NOT toggle the body)
#   #5 `.bt-tool-title` stays selectable (Read paths are copy-pasteable) —
#       the header deliberately has NO user-select rule (see styles.jl), so
#       the computed value must just not be `none`
#   #6 streamed agent chunks render as CommonMark — `**bold**`, `_emph_`, and
#       intraword `_` left alone (no italic-eats-underscore)
#   #7 sidebar resumable row appears for a project whose worker has a
#       `running:true` discovered session but isn't in `chat_models`
#   #8 localStorage `bt-last-pid` updates on view change (the last-route memory
#       that complements Bonito's soft_close window). The stored value is
#       `<boot-id>|<pid>` (sidebar.jl LAST_PID_KEY), so we match the suffix.
#   #9 a UserMsg pushed while `busy_active[]` is true gets `.bt-queued`, and
#       `promote_queued_user_bubble!` clears it
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents, JSON
const BT = BonitoAgents

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]

# A reusable scripted agent-message chunk carrying markdown that exercises
# every render path the changes touched: bold, emph at word boundaries, and
# intraword underscores that must stay literal.
const MD_TEXT = "**hello** _world_ path/foo_bar_baz.jl"

scripted = [
    (0.05, TH.agent_chunk_update(MD_TEXT)),
    (0.05, TH.tool_call_update(
        id = "t-wide", kind = "execute", title = "ls -la", status = "completed",
        content = [TH.tool_text("file1.txt\nfile2.txt\nfile3.txt")])),
]

# Build the chat model + register it so the sidebar can find it.
let m = BT.ChatModel(state, proj.server_path;
                       project_id = proj.id,
                       transport  = TH.mock_transport(; scripted))
    BT.start_chat_client!(m)
end

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    # ── Navigate into Project1 (waiting for the sidebar row to mount). ───
    @assert TH.wait_for(ctx,
        "document.querySelector('.bt-side-item[data-project-id=\"p-1\"]') !== null";
        timeout = 10.0) "Project1 row never appeared in sidebar"
    TH.eval_js(ctx,
        "document.querySelector('.bt-side-item[data-project-id=\"p-1\"]').click()")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null";
                        timeout = 10.0) "chat didn't mount"
    chat = state.chat_models["p-1"]

    # ── #6 streamed CommonMark ────────────────────────────────────────────
    TH.section("Streaming chunks render as CommonMark") do
        TH.type_into(ctx, ".bt-text-input", "go")
        TH.dom_click(ctx, ".bt-send-btn")
        record("agent bubble landed",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-agent-msg').length >= 1";
                   timeout = 5.0))
        # The streaming wire_chunk now ships html, so the rendered DOM should
        # contain real markdown tags rather than the raw asterisks/underscores.
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-agent-msg').innerHTML.indexOf('<strong>') !== -1";
            timeout = 5.0) "agent bubble never got <strong> from `**bold**`"
        html = TH.eval_js(ctx, "document.querySelector('.bt-agent-msg').innerHTML")
        record("bold rendered", @TH.test_true occursin("<strong>hello</strong>", html))
        record("emph rendered", @TH.test_true occursin("<em>world</em>", html))
        # The exact bug the user flagged: `xxx_xxx` italicized the middle word
        # under stdlib Markdown. Strict CommonMark must keep the literal text.
        record("intraword `_` stays literal",
               @TH.test_true occursin("path/foo_bar_baz.jl", html))
        record("no italic ate the underscore",
               @TH.test_true !occursin("<em>bar</em>", html))
    end

    # ── #2 tool pill wide toggle ──────────────────────────────────────────
    TH.section("Tool pill: expand-to-full-chat-width toggle") do
        record("tool mounted",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-tool-msg').length >= 1";
                   timeout = 5.0))
        record("wide button present",
               @TH.test_true TH.dom_exists(ctx, ".bt-tool-msg .bt-tool-fullwidth"))
        # Before clicking: not in wide mode, header collapsed.
        before = TH.eval_js(ctx,
            "document.querySelector('.bt-tool-msg').classList.contains('bt-tool-wide-active')")
        record("not wide initially", @TH.test_eq before false)
        TH.dom_click(ctx, ".bt-tool-msg .bt-tool-fullwidth")
        after = TH.eval_js(ctx,
            "document.querySelector('.bt-tool-msg').classList.contains('bt-tool-wide-active')")
        record("wide-active class after click", @TH.test_eq after true)
        # Critical: the wide click MUST NOT toggle expand/collapse. The header's
        # `data-expanded` stays "false" after the wide click.
        expanded = TH.eval_js(ctx,
            "document.querySelector('.bt-tool-header').dataset.expanded")
        record("wide click did not expand body", @TH.test_eq expanded "false")
        # Toggle off.
        TH.dom_click(ctx, ".bt-tool-msg .bt-tool-fullwidth")
        record("wide-active class removed",
               @TH.test_eq TH.eval_js(ctx,
                   "document.querySelector('.bt-tool-msg').classList.contains('bt-tool-wide-active')") false)
    end

    # ── #5 user-select on tool title ──────────────────────────────────────
    # The header deliberately carries NO user-select rule (styles.jl): text
    # selects by default (`auto`), only chrome like the ▶ glyph opts out via
    # `none`. So the contract is "anything but none".
    TH.section("Tool title is text-selectable (copyable paths)") do
        sel = TH.eval_js(ctx,
            "getComputedStyle(document.querySelector('.bt-tool-title')).userSelect")
        record("title user-select != none", @TH.test_true String(sel) != "none")
    end

    # ── #1 centered session summary ───────────────────────────────────────
    TH.section("SummaryMsg renders centered with rendered html") do
        # Push a SummaryMsg through the normal send! path; the wire_new event
        # lands in the JS event handler and createNode renders it centered.
        BT.send!(chat,
            BT.SummaryMsg(chat,
                BT.SUMMARY_PREFIX *
                " This is the **previous** turn's summary."))
        record("summary node appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-summary-msg').length >= 1";
                   timeout = 3.0))
        # Streaming-open placeholder shows the "loading…" hint; we did NOT call
        # `close(...)` so the placeholder is still the active content. That's
        # the streaming wire shape working as designed.
        record("summary has placeholder body",
               @TH.test_true TH.dom_exists(ctx, ".bt-summary-msg .bt-summary-body"))
        # Sanity that it's centered: align-self resolves to `center`.
        align = TH.eval_js(ctx,
            "getComputedStyle(document.querySelector('.bt-summary-msg')).alignSelf")
        record("align-self == center", @TH.test_eq String(align) "center")
    end

    # ── #9 queued user bubble ─────────────────────────────────────────────
    # `send_message!` would push to `user_messages` and the consumer would pop
    # + promote so fast that the JS race window vanishes — that's the
    # production "consumer is idle" path, where the bubble briefly flashes
    # queued and the test would never see it. To observe the visible state,
    # we inject a UserMsg via `send!` directly (no channel push), then drive
    # `promote_queued_user_bubble!` from the test thread.
    TH.section("Queued user bubble renders with bt-queued + clears on promote") do
        queued = BT.UserMsg(chat, "queued question")
        queued.queued = true
        BT.send!(chat, queued)
        @assert TH.wait_for(ctx, """
            (() => {
                const us = document.querySelectorAll('.bt-user-msg');
                const last = us[us.length - 1];
                return last && last.classList.contains('bt-queued');
            })()
        """; timeout = 3.0) "queued bubble never gained bt-queued class"
        record("last user bubble has bt-queued", true)

        BT.promote_queued_user_bubble!(chat)
        @assert TH.wait_for(ctx,
            "document.querySelectorAll('.bt-user-msg.bt-queued').length === 0";
            timeout = 3.0) "queued class never cleared after user_unqueue"
        record("queued class cleared after promote", true)
    end

    # ── #8 last-route memory in localStorage ──────────────────────────────
    # Stored as `<boot-id>|<pid>` (the boot-id scopes the memory to one server
    # run — see LAST_PID_KEY in sidebar.jl), so match the `|pid` suffix.
    TH.section("Last route persists to localStorage") do
        stored = TH.eval_js(ctx, "localStorage.getItem('bt-last-pid')")
        record("localStorage[bt-last-pid] ends with '|p-1'",
               @TH.test_true endswith(String(stored), "|p-1"))
        # Navigate to home; the pid part should update to empty.
        TH.eval_js(ctx,
            "document.querySelector('.bt-side-item[data-project-id=\"\"]').click()")
        sleep(0.3)
        record("localStorage[bt-last-pid] pid part empty after home",
               @TH.test_true endswith(
                   String(TH.eval_js(ctx, "localStorage.getItem('bt-last-pid')")), "|"))
    end

    # ── #3 plotpane resize handle ─────────────────────────────────────────
    # The handle on the plotpane's left edge resizes the CHAT column: it sets
    # `--bt-chat-width` on `.bt-main` during the drag (clamped to
    # [CHAT_MIN=480, CHAT_MAX=1400]) and notifies a Julia-side saver on
    # release (no localStorage — see PopupController.setupDivider in
    # popup.js). Double-click clears the override. The plotpane is hidden by
    # default (`width:0`); we force the visible-class on to make the handle
    # interactive.
    TH.section("Plotpane resize handle drives --bt-chat-width on .bt-main") do
        record("plotpane element present",
               @TH.test_true TH.dom_exists(ctx, "#bt-plotpane-dropzone"))
        record("resize handle present",
               @TH.test_true TH.dom_exists(ctx, "#bt-plotpane-dropzone .bt-pp-resize"))

        # Make it visible + run a drag.
        TH.eval_js(ctx, """
            (() => {
                const pp = document.getElementById('bt-plotpane-dropzone');
                pp.classList.add('bt-plotpane-visible');
                const main = pp.closest('.bt-stage')?.querySelector('.bt-main');
                if (main) main.style.removeProperty('--bt-chat-width');
                return true;
            })()""")
        sleep(0.2)
        # Drag the handle 120 px to the RIGHT (the handle sizes the chat
        # column, so rightward widens the chat).
        TH.eval_js(ctx, """
            (() => {
                const handle = document.querySelector('#bt-plotpane-dropzone .bt-pp-resize');
                const r = handle.getBoundingClientRect();
                const startX = r.left + r.width / 2;
                const startY = r.top  + r.height / 2;
                handle.dispatchEvent(new PointerEvent('pointerdown',
                    { clientX: startX, clientY: startY, bubbles: true }));
                window.dispatchEvent(new PointerEvent('pointermove',
                    { clientX: startX + 120, clientY: startY, bubbles: true }));
                window.dispatchEvent(new PointerEvent('pointerup',
                    { clientX: startX + 120, clientY: startY, bubbles: true }));
                return true;
            })()""")
        chat_w_js = """
            (() => {
                const pp = document.getElementById('bt-plotpane-dropzone');
                const main = pp.closest('.bt-stage')?.querySelector('.bt-main');
                return main ? main.style.getPropertyValue('--bt-chat-width') : '';
            })()"""
        @assert TH.wait_for(ctx, "($chat_w_js).length > 0";
            timeout = 2.0) "drag never wrote --bt-chat-width"
        new_w = TH.eval_js(ctx, "parseFloat($chat_w_js)")
        record("--bt-chat-width clamped into [480, 1400]",
               @TH.test_true (480.0 <= Float64(new_w) <= 1400.0))

        # Double-click on the handle should clear the override.
        TH.eval_js(ctx, """
            (() => {
                const handle = document.querySelector('#bt-plotpane-dropzone .bt-pp-resize');
                handle.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
                return true;
            })()""")
        sleep(0.2)
        record("dblclick cleared inline --bt-chat-width",
               @TH.test_eq String(TH.eval_js(ctx, chat_w_js)) "")

        # Clean up — drop the bt-plotpane-visible class so later sections start fresh.
        TH.eval_js(ctx,
            "document.getElementById('bt-plotpane-dropzone').classList.remove('bt-plotpane-visible')")
    end

    # ── #4 FloatingWindow hides on home navigation ────────────────────────
    # The on(current_view) handler in install_popup! flips visible[] = false
    # when navigating to home. To exercise it we first have to flip the FW
    # ON — the handler ignores no-op transitions (Observable doesn't notify on
    # same value). There is no window-global controller anymore (the
    # PopupController is observable-driven); the supported route is the chat
    # comm's `detach_app` command, which lands in DetachAppCommand →
    # `pane.detach_app[] = id` → controller.detach(id). detach() looks for a
    # `bt-embed-<id>` element + `bt-slot-<id>` slot; we create fakes. After
    # detach the FW's inline `display` should be `flex`. Then click Home and
    # assert it flips back to `none`.
    TH.section("FloatingWindow auto-hides when navigating Home") do
        # Re-open Project1 first (we navigated to home earlier).
        TH.eval_js(ctx,
            "document.querySelector('.bt-side-item[data-project-id=\"p-1\"]').click()")
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-text-input') !== null"; timeout = 5.0) "chat re-mount failed"

        # Stage: create a fake embed + a fake slot so detach() can find it,
        # then route the detach through the comm (the ⤢ button's path).
        TH.eval_js(ctx, """
            (() => {
                if (!document.getElementById('bt-embed-fake')) {
                    const embed = document.createElement('div');
                    embed.id = 'bt-embed-fake';
                    embed.textContent = 'fake embed';
                    document.body.appendChild(embed);
                    const slot = document.createElement('div');
                    slot.id = 'bt-slot-fake';
                    document.body.appendChild(slot);
                }
                document.querySelector('.bt-messages').__bt_chat
                    .comm.notify({ type: 'detach_app', id: 'fake' });
                return true;
            })()""")
        @assert TH.wait_for(ctx, """(() => {
            const fw = document.querySelector('.bn-floating-window');
            return fw && getComputedStyle(fw).display !== 'none';
        })()"""; timeout = 3.0) "FW never became visible after detach"
        record("FW visible after detach", true)

        # Navigate to home — Julia handler should set visible[] = false → applyVis
        # → inline style.display = 'none'.
        TH.eval_js(ctx,
            "document.querySelector('.bt-side-item[data-project-id=\"\"]').click()")
        @assert TH.wait_for(ctx, """(() => {
            const fw = document.querySelector('.bn-floating-window');
            return fw && getComputedStyle(fw).display === 'none';
        })()"""; timeout = 3.0) "FW never hid on home navigation"
        record("FW hidden after navigating home", true)
    end

    # ── #7 sidebar keeps a touched project after chat teardown ────────────
    # The old `bt-side-resumable` row class is gone: the sidebar now renders
    # ONE unified "Open chats" list — a project is listed iff the user has
    # touched it (title backfilled / resume_session_id persisted in
    # projects.json), independent of whether a live ChatModel exists; the
    # per-entry LED encodes liveness instead. So the contract to guard is:
    # tearing down the live ChatModel must NOT drop the project's row.
    TH.section("Touched project row survives ChatModel teardown") do
        lock(state.lock) do
            delete!(state.chat_models, "p-1")
        end
        BT.notify_chats!(state)
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-side-item[data-project-id=\"p-1\"]') !== null";
            timeout = 3.0) "project row vanished after chat teardown"
        record("row still mounted without a live ChatModel", true)
    end

    # ── JS errors gate ────────────────────────────────────────────────────
    TH.section("No JS errors during the run") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_eq length(errs) 0)
        isempty(errs) || @info "JS errors:" errs
    end

finally
    TH.report!("Session changes — in-window e2e", results)
    TH.shutdown(ctx)
end
