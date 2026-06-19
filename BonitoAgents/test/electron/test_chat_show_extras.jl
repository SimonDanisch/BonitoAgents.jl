# bt_show paths not covered by test_chat_show.jl, migrated onto the TestKit
# harness (real dev_server, real worker subprocess, real ACP wire, real Electron
# browser; only the agent's behaviour is faked, via the `agent=` callback).
#
#   - video/mp4 → <video> element with a served Bonito.Asset src (range-capable,
#     NOT a data: blob — so the browser can stream/seek and no bytes hit claude)
#   - text/html → currently NOT specially rendered (intentional; see chat.jl).
#     Falls through to the generic "binary" branch (no iframe, no inline HTML).
#   - File referenced but missing on disk (worker-fetch path): the synchronous
#     fetch can't supply it, so Bonito's render-error boundary contains the
#     failure and shows an error placeholder in the tool body — no inline file,
#     no chat crash.
#
# As in the committed test_chat_show.jl, the `shown:` markers resolve against the
# chat's SERVER-SIDE cwd (`model.cwd`); we pre-write the video + html files there
# (exactly as the real bt_show tool would have left them) so they render
# synchronously. The third file is intentionally NOT written, so its render takes
# the worker-fetch branch, which fails and surfaces the contained error placeholder.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, tool, text_block, end_turn

# Tiny "video" — not a real mp4. render_show_file picks the <video> element by
# extension and points <source src> at a served Asset; the element + served URL
# are what we verify, not playback.
const VIDEO_BODY = "FAKE_VIDEO_BYTES_FOR_TESTING_ONLY"
# HTML present so we can prove text/html falls through to the generic placeholder.
const HTML_BODY  = "<!doctype html><title>html present</title><h1>should NOT render inline</h1>"

@testset "bt_show extras — video/mp4, text/html fallthrough, missing-file error" begin
    s = TK.dev_server(; agent = msg -> [
        text("Showing the files."),
        tool(; id = "video-1", kind = "other", title = "bt_show clip.mp4",
               status = "completed",
               content = [text_block("shown: show/clip.mp4 (video/mp4, $(length(codeunits(VIDEO_BODY))) bytes)")]),
        tool(; id = "html-1", kind = "other", title = "bt_show page.html",
               status = "completed",
               content = [text_block("shown: show/page.html (text/html, $(length(codeunits(HTML_BODY))) bytes)")]),
        tool(; id = "missing-1", kind = "other", title = "bt_show absent.png",
               status = "completed",
               content = [text_block("shown: show/absent.png (image/png, 1234 bytes)")]),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        # Pre-write the video + html into the chat's SERVER-SIDE cwd (the dir
        # `shown: <relpath>` resolves against in show_server_path). absent.png is
        # deliberately NOT written, so it takes the worker-fetch (error) branch.
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        showdir = joinpath(model.cwd, "show")
        mkpath(showdir)
        write(joinpath(showdir, "clip.mp4"),  VIDEO_BODY)
        write(joinpath(showdir, "page.html"), HTML_BODY)

        TK.send_message(s, "go")

        # All three tool bubbles arrive.
        @test TK.wait_for(s, "three tool bubbles arrive",
            "document.querySelectorAll('.bt-tool-msg').length >= 3"; timeout = 30) == true

        # ── video/mp4 preview → <video> element ──────────────────────────────
        # NO click: bt_show results auto-expand; a header click would TOGGLE shut.
        @test TK.wait_for(s, "video element appears in body", """
            (() => { const slot = document.querySelector('.bt-tool-body[data-tool-id="video-1"]');
                     return slot && slot.querySelector('video') !== null; })()
        """; timeout = 20) == true
        # The <source> src points at a served Bonito.Asset (range-capable), a
        # /assets/<key> URL, NOT a data: blob.
        src_val = TK.eval_js(s, """
            (() => { const slot = document.querySelector('.bt-tool-body[data-tool-id="video-1"]');
                     const src = slot ? slot.querySelector('video source') : null;
                     return src ? src.getAttribute('src') : null; })()
        """)
        @test src_val isa AbstractString
        @test !startswith(src_val, "data:")
        @test occursin("/assets/", src_val)

        # ── text/html falls through — no iframe, no inline render ─────────────
        # Wait for the body to render something (loading spinner gone).
        @test TK.wait_for(s, "html body rendered (spinner gone)", """
            (() => { const slot = document.querySelector('.bt-tool-body[data-tool-id="html-1"]');
                     return slot && (slot.innerText || '').length > 0
                         && (slot.innerText || '').indexOf('loading') === -1; })()
        """; timeout = 20) == true
        # No iframe — the explicit decision today.
        @test Int(TK.eval_js(s,
            "document.querySelectorAll('.bt-tool-body[data-tool-id=\"html-1\"] iframe').length")) == 0
        # The H1 from the file is NOT live in the chat DOM (generic placeholder only).
        @test TK.eval_js(s, """
            (() => { const slot = document.querySelector('.bt-tool-body[data-tool-id="html-1"]');
                     return slot && slot.querySelector('h1') !== null; })()
        """) == false

        # ── missing-file → contained error placeholder, NOT a crash ──────────
        # The file isn't on the server mirror, so render takes the worker-fetch
        # branch. With a live worker that can't supply the file the synchronous
        # fetch throws (EOFError on the transfer); Bonito's render-error boundary
        # contains it and renders an error placeholder INTO the tool body (no
        # inline file, no chat crash). With an offline worker the same body shows
        # a "not connected"/"failed to fetch"/"file not on server" message. Accept
        # any of those — the contract is "a contained error placeholder appears".
        @test TK.wait_for(s, "error placeholder appears for the unfetchable file", """
            (() => { const slot = document.querySelector('.bt-tool-body[data-tool-id="missing-1"]');
                     if (!slot) return false;
                     const t = slot.innerText || '';
                     return t.indexOf('failed to fetch') !== -1
                         || t.indexOf('file not on server') !== -1
                         || t.indexOf('not connected') !== -1
                         || t.indexOf('EOFError') !== -1
                         || t.indexOf('Error') !== -1; })()
        """; timeout = 25) == true
        # The unfetchable image is NOT rendered inline — no <img> leaked into the
        # body despite the image/png mime.
        @test TK.eval_js(s,
            "document.querySelector('.bt-tool-body[data-tool-id=\"missing-1\"] img') !== null") == false
        # The error is contained: the chat is still alive (composer present).
        @test TK.eval_js(s, "document.querySelector('.bt-text-input') !== null") == true

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-show-extras-final.png"))

        # No JS errors across the run.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
