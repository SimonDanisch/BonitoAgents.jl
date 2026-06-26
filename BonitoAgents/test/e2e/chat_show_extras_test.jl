# Black-box e2e for the bt_show file-preview cases NOT covered by media_test.jl
# (image + video happy path live there). Here we drive the DOM for:
#
#   • text/html → render_show_file falls through the media branches (.html is
#     neither an image nor a video ext), `editor_openable(".html")` is true, and
#     the file is non-binary → it renders through `monaco_readonly` as a Monaco
#     editor. The server-side mount is a `<div class="monaco-editor-div
#     language-html">` (BonitoBook.MonacoEditor.jsrender). It is NOT an iframe and
#     NOT a `.bt-media-wrap` — that's the deliberate behavior: html is shown as
#     read-only SOURCE, never executed/sandboxed inline (see chat.jl
#     render_show_file + editor_openable).
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
# dev_server is local, so the worker reads the same /tmp we write here (the html
# file lands on disk for the worker to fetch + the server to Monaco-render).
@testitem "e2e:chat_show_extras" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    html_path    = "/tmp/bt_e2e_show_extras_$(getpid()).html"
    missing_path = "/tmp/bt_e2e_show_extras_missing_$(getpid()).png"
    write(html_path,
        "<!doctype html><title>html preview</title><h1>bt_show html source</h1>")
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
        TK.end_turn(),
    ]

    pid = TK.new_chat(s)
    TK.send_message(s, "show me the extras")

    @test TK.wait_for(s, "both bt_show tools completed",
        "[...document.querySelectorAll('.bt-tool-msg .bt-tool-status')].filter(e=>e.textContent==='completed').length >= 2";
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

    # ── text/html → Monaco read-only source, NOT an iframe, NOT media ────────
    @test TK.wait_for(s, "html renders as a Monaco source editor",
        "!!document.querySelector('.bt-tool-body[data-tool-id=\"html1\"] .monaco-editor-div')";
        timeout = 30)

    # The html preview is SOURCE, never an executed/sandboxed iframe and never the
    # media-wrap path: no <iframe>, no .bt-media-wrap, and the file's <h1> is not
    # live in the chat DOM.
    @test TK.eval_js(s, """(() => {
        const slot = document.querySelector('.bt-tool-body[data-tool-id="html1"]');
        if (!slot) return false;
        return slot.querySelector('iframe') === null
            && slot.querySelector('.bt-media-wrap') === null
            && slot.querySelector('h1') === null;
    })()""") === true

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
end
