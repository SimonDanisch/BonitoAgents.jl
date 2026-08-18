# Black-box e2e for the bt_show file-preview cases NOT covered by media_test.jl
# (image + video happy path live there). Here we drive the DOM for:
#
#   • text/html → `file_kind` says HTMLFile, so the preview is the RENDERED page
#     in a `<iframe class="bt-fv-frame">` pointed at the streamed asset url —
#     what the bt_show tool description has always promised ("text/html →
#     sandboxed iframe") and what makes an agent-generated report actually
#     readable in the chat. The frame carries `sandbox="allow-scripts"` and
#     NOTHING else: no `allow-same-origin`, so the page runs in an opaque origin
#     and cannot reach the dashboard's DOM, storage or session; no
#     `allow-top-navigation`, so it cannot navigate the window away. Both of
#     those are asserted below — they are the security contract, not decoration.
#
#   • missing file → a `shown: /tmp/does-not-exist.png (image/png, 0B)` whose file
#     is on neither the server nor the worker disk. The body must render WITHOUT
#     crashing the chat and WITHOUT a fatal JS error: render_show_file takes the
#     image branch (.png), show_media_src asks the live worker bridge for an
#     `/assets/<key>` url (which it hands out without an isfile check — the 404
#     only surfaces when the browser range-fetches the bytes, and a broken <img>
#     load does NOT fire window.onerror), so an <img class=bt-media> renders with
#     a dead src. If instead the fetch path throws, the ToolRenderCommand handler
#     catches it and mounts `<div class="bt-tool-error">tool body unavailable…`.
#     Either outcome is graceful; the assertion is "the slot renders something and
#     window.__errs stays empty".
#
#   • csv + obj → the rich kinds rendered INLINE. Same renderers the workspace
#     file tab uses, but reaching the DOM by a different route (`dom_in_js` into
#     a tool slot), and their behaviour comes from the window-level file-view
#     driver rather than from the node itself — so these assert that the driver
#     adopts chat bubbles too, by exercising the behaviour (a sort click, the
#     mesh viewer's own report of the geometry it decoded), not just the markup.
#
# dev_server is local, so the worker reads the same /tmp we write here (the html
# file lands on disk for the worker to fetch + the server to render).
@testitem "e2e:chat_show_extras" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    html_path    = "/tmp/bt_e2e_show_extras_$(getpid()).html"
    missing_path = "/tmp/bt_e2e_show_extras_missing_$(getpid()).png"
    csv_path     = "/tmp/bt_e2e_show_extras_$(getpid()).csv"
    obj_path     = "/tmp/bt_e2e_show_extras_$(getpid()).obj"
    write(html_path,
        "<!doctype html><title>html preview</title><h1>bt_show html source</h1>")
    write(csv_path, "name,score\nada,42\ngrace,7\n")
    write(obj_path, "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
    rm(missing_path; force = true)   # make sure it really is absent
    html_bytes = filesize(html_path)

    s.agent_fn[] = _ -> [
        TK.text("here are the extras"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "page.html",
                  content = [TK.text_block("shown: $(html_path) (text/html, $(html_bytes)B)")],
                  id = "html1"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "absent.png",
                  content = [TK.text_block("shown: $(missing_path) (image/png, 0B)")],
                  id = "missing1"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "data.csv",
                  content = [TK.text_block("shown: $(csv_path) (text/csv, $(filesize(csv_path)))")],
                  id = "csv1"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "square.obj",
                  content = [TK.text_block("shown: $(obj_path) (model/obj, $(filesize(obj_path)))")],
                  id = "obj1"),
        TK.end_turn(),
    ]

    pid = TK.new_chat(s)
    TK.send_message(s, "show me the extras")

    @test TK.wait_for(s, "all bt_show tools completed",
        "[...document.querySelectorAll('.bt-tool-msg .bt-tool-status')].filter(e=>e.textContent==='completed').length >= 4";
        timeout = 60)

    # bt_show references auto-expand the pill (has_show_reference → expand=true),
    # so the bodies render without a click. Click any still-collapsed headers as a
    # belt-and-braces guard (idempotent: re-clicking an open one would toggle it
    # shut, so only click the ones whose body slot is still empty).
    TK.eval_js(s, """
        [...document.querySelectorAll('.bt-tool-msg')].forEach(m => {
            const body = m.querySelector('.bt-tool-body');
            const h = m.querySelector('.bt-tool-header');
            if (h && body && (body.innerText||'').trim() === '') h.click();
        }); true""")

    # ── text/html → the rendered page in a sandboxed iframe ──────────────────
    @test TK.wait_for(s, "html renders in a frame",
        "!!document.querySelector('.bt-tool-body[data-tool-id=\"html1\"] iframe.bt-fv-frame')";
        timeout = 30)

    # The sandbox is the contract: scripts may run, but the frame gets an OPAQUE
    # origin (no allow-same-origin) so the page cannot touch the dashboard, and
    # it cannot navigate the top-level window (no allow-top-navigation).
    @test TK.eval_js(s, """(() => {
        const f = document.querySelector('.bt-tool-body[data-tool-id="html1"] iframe.bt-fv-frame');
        if (!f) return false;
        const tokens = [...f.sandbox];
        return tokens.length === 1 && tokens[0] === 'allow-scripts';
    })()""") === true

    # It really points at the streamed asset, not an inlined srcdoc/data: blob.
    @test TK.eval_js(s, """(() => {
        const f = document.querySelector('.bt-tool-body[data-tool-id="html1"] iframe.bt-fv-frame');
        const src = f && (f.getAttribute('src') || '');
        return !!src && src.startsWith('/assets/') && !f.hasAttribute('srcdoc');
    })()""") === true

    # ── the rich kinds render INLINE too, with working behaviour ─────────────
    # Same renderers as the workspace tab, but delivered into a chat bubble by a
    # completely different path (`dom_in_js` into a tool slot). Their JS comes
    # from the window-level driver, so this is the assertion that the driver
    # reaches chat bubbles and not just panels.
    @test TK.wait_for(s, "a csv shows as a table in the bubble",
        """(() => {
            const t = document.querySelector('.bt-tool-body[data-tool-id="csv1"] table.bt-fv-table');
            return !!t && t.tBodies[0].rows.length === 2
                && t.tBodies[0].rows[0].cells[1].textContent === 'ada';
        })()"""; timeout = 30)
    # Click-to-sort proves the driver adopted THIS node, not just that the
    # markup rendered.
    TK.eval_js(s, """(() => {
        const t = document.querySelector('.bt-tool-body[data-tool-id="csv1"] table.bt-fv-table');
        t.tHead.rows[0].cells[2].click(); return true; })()""")
    @test TK.wait_for(s, "the inline table sorts",
        """(() => {
            const b = document.querySelector('.bt-tool-body[data-tool-id="csv1"] table.bt-fv-table').tBodies[0];
            return [...b.rows].map(r => r.cells[2].textContent).join(',') === '7,42';
        })()"""; timeout = 15)

    @test TK.wait_for(s, "geometry shows in the 3D viewer in the bubble",
        """(() => {
            const st = document.querySelector('.bt-tool-body[data-tool-id="obj1"] .bt-mesh-status');
            return !!st && st.textContent.includes('2 triangles');
        })()"""; timeout = 40)

    # ── missing file → graceful (some body, no crash) ────────────────────────
    # Either an <img>/media-wrap with a dead /assets/ src (live-bridge fast path)
    # or the .bt-tool-error placeholder (fetch path threw, handler caught it).
    @test TK.wait_for(s, "missing-file body renders gracefully",
        """(() => {
            const slot = document.querySelector('.bt-tool-body[data-tool-id="missing1"]');
            if (!slot) return false;
            return slot.querySelector('.bt-media-wrap') !== null
                || slot.querySelector('img') !== null
                || slot.querySelector('.bt-tool-error') !== null;
        })()""";
        timeout = 30)

    # The whole point: the missing file must NOT take the chat down — the rest of
    # the UI is still live (composer present, the html tool still rendered).
    @test TK.eval_js(s, "!!document.querySelector('.bt-text-input')") === true

    @test isempty(TK.js_errors(s))

    rm(html_path; force = true)
    rm(missing_path; force = true)
    rm(csv_path; force = true)
    rm(obj_path; force = true)
end
