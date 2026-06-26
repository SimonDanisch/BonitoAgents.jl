# Black-box e2e for the bt_show preview cases NOT covered by media_test.jl
# (image + video happy path) or chat_show_extras_test.jl (html + missing file).
# Here we drive the DOM for the two remaining contracts from render_show_file:
#
#   • text/plain → render_show_file falls through the media branches (.txt is
#     neither a SHOW_IMAGE_EXTS nor a SHOW_VIDEO_MIME ext), `editor_openable`
#     is true and the bytes are non-binary → it renders through `monaco_readonly`
#     as a read-only Monaco editor. The server-side mount is BonitoBook's
#     `<div class="monaco-editor-div ...">` (MonacoEditor.jsrender). That is the
#     deterministic integration boundary; `.monaco-editor` is the inner Monaco
#     runtime element that mounts asynchronously on top of it.
#
#   • image/png served-asset URL → render_show_file takes the image branch and
#     `show_media_src` resolves to a streamed worker-asset / `Bonito.Asset` url.
#     The <img class=bt-media> src must start with `/assets/` (a served, range-
#     capable Bonito.Asset), NEVER a multi-MB `data:` base64 blob.
#
# dev_server is local, so the worker reads the same /tmp we write here.
@testitem "e2e:chat_show" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    txt_path = "/tmp/bt_e2e_chat_show_$(getpid()).txt"
    png_path = "/tmp/bt_e2e_chat_show_$(getpid()).png"
    txt_content = "Hello from bt_show preview test\nLine two\nLine three"
    write(txt_path, txt_content)
    # A non-trivial PNG payload: the whole point is that this rides as a served
    # /assets/ url, not an inlined base64 data: blob.
    write(png_path, UInt8.((0:4999) .% 256))
    txt_bytes = filesize(txt_path)

    s.agent_fn[] = _ -> [
        TK.text("here are the previews"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "notes.txt",
                  content = [TK.text_block("shown: $(txt_path) (text/plain, $(txt_bytes)B)")],
                  id = "txt1"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "image.png",
                  content = [TK.text_block("shown: $(png_path) (image/png, 5000B)")],
                  id = "img1"),
        TK.end_turn(),
    ]

    pid = TK.new_chat(s)
    TK.send_message(s, "show me the previews")

    @test TK.wait_for(s, "both bt_show tools completed",
        "[...document.querySelectorAll('.bt-tool-msg .bt-tool-status')].filter(e=>e.textContent==='completed').length >= 2";
        timeout = 60)

    # bt_show references auto-expand the pill (has_show_reference → expand=true),
    # so the bodies render without a click. Click any still-collapsed headers as a
    # belt-and-braces guard (idempotent: only click headers whose body is empty so
    # we never toggle an already-open body shut).
    TK.eval_js(s, """
        [...document.querySelectorAll('.bt-tool-msg')].forEach(m => {
            const body = m.querySelector('.bt-tool-body');
            const h = m.querySelector('.bt-tool-header');
            if (h && body && (body.innerText||'').trim() === '') h.click();
        }); true""")

    # ── text/plain → read-only Monaco source editor ──────────────────────────
    # monaco_readonly → BonitoBook.MonacoEditor, whose server-side mount is the
    # `.monaco-editor-div` (same deterministic selector chat_show_extras uses).
    @test TK.wait_for(s, "text renders as a Monaco read-only editor",
        "!!document.querySelector('.bt-tool-body[data-tool-id=\"txt1\"] .monaco-editor-div')";
        timeout = 30)

    # The text preview is a source editor, NOT a media-wrap and NOT an iframe.
    @test TK.eval_js(s, """(() => {
        const slot = document.querySelector('.bt-tool-body[data-tool-id="txt1"]');
        if (!slot) return false;
        return slot.querySelector('.bt-media-wrap') === null
            && slot.querySelector('iframe') === null;
    })()""") === true

    # The Monaco runtime mounts on top of the div and pulls in the file content;
    # once it lays out, the editor has real height (BonitoBook owns the actual
    # text-render path; the integration boundary that matters here is "the right
    # slot mounted a non-empty editor").
    @test TK.wait_for(s, "Monaco editor body has laid out",
        """(() => {
            const div = document.querySelector('.bt-tool-body[data-tool-id="txt1"] .monaco-editor-div');
            return !!div && div.getBoundingClientRect().height > 10;
        })()""";
        timeout = 15)

    # ── image/png → served /assets/ url, NOT a data: base64 blob ─────────────
    @test TK.wait_for(s, "image renders as a streamed asset",
        "(() => { const i = document.querySelector('.bt-tool-body[data-tool-id=\"img1\"] .bt-media-wrap img.bt-media'); " *
        "return !!i && (i.getAttribute('src')||'').startsWith('/assets/'); })()";
        timeout = 30)

    # Explicitly assert the negative: the src is NEVER a data: base64 blob.
    @test TK.eval_js(s, """(() => {
        const i = document.querySelector('.bt-tool-body[data-tool-id="img1"] .bt-media-wrap img.bt-media');
        if (!i) return false;
        const src = i.getAttribute('src') || '';
        return src.startsWith('/assets/') && !src.startsWith('data:');
    })()""") === true

    @test isempty(TK.js_errors(s))

    rm(txt_path; force = true)
    rm(png_path; force = true)
end
