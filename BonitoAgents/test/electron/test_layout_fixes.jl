# Regression tests for the layout fixes from the dvh / .bt-dash scroll /
# .bt-session-info min-width: 0 round, plus the chat-spinner remount fix.

isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using Bonito

state = TH.make_state(; n_workers = 10, n_projects = 6)
for (i, w) in enumerate(values(state.workers[]))
    w.status = isodd(i) ? :online : :offline
end

# Slow-streaming scripted response so test 4 can navigate home/back while
# the prompt is still in flight on the shared ChatModel.
slow_scripted = [
    (1.5, TH.agent_chunk_update("thinking…")),   # 1.5s gap → window to navigate
]
let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport(; scripted = slow_scripted))
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Dashboard is its own scroll container") do
        # Narrow + short viewport — 10 workers + 6 projects guarantee
        # the dashboard exceeds 600px and needs to scroll.
        TH.set_window_size(ctx, 480, 600)
        sleep(0.3)
        scroll_info = TH.eval_js(ctx, """
            (() => {
                const d = document.querySelector('.bt-dash');
                if (!d) return null;
                d.scrollTop = 200;
                return { scrollHeight: d.scrollHeight,
                         clientHeight: d.clientHeight,
                         scrollTop:    d.scrollTop };
            })()
        """)
        record("dashboard content exceeds viewport height",
               @TH.test_true (scroll_info["scrollHeight"] > scroll_info["clientHeight"] + 50))
        # Pre-fix bug: `.bt-main` had `overflow: hidden` and `.bt-dash`
        # had `min-height: 100vh`, so the overflow was clipped and
        # `scrollTop` couldn't advance.
        record("scrollTop advances past 0 (scroll is active)",
               @TH.test_true (scroll_info["scrollTop"] >= 150))
    end

    TH.section("Project card actions don't overflow on mobile") do
        # ~390px is the typical mobile viewport (matches the user's
        # screenshot where the "Open chat on <worker>" button hung off
        # the right of the card). Pre-fix bug: `.bt-card-actions` had
        # `margin-left: auto` even on mobile, so the cluster sized to
        # its content and right-aligned, leaving `flex-wrap: wrap` with
        # no room to actually wrap. The button cluster overflowed the
        # card. Post-fix the cluster takes `width: 100%` on mobile, so
        # the wrap kicks in cleanly.
        TH.set_window_size(ctx, 390, 800)
        sleep(0.3)
        # Scroll the dashboard so a project card is in view, then probe
        # the first one. All project cards share the same CSS, so the
        # first card is representative.
        overflow_info = TH.eval_js(ctx, """
            (() => {
                const dash = document.querySelector('.bt-dash');
                if (dash) dash.scrollTop = 800;   // bring projects into view
                const cards = document.querySelectorAll('.bt-cards')[1]; // [0]=workers, [1]=projects
                const card  = cards && cards.querySelector('.bt-card');
                const acts  = card && card.querySelector('.bt-card-actions');
                if (!card || !acts) return null;
                const cardR = card.getBoundingClientRect();
                const actsR = acts.getBoundingClientRect();
                // Also probe the open-chat link's right edge directly —
                // that's the element that overflowed in the screenshot.
                const open  = acts.querySelector('.bt-open-on');
                const openR = open ? open.getBoundingClientRect() : null;
                return {
                    card_right:  cardR.right,
                    card_width:  cardR.width,
                    acts_right:  actsR.right,
                    acts_width:  actsR.width,
                    open_right:  openR ? openR.right : null,
                };
            })()
        """)
        @assert overflow_info !== nothing "couldn't find a project card to probe"
        record("project card actions stay inside the card",
               @TH.test_true (overflow_info["acts_right"] <= overflow_info["card_right"] + 1))
        if overflow_info["open_right"] !== nothing
            record("open-chat link stays inside the card",
                   @TH.test_true (overflow_info["open_right"] <= overflow_info["card_right"] + 1))
        end
    end

    TH.section("Mobile: buttons never wrap their own text") do
        # Pre-fix bug: `.bt-btn` was `display: inline-flex` with no
        # `white-space: nowrap`. On narrow viewports the "+ New project"
        # button wrapped its label onto two lines ("+ New" / "project"),
        # which looks broken. Probe every button on the page; any with
        # `scrollHeight > clientHeight + 1` is wrapping text vertically.
        TH.set_window_size(ctx, 360, 800)
        sleep(0.3)
        wraps = TH.eval_js(ctx, """
            (() => {
                const out = [];
                for (const b of document.querySelectorAll('.bt-btn')) {
                    if (b.offsetParent === null) continue;  // skip hidden
                    if (b.scrollHeight > b.clientHeight + 1) {
                        out.push(b.innerText.trim().slice(0, 30));
                    }
                }
                return out;
            })()
        """)
        record("no .bt-btn wraps its label across lines at 360px",
               @TH.test_eq length(wraps) 0)
    end

    TH.section("Mobile: section heading and form buttons stack cleanly") do
        # The PROJECTS section header has h2 + "+ New project" + "+ From
        # GitHub". At 390px these can't fit on one row. Post-fix mobile
        # CSS gives the h2 `flex: 1 0 100%` so it takes its own row and
        # the buttons wrap onto a second row. Verify by checking the h2's
        # bottom is above the buttons' tops.
        TH.set_window_size(ctx, 390, 800)
        sleep(0.3)
        TH.eval_js(ctx, "document.querySelector('.bt-dash').scrollTop = 400")
        sleep(0.2)
        info = TH.eval_js(ctx, """
            (() => {
                // The Projects section is the .bt-section whose h2 says
                // 'Projects'. Find it explicitly so we're not at the
                // mercy of insertion order.
                const sections = document.querySelectorAll('.bt-section');
                for (const sec of sections) {
                    const h2  = sec.querySelector('h2');
                    if (!h2 || h2.innerText.toLowerCase() !== 'projects') continue;
                    const btns = sec.querySelectorAll('.bt-btn');
                    if (btns.length < 2) return null;
                    const h2R = h2.getBoundingClientRect();
                    const b1R = btns[0].getBoundingClientRect();
                    const b2R = btns[1].getBoundingClientRect();
                    return {
                        h2_bottom: h2R.bottom, h2_left: h2R.left,
                        b1_top: b1R.top, b1_right: b1R.right,
                        b2_top: b2R.top, b2_right: b2R.right,
                        sec_right: sec.getBoundingClientRect().right,
                    };
                }
                return null;
            })()
        """)
        @assert info !== nothing "couldn't find PROJECTS section header"
        record("h2 sits on its own row above the buttons",
               @TH.test_true (info["b1_top"] >= info["h2_bottom"] - 1))
        record("both header buttons stay inside the section",
               @TH.test_true (info["b1_right"] <= info["sec_right"] + 1 &&
                              info["b2_right"] <= info["sec_right"] + 1))
    end

    TH.section("Chat input stays in viewport at small heights") do
        # Navigate to Project1's chat (which we pre-seeded with a ChatModel
        # above). Then shrink the viewport — with the pre-fix `100vh` on
        # `.bt-shell`, the chat input is positioned below the visible area
        # whenever the rendered viewport is shorter than 100vh. Post-fix
        # (`100dvh`), `.bt-shell` follows the rendered viewport exactly,
        # so the input row stays inside `window.innerHeight`.
        TH.set_window_size(ctx, 1280, 800)
        sleep(0.2)
        p1_idx = TH.eval_js(ctx, """
            (() => {
                const items = document.querySelectorAll('.bt-side-item .bt-side-name');
                for (let i = 0; i < items.length; i++)
                    if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
                return -1;
            })()
        """)
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
        @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null";
                              timeout = 4.0) "chat didn't mount"

        TH.set_window_size(ctx, 420, 640)
        sleep(0.3)
        layout = TH.eval_js(ctx, """
            (() => {
                const inp   = document.querySelector('.bt-input-area');
                const shell = document.querySelector('.bt-shell');
                if (!inp || !shell) return null;
                return { input_bottom:    inp.getBoundingClientRect().bottom,
                         shell_height:    shell.getBoundingClientRect().height,
                         inner_height:    window.innerHeight };
            })()
        """)
        record("shell height matches the rendered viewport",
               @TH.test_true (abs(layout["shell_height"] - layout["inner_height"]) < 4))
        record("input row bottom is inside the viewport",
               @TH.test_true (layout["input_bottom"] <= layout["inner_height"] + 1))

        # Chat header: pre-fix `.bt-header-sync` had `min-width: 260px` so
        # the Sync button covered the project name on phone-width viewports.
        # Post-fix mobile rule sets `min-width: 0; flex: 0 1 auto`, and
        # `.bt-header-title` gets `flex: 1 1 auto` so it takes the
        # remaining row width.
        header = TH.eval_js(ctx, """
            (() => {
                const t = document.querySelector('.bt-header-title');
                const s = document.querySelector('.bt-header-sync');
                if (!t || !s) return null;
                const tR = t.getBoundingClientRect();
                const sR = s.getBoundingClientRect();
                return {title_w: tR.width, sync_w: sR.width,
                        title_right: tR.right, sync_left: sR.left};
            })()
        """)
        @assert header !== nothing "couldn't find chat header probe targets"
        record("chat header title gets meaningful width (not crushed)",
               @TH.test_true (header["title_w"] >= 80))
        record("Sync button doesn't dominate the row",
               @TH.test_true (header["sync_w"] <= 100))
        record("title doesn't overlap Sync button",
               @TH.test_true (header["title_right"] <= header["sync_left"] + 1))
    end

    TH.section("Spinner restored on chat remount mid-prompt") do
        # Send a prompt — the scripted transport has a 1.5s delay before
        # the first chunk, so we have a window to navigate away. Pre-fix,
        # the spinner was driven by transient `busy_start` events over
        # `comm`; the new per-session bridge after remount didn't see
        # the original event, so the dots stayed hidden until busy_end
        # — making it look like nothing was happening.
        TH.set_window_size(ctx, 1280, 800)
        sleep(0.2)
        TH.type_into(ctx, ".bt-text-input", "are you there?")
        TH.dom_click(ctx, ".bt-send-btn")
        record("busy spinner activates after send",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-busy.bt-busy-active') !== null";
                   timeout = 3.0))

        # Navigate to home, then back to the project. The DOM subsession
        # for the chat tears down and re-mounts; on the new mount we
        # expect the spinner to still be active because the prompt is
        # still in flight on the shared ChatModel.
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[0].click()""")
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-text-input') === null";
            timeout = 3.0) "chat didn't unmount on Home click"
        sleep(0.2)

        p1_idx = TH.eval_js(ctx, """
            (() => {
                const items = document.querySelectorAll('.bt-side-item .bt-side-name');
                for (let i = 0; i < items.length; i++)
                    if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
                return -1;
            })()
        """)
        TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
        @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null";
                              timeout = 3.0) "chat didn't remount"

        record("busy spinner is visible after remount (still streaming)",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-busy.bt-busy-active') !== null";
                   timeout = 2.0))

        # And finally — after the scripted response completes, the spinner
        # clears. Confirms busy_active is properly toggled off via the
        # finally block in send_prompt_async!.
        record("spinner clears once response finishes",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-busy.bt-busy-active') === null";
                   timeout = 8.0))
    end

    TH.section("No JS errors") do
        record("zero JS errors during the layout fixture exercise",
               @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "tier 3b — layout fixes")

    TH.section("Session-row info column constrains long paths") do
        # Run LAST: navigates the window away from unified_app to mount a
        # one-shot probe page. Bonito's `display(disp, app)` re-mount of
        # unified_app loses the worker/project KeyedList contents (cards
        # don't repopulate), so we don't try to come back — once we leave
        # the dashboard, this is the last assertion the window does.
        #
        # Pre-fix bug: `.bt-session-row` is a flex container, but its text
        # column had no min-width: 0, so the monospace nowrap path grew
        # the column and pushed the Import button off the right edge.
        long_path = "/sim/Programmieren/" * repeat("very_long_subdirectory/", 10) * "ProjectFolder"
        record_card = BonitoAgents.WorkerCard(state, "w-1";
            error_obs        = Observable(""),
            picker_state     = Observable(""),
            discover_state   = Observable(""),
            busy             = Observable(BonitoAgents.BUSY_IDLE),
            discover_busy    = Observable(false),
            discover_results = Observable(Dict{String,Any}[]),
            import_path      = Observable(Dict{String,Any}()),
            do_import        = (w, p; kw...) -> nothing,
            trigger_scan     = w -> nothing)
        row = BonitoAgents.SessionRow(record_card, Dict{String,Any}(
            "path"       => long_path,
            "name"       => "deeply-nested-project",
            "active"     => false,
            "session_id" => "abc",
            "last_used"  => 0.0))

        probe_app = Bonito.App() do session
            Bonito.DOM.div(
                BonitoAgents.DashboardStyles,
                Bonito.jsrender(session, row);
                id    = "probe",
                style = Bonito.Styles("width" => "320px", "padding" => "8px",
                                       "box-sizing" => "border-box"))
        end
        # Restore a wide viewport so the 320px wrapper actually fits,
        # then mount the probe.
        TH.set_window_size(ctx, 1280, 800)
        display(ctx.disp, probe_app)
        @assert TH.wait_for(ctx, "document.querySelector('.bt-session-row') !== null";
                              timeout = 4.0) "session-row probe didn't mount"

        row_rect = TH.dom_rect(ctx, ".bt-session-row")
        btn_rect = TH.dom_rect(ctx, ".bt-session-row .bt-btn")
        record("button right edge stays inside row",
               @TH.test_true (btn_rect["right"] <= row_rect["right"] + 1))
        record("path text gets truncated (overflow hidden)",
               @TH.test_true TH.eval_js(ctx, """
                   (() => {
                       const el = document.querySelector('.bt-session-path');
                       return el && el.scrollWidth > el.clientWidth;
                   })()
               """))
    end

    TH.section("Mobile: Discover panel header stacks (title above actions)") do
        # On the worker card, clicking Discover opens a panel whose header
        # is "Claude Code sessions on <worker>" + ↻ Rescan + close button.
        # On 360-390px viewports all three on one row leaves Rescan and
        # the close button squashed. Post-fix the mobile media query gives
        # `.bt-discover-header` `flex-direction: column` so the title takes
        # its own row and the actions cluster right-aligns below.
        #
        # Use a probe app to render the WorkerCard directly so we don't
        # depend on the live dashboard re-mount issue (we've already left
        # unified_app at this point).
        record_card = BonitoAgents.WorkerCard(state, "w-1";
            error_obs        = Observable(""),
            picker_state     = Observable(""),
            discover_state   = Observable("w-1"),       # open from the start
            busy             = Observable(BonitoAgents.BUSY_IDLE),
            discover_busy    = Observable(false),
            discover_results = Observable(Dict{String,Any}[]),
            import_path      = Observable(Dict{String,Any}()),
            do_import        = (w, p; kw...) -> nothing,
            trigger_scan     = w -> nothing)
        probe_app = Bonito.App() do session
            Bonito.DOM.div(
                BonitoAgents.DashboardStyles,
                Bonito.jsrender(session, record_card);
                id    = "probe-discover",
                style = Bonito.Styles("width" => "340px", "padding" => "8px",
                                       "box-sizing" => "border-box"))
        end
        TH.set_window_size(ctx, 390, 800)
        sleep(0.2)
        display(ctx.disp, probe_app)
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-discover-header') !== null"; timeout = 4.0) "discover-header probe didn't mount"

        info = TH.eval_js(ctx, """
            (() => {
                const hdr  = document.querySelector('.bt-discover-header');
                const ttl  = hdr.querySelector('.bt-discover-title');
                const acts = hdr.querySelector('.bt-discover-actions');
                if (!ttl || !acts) return null;
                const tR = ttl.getBoundingClientRect();
                const aR = acts.getBoundingClientRect();
                const hR = hdr.getBoundingClientRect();
                return {
                    title_bottom: tR.bottom, title_right: tR.right,
                    acts_top:     aR.top,    acts_right:  aR.right,
                    hdr_right:    hR.right,
                };
            })()
        """)
        @assert info !== nothing "couldn't find discover-header elements"
        # Title row sits above actions row (allow a 4px tolerance for
        # layout rounding / line-height fudge).
        record("Discover title sits above the actions cluster",
               @TH.test_true (info["acts_top"] >= info["title_bottom"] - 4))
        # Actions cluster fits inside the panel
        record("Rescan + close buttons stay inside the panel",
               @TH.test_true (info["acts_right"] <= info["hdr_right"] + 1))
    end

    TH.section("Mobile: session-row active badge doesn't overlap Resume btn") do
        # Long project names ("ClaudeExperiments-very-long-name") used to
        # push the active badge into / under the Resume button on mobile.
        # Fix wraps the name string in `.bt-session-name-text` so it can
        # ellipsize, and the `.bt-pill` itself is now `flex-shrink: 0`
        # plus `white-space: nowrap` so its label never wraps internally.
        # Probe at 340px wrapper width — the inner width of a worker card
        # on a 390px viewport.
        record_card = BonitoAgents.WorkerCard(state, "w-1";
            error_obs        = Observable(""),
            picker_state     = Observable(""),
            discover_state   = Observable(""),
            busy             = Observable(BonitoAgents.BUSY_IDLE),
            discover_busy    = Observable(false),
            discover_results = Observable(Dict{String,Any}[]),
            import_path      = Observable(Dict{String,Any}()),
            do_import        = (w, p; kw...) -> nothing,
            trigger_scan     = w -> nothing)
        row_long = BonitoAgents.SessionRow(record_card, Dict{String,Any}(
            "path"       => "/sim/Programmieren/ClaudeExperiments-very-long-name",
            "name"       => "ClaudeExperiments-very-long-name",
            "active"     => true,
            "session_id" => "abc",
            "pid"        => 10343))
        probe_app = Bonito.App() do session
            Bonito.DOM.div(
                BonitoAgents.DashboardStyles,
                Bonito.jsrender(session, row_long);
                id    = "probe-active",
                style = Bonito.Styles("width" => "340px", "padding" => "8px",
                                       "box-sizing" => "border-box"))
        end
        display(ctx.disp, probe_app)
        @assert TH.wait_for(ctx,
            "document.querySelector('.bt-pill-active') !== null"; timeout = 4.0) "session-row active probe didn't mount"

        layout = TH.eval_js(ctx, """
            (() => {
                const row   = document.querySelector('.bt-session-row');
                const badge = row.querySelector('.bt-pill-active');
                const btn   = row.querySelector('.bt-btn');
                const text  = row.querySelector('.bt-session-name-text');
                if (!row || !badge || !btn) return null;
                const rR = row.getBoundingClientRect();
                const aR = badge.getBoundingClientRect();
                const bR = btn.getBoundingClientRect();
                return {
                    badge_right: aR.right, btn_left: bR.left,
                    btn_right:   bR.right, row_right: rR.right,
                    text_truncated: text ? text.scrollWidth > text.clientWidth : false,
                };
            })()
        """)
        @assert layout !== nothing "couldn't find session-row probe elements"
        record("active badge stays clear of the Resume button",
               @TH.test_true (layout["badge_right"] + 1 < layout["btn_left"]))
        record("Resume button stays inside the row",
               @TH.test_true (layout["btn_right"] <= layout["row_right"] + 1))
        record("long session name ellipsizes",
               @TH.test_true layout["text_truncated"])
    end

finally
    TH.report!("Tier 3b — layout fixes", results)
    TH.shutdown(ctx)
end
