# bt_show paths not covered by test_chat_show.jl:
#   - video/mp4 → <video> element with a served Bonito.Asset src (range-capable,
#     NOT a data: blob — so the browser can stream/seek and no bytes hit claude)
#   - text/html → currently NOT specially rendered (intentional; see chat.jl).
#     Falls through to the generic "binary" branch.
#   - File present locally but missing on disk (worker-fetch path): spinner
#     appears, then a clean error placeholder when the worker isn't reachable.
#
# This file also covers a real bug fixed alongside it: the worker-fetch
# branch in render_show_reference used to shadow the `state` parameter
# with an Observable, then call fetch_file_from_worker(state, ...) — a
# crash if you ever exercised that path.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]

mkpath(joinpath(proj.server_path, "show"))

# Tiny "video" — not a real mp4. render_show_file picks the <video> element by
# extension and points <source src> at a served Asset; the element + served URL
# are what we're verifying, not playback.
video_path = joinpath(proj.server_path, "show", "clip.mp4")
write(video_path, codeunits("FAKE_VIDEO_BYTES_FOR_TESTING_ONLY"))
const VIDEO_BYTES = filesize(video_path)

# HTML file present so we can prove text/html falls through to the generic
# "binary" placeholder rather than rendering inline.
html_path = joinpath(proj.server_path, "show", "page.html")
write(html_path, "<!doctype html><title>html present</title><h1>should NOT render inline</h1>")
const HTML_BYTES = filesize(html_path)

# Third tool references a file that is NOT on the server. The
# render_show_reference handler will look up the worker (w-1, status
# :offline because no real WS) and try to fetch via /transfer-ws — which
# will fail. We expect the error placeholder.
scripted = [
    (0.05, TH.tool_call_update(
        id="video-1", kind="other", title="bt_show clip.mp4",
        status="completed",
        content=[TH.tool_text("shown: show/clip.mp4 (video/mp4, $VIDEO_BYTES bytes)")])),
    (0.05, TH.tool_call_update(
        id="html-1", kind="other", title="bt_show page.html",
        status="completed",
        content=[TH.tool_text("shown: show/page.html (text/html, $HTML_BYTES bytes)")])),
    (0.05, TH.tool_call_update(
        id="missing-1", kind="other", title="bt_show absent.png",
        status="completed",
        content=[TH.tool_text("shown: show/absent.png (image/png, 1234 bytes)")])),
]

let
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport = TH.mock_transport(; scripted))
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "no chat"

    TH.section("Trigger the script") do
        TH.type_into(ctx, ".bt-text-input", "go")
        TH.dom_click(ctx, ".bt-send-btn")
        record("three tool bubbles arrive",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-tool-msg').length >= 3"; timeout = 5.0))
    end

    TH.section("video/mp4 preview → <video> element") do
        # NO click: bt_show results auto-expand (the completion update ships
        # `expand`), so a manual header click would TOGGLE the open body shut.
        record("video element appears in the body",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="video-1"]');
                       return slot && slot.querySelector('video') !== null;
                   })()
               """; timeout = 5.0))
        # The <source> src points at a served Bonito.Asset (range-capable) so the
        # browser can stream/seek the video — a /assets/<key> URL, not a data: blob.
        src_val = TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="video-1"]');
                const src = slot ? slot.querySelector('video source') : null;
                return src ? src.getAttribute('src') : null;
            })()
        """)
        record("video source src is a served /assets/ URL (not a data: blob)",
               @TH.test_true (src_val isa AbstractString
                              && !startswith(src_val, "data:")
                              && occursin("/assets/", src_val)))
    end

    TH.section("text/html falls through — no iframe, no inline render") do
        # NO click: bt_show results auto-expand (the completion update ships
        # `expand`), so a manual header click would TOGGLE the open body shut.
        # Wait for the body to render *something* (loading spinner gone).
        @assert TH.wait_for(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="html-1"]');
                return slot && (slot.innerText || '').length > 0
                    && (slot.innerText || '').indexOf('loading') === -1;
            })()
        """; timeout = 5.0)
        # No iframe — that's the explicit decision today.
        n_iframes = TH.eval_js(ctx, """
            document.querySelectorAll('.bt-tool-body[data-tool-id="html-1"] iframe').length
        """)
        record("no iframe in the html body", @TH.test_eq Int(n_iframes) 0)
        # And the H1 from the file is NOT live in the chat DOM (we only
        # show the generic placeholder + caption, not the rendered HTML).
        rendered_inline = TH.eval_js(ctx, """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="html-1"]');
                return slot && slot.querySelector('h1') !== null;
            })()
        """)
        record("HTML content is NOT rendered live in the chat DOM",
               @TH.test_true !rendered_inline)
    end

    TH.section("Missing-file → spinner then clean error placeholder") do
        # NO click: bt_show results auto-expand (the completion update ships
        # `expand`), so a manual header click would TOGGLE the open body shut.
        # Spinner (Bonito RippleSpinner → .lds-ripple) shows while the @async
        # fetch is in flight; if the fetch fails fast, the error placeholder is
        # already there instead — either proves the async render path ran.
        record("spinner (or error) appears for the async fetch",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="missing-1"]');
                       if (!slot) return false;
                       const t = slot.innerText || '';
                       return slot.querySelector('.lds-ripple') !== null
                           || t.indexOf('failed to fetch') !== -1
                           || t.indexOf('file not on server') !== -1
                           || t.indexOf('not connected') !== -1
                           || t.indexOf('Error') !== -1;
                   })()
               """; timeout = 5.0))
        # Eventually the @async errors out (no worker connected) and the
        # error placeholder takes over. The body text contains 'failed to
        # fetch' or '(file not on server'.
        record("error placeholder eventually replaces spinner",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const slot = document.querySelector('.bt-tool-body[data-tool-id="missing-1"]');
                       if (!slot) return false;
                       const t = slot.innerText || '';
                       return t.indexOf('failed to fetch') !== -1
                           || t.indexOf('file not on server') !== -1
                           || t.indexOf('not connected') !== -1;
                   })()
               """; timeout = 10.0))
    end

    TH.section("No JS errors") do
        record("zero JS errors", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "bt_show extras — final")

finally
    TH.report!("bt_show extras", results)
    TH.shutdown(ctx)
end
