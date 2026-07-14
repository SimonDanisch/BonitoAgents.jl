# End-to-end: closing a chat from the homebar, and chat-name persistence /
# consistency. UI-driven (real sidebar ✕ clicks, real header rename), with a
# few server-state assertions for invariants the UI doesn't surface directly.
#
# Behaviour asserted (the user-facing contract that two bugs broke):
#
#   CLOSE (the ✕ on a sidebar "Open chats" entry)
#     * removes the chat from the homebar (it used to stay — a titled / session-
#       bound chat is persistently "open", so the ✕ visibly did nothing),
#     * returns the view to the dashboard, tears the ChatModel down, and
#     * persists the close (`dismissed`) so it survives a restart.
#     * closing ONE chat leaves the others untouched.
#
#   NAME persistence + consistency
#     * a fresh chat auto-titles from its first message, shown identically in the
#       homebar label AND the chat header,
#     * a header rename updates BOTH in lockstep and persists,
#     * the rename survives switching to another chat and back,
#     * a fresh chat records its bound claude session id (`resume_session_id`) —
#       the root fix for "the name reverts to the first message": without the
#       binding the same open chat showed under its title in the homebar but
#       under its first message in the folder→threads browser, and resuming it
#       there spawned a duplicate untitled project.
#     * reopening a closed chat restores it to the homebar UNDER ITS TITLE
#       (drive the same `ensure_project_session!` entrypoint the browser's
#       Resume button uses; the mock worker has no discoverable jsonl, so the
#       discover-menu round-trip itself isn't reproducible in the harness).
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
import BonitoAgents as BT

# ── UI helpers (scoped so multi-pane keep-alive doesn't read a stale pane) ──
sidebar_has(s, pid) = TK.eval_js(s, """(() => [...document.querySelectorAll('.bt-side-item')]
    .some(e => e.getAttribute('data-project-id') === $(repr(pid))))()""") === true

sidebar_label(s, pid) = TK.eval_js(s, """(() => {
    const e = [...document.querySelectorAll('.bt-side-item')]
        .find(x => x.getAttribute('data-project-id') === $(repr(pid)));
    const n = e && e.querySelector('.bt-side-name');
    return n ? n.innerText.trim() : null; })()""")

# Header title of the VISIBLE chat pane (`.bt-header-title` isn't pane-scoped by
# the harness shim, so resolve it within the on-screen pane ourselves).
header_title(s) = TK.eval_js(s, """(() => {
    const p = [...document.querySelectorAll('.bt-chatpane')].find(x => x.offsetParent !== null);
    const inp = p && p.querySelector('.bt-header-title-edit');
    return inp ? inp.value : null; })()""")

click_close(s, pid) = TK.eval_js(s, """(() => {
    const e = [...document.querySelectorAll('.bt-side-item')]
        .find(x => x.getAttribute('data-project-id') === $(repr(pid)));
    if (!e) return 'no-item';
    const x = e.querySelector('.bt-side-close');
    if (!x) return 'no-close';
    x.click(); return 'clicked'; })()""")

rename_header(s, newname) = TK.eval_js(s, """(() => {
    const p = [...document.querySelectorAll('.bt-chatpane')].find(x => x.offsetParent !== null);
    const inp = p && p.querySelector('.bt-header-title-edit');
    if (!inp) return 'no-input';
    inp.focus();
    const set = Object.getOwnPropertyDescriptor(inp.constructor.prototype, 'value').set;
    set.call(inp, $(repr(newname)));
    inp.dispatchEvent(new Event('change', {bubbles: true}));
    return 'ok'; })()""")

bound_sid(s, pid) = begin
    p = get(s.h.state.projects[], pid, nothing)
    p === nothing ? nothing : p.resume_session_id
end

function run_suite(server)
    server.agent_fn[] = (msg -> [TK.text("Echo: $msg")])

    @testset "close button + name persistence (UI)" begin
        # ── Header shows the WORKER project path, not the server mirror ──────
        # The folder line under the chat title must be the project's pwd on the
        # worker (`ProjectInfo.worker_path`, what the projects scan list shows) —
        # NOT `model.cwd` / `server_path`, the state-dir mirror that's meaningless
        # to the user.
        @testset "header folder line is the worker path" begin
            pid = TK.new_chat(server; title = "PathProbe")
            @test TK.wait_for(server, "header env present",
                "(() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); return !!(p && p.querySelector('.bt-header-env')); })()";
                timeout = 10) == true
            shown = TK.eval_js(server,
                "(() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); return p.querySelector('.bt-header-env').getAttribute('title'); })()")
            proj = server.h.state.projects[][pid]
            @test shown == proj.worker_path
            @test shown != proj.server_path
        end

        # ── Close removes the chat from the homebar ─────────────────────────
        @testset "✕ closes the chat: leaves the homebar, returns to dashboard" begin
            pid = TK.new_chat(server; title = "Closable")
            TK.send_message(server, "first message one")
            @test TK.wait_for(server, "chat listed in homebar",
                "[...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pid)))";
                timeout = 10) == true
            # Root fix for name-revert: a chat binds its claude session id (so it's
            # one tracked thread, not a duplicate in the threads browser). With lazy
            # ACP the bind happens ASYNC on the first message, so poll for it rather
            # than assert instantly (the eager path bound synchronously at open).
            @test let ok = false
                for _ in 1:80
                    bound_sid(server, pid) !== nothing && (ok = true; break)
                    sleep(0.1)
                end
                ok
            end

            @test click_close(server, pid) == "clicked"
            # The ✕ must actually remove the entry (the bug: it lingered).
            @test TK.wait_for(server, "chat left the homebar",
                "![...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pid)))";
                timeout = 10) == true
            @test TK.current_chat_id(server) == ""                  # back on dashboard
            @test server.h.state.projects[][pid].dismissed == true  # persisted closed
            # Teardown runs off the event task (`@async stop_session!`) so the UI
            # never froze — poll for the ChatModel to actually drop.
            torn_down = false
            for _ in 1:50
                haskey(server.h.state.chat_models, pid) || (torn_down = true; break)
                sleep(0.1)
            end
            @test torn_down                                         # session torn down
        end

        # ── ✕ placement: top-right corner, clear of the files hint ──────────
        @testset "✕ pins to the row's top-right; ▾ files owns the bottom-right" begin
            pid = TK.new_chat(server; title = "Placement")
            @test TK.wait_for(server, "chat row present",
                "[...document.querySelectorAll('.bt-side-chat-row')].some(r => r.querySelector('.bt-side-item')?.getAttribute('data-project-id') === $(repr(pid)))";
                timeout = 10) == true
            geo = TK.eval_js(server, """(() => {
                const row = [...document.querySelectorAll('.bt-side-chat-row')]
                    .find(r => r.querySelector('.bt-side-item')?.getAttribute('data-project-id') === $(repr(pid)));
                const it = row.querySelector('.bt-side-item');
                const x  = row.querySelector('.bt-side-close');
                const h  = row.querySelector('.bt-side-tree-hint');
                const ib = it.getBoundingClientRect(), xb = x.getBoundingClientRect();
                const hb = h ? h.getBoundingClientRect() : null;
                return { xTop: Math.round(xb.top - ib.top),
                         xRight: Math.round(ib.right - xb.right),
                         gap: hb ? Math.round(hb.top - xb.bottom) : null,
                         hidden: getComputedStyle(x).pointerEvents === 'none' }; })()""")
            @test geo["xTop"] <= 6              # top-anchored, not vertically centered
            @test geo["xRight"] <= 10           # right-anchored
            geo["gap"] === nothing || @test geo["gap"] >= 0   # never overlaps ▾ files
            # Hidden ✕ must not be an invisible click target (stray corner click
            # closing a chat) — pointer-events off until the row reveals it.
            @test geo["hidden"] == true
            @test click_close(server, pid) == "clicked"   # cleanup: close the probe chat
            @test TK.wait_for(server, "placement probe closed",
                "![...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pid)))";
                timeout = 10) == true
        end

        # ── Closing one chat leaves the others ──────────────────────────────
        @testset "closing one chat leaves the others" begin
            pidA = TK.new_chat(server; title = "Keep-A"); TK.send_message(server, "alpha msg")
            pidB = TK.new_chat(server; title = "Keep-B"); TK.send_message(server, "bravo msg")
            @test TK.wait_for(server, "both listed",
                "[...document.querySelectorAll('.bt-side-item')].filter(e => [$(repr(pidA)),$(repr(pidB))].includes(e.getAttribute('data-project-id'))).length === 2";
                timeout = 10) == true
            @test click_close(server, pidB) == "clicked"
            @test TK.wait_for(server, "B gone",
                "![...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pidB)))";
                timeout = 10) == true
            @test sidebar_has(server, pidA)                         # A survived
            @test server.h.state.projects[][pidB].dismissed == true
            @test server.h.state.projects[][pidA].dismissed == false
        end

        # ── Rename: homebar + header agree, and it persists ─────────────────
        @testset "rename is consistent across homebar + header and persists" begin
            pid = TK.new_chat(server; title = "Renamable")
            TK.send_message(server, "auto title here")
            # Auto-title from the first message, shown identically in both places.
            @test TK.wait_for(server, "auto-title in homebar",
                "(() => { const e=[...document.querySelectorAll('.bt-side-item')].find(x=>x.getAttribute('data-project-id')===$(repr(pid))); const n=e&&e.querySelector('.bt-side-name'); return !!n && n.innerText.trim()==='auto title here'; })()";
                timeout = 10) == true
            @test header_title(server) == "auto title here"

            @test rename_header(server, "Renamed Chat") == "ok"
            @test TK.wait_for(server, "homebar shows rename",
                "(() => { const e=[...document.querySelectorAll('.bt-side-item')].find(x=>x.getAttribute('data-project-id')===$(repr(pid))); const n=e&&e.querySelector('.bt-side-name'); return !!n && n.innerText.trim()==='Renamed Chat'; })()";
                timeout = 10) == true
            @test header_title(server) == "Renamed Chat"
            @test server.h.state.projects[][pid].title == "Renamed Chat"

            # Rename survives switching to another chat and back.
            TK.new_chat(server; title = "Other"); TK.send_message(server, "other msg")
            TK.open_chat(server, pid)
            @test TK.wait_for(server, "renamed header after switch-back",
                "(() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const inp=p&&p.querySelector('.bt-header-title-edit'); return !!inp && inp.value==='Renamed Chat'; })()";
                timeout = 10) == true
            @test sidebar_label(server, pid) == "Renamed Chat"
        end

        # ── Reopen after close restores the entry UNDER ITS TITLE ───────────
        @testset "reopen after close restores the chat with its title" begin
            pid = TK.new_chat(server; title = "Reopenable")
            TK.send_message(server, "the seed message")
            @test rename_header(server, "Pinned Title") == "ok"
            @test TK.wait_for(server, "renamed",
                "(() => { const e=[...document.querySelectorAll('.bt-side-item')].find(x=>x.getAttribute('data-project-id')===$(repr(pid))); const n=e&&e.querySelector('.bt-side-name'); return !!n && n.innerText.trim()==='Pinned Title'; })()";
                timeout = 10) == true

            @test click_close(server, pid) == "clicked"
            @test TK.wait_for(server, "closed → gone",
                "![...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pid)))";
                timeout = 10) == true
            @test server.h.state.projects[][pid].dismissed == true

            # Reopen via the same bring-up entrypoint the discover-menu Resume
            # button calls. Clears `dismissed` and re-registers the model.
            BT.ensure_project_session!(server.h.state, server.h.state.projects[][pid])
            @test TK.wait_for(server, "reopened → back in homebar",
                "[...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pid)))";
                timeout = 15) == true
            @test server.h.state.projects[][pid].dismissed == false
            @test server.h.state.projects[][pid].title == "Pinned Title"   # title preserved
            @test sidebar_label(server, pid) == "Pinned Title"
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server()
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
