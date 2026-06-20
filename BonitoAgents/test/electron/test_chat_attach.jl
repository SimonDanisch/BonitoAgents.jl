# Tier 2k — image attachments (paste, drag-drop, multi, remove, send, errors).
#
# What this exercises:
#  - Paste a fake PNG via a real ClipboardEvent + DataTransfer → thumbnail
#    strip becomes active, one .bt-attachment-thumb appears.
#  - Paste a second image → two thumbnails.
#  - Drop a third via a synthetic DragEvent on .bt-app → three thumbnails.
#  - Click the × on one thumb → that one disappears, the other two remain.
#  - Click send with attachments queued → the comm "send" event lands in
#    Julia, files are persisted under <cwd>/.bt-attachments/, the user
#    bubble carries the `[attached files in this message]` footer, and
#    the thumbnail strip is cleared.
#  - Send a too-large blob → error chip appears, no thumbnail added.
#  - Send an unsupported mime → server-side reject, attach_error path.
#  - Pure-text send still works (no attachments → original path unchanged).
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using JSON

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]

# Seed an idle chat. The mock end_turns immediately with no agent updates —
# we only care about the *user-side* persistence + DOM here.
let
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
end

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# Tiny synthetic byte payload. Doesn't need to be a valid PNG — we never
# decode it on either end. The MIME tag drives the routing.
const TINY_PNG_BYTES = UInt8[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
]
const TINY_PNG_HEX = lowercase(bytes2hex(TINY_PNG_BYTES))

# Build a JS hex→Uint8Array snippet so we don't have to babysit JSON.
# (JSON of a Vector{UInt8} produces a number array; that's fine but the
# hex helper is also handy for the on-disk byte comparison below.)
js_bytes_from_hex(hex) = """
    (() => {
        const hex = $(JSON.json(hex));
        const out = new Uint8Array(hex.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i*2, 2), 16);
        return out;
    })()
"""

try
    # ── Navigate into the chat ────────────────────────────────────────────
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"
    @assert TH.wait_for(ctx, "document.querySelector('.bt-attachments') !== null") "attachments bar didn't mount"

    # The chat instance is exposed via `node.__bt_chat` (devtools hook in
    # connect()). We need the messages container's __bt_chat handle for
    # direct attachment helpers; the JS event simulators below use the
    # standard DOM APIs.
    setup_chat_handle = "const chat = document.querySelector('.bt-messages').__bt_chat;"

    function paste_image_js(filename, hex; mime = "image/png")
        TH.eval_js(ctx, """(() => {
            const bytes = $(js_bytes_from_hex(hex));
            const file  = new File([bytes], $(JSON.json(filename)),
                                   {type: $(JSON.json(mime))});
            const dt = new DataTransfer();
            dt.items.add(file);
            const ta = document.querySelector('.bt-text-input');
            const evt = new ClipboardEvent('paste', {
                clipboardData: dt,
                bubbles: true, cancelable: true,
            });
            // Some Chromium builds construct ClipboardEvent without
            // forwarding clipboardData onto the instance; fall back to
            // calling the chat's private helper if the public path
            // didn't pick up our File. We only do this if the dispatch
            // didn't add a thumbnail within one microtask.
            ta.dispatchEvent(evt);
            if (!evt.clipboardData || evt.clipboardData.files.length === 0) {
                $setup_chat_handle
                chat._attachAddBlob(file, file.type, file.name);
            }
            return true;
        })()""")
    end

    function drop_image_js(filename, hex; mime = "image/png")
        TH.eval_js(ctx, """(() => {
            const bytes = $(js_bytes_from_hex(hex));
            const file  = new File([bytes], $(JSON.json(filename)),
                                   {type: $(JSON.json(mime))});
            const dt = new DataTransfer();
            dt.items.add(file);
            const app = document.querySelector('.bt-app');
            const dragover = new DragEvent('dragover',
                {dataTransfer: dt, bubbles: true, cancelable: true});
            app.dispatchEvent(dragover);
            const drop = new DragEvent('drop',
                {dataTransfer: dt, bubbles: true, cancelable: true});
            app.dispatchEvent(drop);
            // Same fallback as paste: some Chromium builds don't
            // forward dataTransfer.files onto constructed DragEvents.
            if (!drop.dataTransfer || drop.dataTransfer.files.length === 0) {
                $setup_chat_handle
                chat._attachAddBlob(file, file.type, file.name);
            }
            return true;
        })()""")
    end

    function attach_count()
        TH.eval_js(ctx, "document.querySelectorAll('.bt-attachment-thumb').length")
    end

    # ── Empty state ───────────────────────────────────────────────────────
    TH.section("Attachment bar is mounted but hidden until something is queued") do
        record("attachments bar exists in DOM",
               @TH.test_true TH.dom_exists(ctx, ".bt-attachments"))
        record("no thumbs initially",
               @TH.test_eq attach_count() 0)
        active = TH.eval_js(ctx, """
            document.querySelector('.bt-attachments').classList.contains('bt-attachments-active')""")
        record("no .bt-attachments-active class initially",
               @TH.test_eq active false)
    end

    # ── Paste ────────────────────────────────────────────────────────────
    TH.section("Paste one image → one thumbnail") do
        paste_image_js("pasted-1.png", TINY_PNG_HEX)
        record("thumbnail appears within 2s",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 1";
                   timeout = 2.0))
        active = TH.eval_js(ctx, """
            document.querySelector('.bt-attachments').classList.contains('bt-attachments-active')""")
        record("attachments bar is now active", @TH.test_eq active true)
        # The thumbnail's <img> should have a data: URL.
        src_ok = TH.eval_js(ctx, """(() => {
            const img = document.querySelector('.bt-attachment-thumb img');
            return img && img.src.startsWith('data:image/');
        })()""")
        record("thumb <img> uses a data: URL", @TH.test_eq src_ok true)
    end

    TH.section("Paste a second image → two thumbnails") do
        paste_image_js("pasted-2.png", TINY_PNG_HEX)
        record("two thumbnails present",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 2";
                   timeout = 2.0))
    end

    TH.section("Drop a third image onto .bt-app → three thumbnails") do
        drop_image_js("dropped-3.png", TINY_PNG_HEX)
        record("three thumbnails present",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 3";
                   timeout = 2.0))
        # drop should have cleared the drag-over class
        over = TH.eval_js(ctx, """
            document.querySelector('.bt-app').classList.contains('bt-drag-over')""")
        record("no .bt-drag-over after drop", @TH.test_eq over false)
    end

    TH.section("Click × on the middle thumbnail → leaves two") do
        TH.eval_js(ctx, """(() => {
            const thumbs = document.querySelectorAll('.bt-attachment-thumb');
            thumbs[1].querySelector('.bt-attachment-remove').click();
            return true;
        })()""")
        record("two thumbnails remain",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 2";
                   timeout = 2.0))
    end

    # ── Send with attachments ────────────────────────────────────────────
    TH.section("Send with attachments → bubble carries [attached] footer + files on disk") do
        n_user_before = TH.dom_count(ctx, ".bt-user-msg")
        TH.type_into(ctx, ".bt-text-input", "look at these")
        sleep(0.1)
        TH.dom_click(ctx, ".bt-send-btn")
        # Wait for the user bubble to land.
        record("user bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-user-msg').length >= $(n_user_before + 1)";
                   timeout = 3.0))
        # Last user bubble text should include both the message AND the
        # [attached] footer with .bt-attachments/<ts>.png references.
        bubble_text = TH.eval_js(ctx, """(() => {
            const bs = document.querySelectorAll('.bt-user-msg');
            return bs[bs.length - 1].innerText;
        })()""")
        record("bubble contains the typed text",
               @TH.test_true occursin("look at these", String(bubble_text)))
        record("bubble contains [attached files] footer",
               @TH.test_true occursin("[attached files in this message]", String(bubble_text)))
        record("bubble references .bt-attachments/ path",
               @TH.test_true occursin(".bt-attachments/", String(bubble_text)))

        # Thumbnail strip + textarea cleared.
        record("attachment thumbs cleared",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 0";
                   timeout = 2.0))
        record("textarea cleared",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-text-input').value === ''";
                   timeout = 2.0))

        # The files should now exist on disk under the project's server_path.
        attach_dir = joinpath(proj.server_path, ".bt-attachments")
        record("server-side .bt-attachments/ dir was created",
               @TH.test_true isdir(attach_dir))
        files = isdir(attach_dir) ? sort(readdir(attach_dir)) : String[]
        record("two files persisted (matches surviving attachments)",
               @TH.test_eq length(files) 2)
        if length(files) >= 1
            full = joinpath(attach_dir, files[1])
            record("file 1 has the expected byte length",
                   @TH.test_eq filesize(full) length(TINY_PNG_BYTES))
            # Byte-exact round-trip — the path that goes browser →
            # base64(JS) → comm → base64decode(Julia) → write must
            # preserve every byte.
            record("file 1 bytes are byte-exact with the source PNG",
                   @TH.test_eq read(full) TINY_PNG_BYTES)
        end
    end

    # ── Reject paths ─────────────────────────────────────────────────────
    TH.section("Oversized image is rejected client-side") do
        # 6 MB > 5 MB limit. We don't actually allocate 6MB of bytes here —
        # File constructor accepts a Blob of any size, and the size check
        # is on .size so a Uint8Array(6*1024*1024) is enough. We don't need
        # to ship it across the wire.
        TH.eval_js(ctx, """(() => {
            const big = new Uint8Array(6 * 1024 * 1024);
            const file = new File([big], 'huge.png', {type: 'image/png'});
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachAddBlob(file, file.type, file.name);
            return true;
        })()""")
        record("error chip appears within 2s",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-attach-error') !== null";
                   timeout = 2.0))
        record("no thumbnail was added",
               @TH.test_eq attach_count() 0)
        err_text = TH.eval_js(ctx,
            "document.querySelector('.bt-attach-error')?.innerText || ''")
        record("error chip mentions size",
               @TH.test_true occursin("too large", lowercase(String(err_text))))
    end

    TH.section("Server-side reject for unsupported mime → attach_error path") do
        # JS will happily build a File with any mime; the rejection happens
        # in process_attachments! → attachment_ext. The "send" path posts the
        # comm event directly and surfaces the error as an attach_error
        # message — which our dispatch turns into a chip in the bar.

        # Wait out / nuke any leftover error chip from the previous test
        # so we can detect a *fresh* one.
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-attach-error');
            if (c) c.remove();
            return true;
        })()""")
        # Inject the bad blob directly so we don't need a real mime in the JS
        # _attachAddBlob path (which would accept it — the JS side trusts
        # browser-issued mimes and lets the server be the authority).
        TH.eval_js(ctx, """(() => {
            const chat = document.querySelector('.bt-messages').__bt_chat;
            const bytes = new Uint8Array([0xff, 0xd8, 0xff]);
            const file = new File([bytes], 'foo.pdf', {type: 'application/pdf'});
            chat._attachAddBlob(file, file.type, file.name);
            return true;
        })()""")
        record("PDF thumbnail queued (JS doesn't gate mime)",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 1";
                   timeout = 2.0))
        TH.dom_click(ctx, ".bt-send-btn")
        record("attach_error chip appears with mime message",
               @TH.test_true TH.wait_for(ctx, """
                   (() => {
                       const c = document.querySelector('.bt-attach-error');
                       return c && c.innerText.toLowerCase().indexOf('mime') !== -1;
                   })()
                   """; timeout = 2.0))
        # Cleanup leftover bad thumb before next section.
        TH.eval_js(ctx, """(() => {
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachClear();
            const c = document.querySelector('.bt-attach-error');
            if (c) c.remove();
            return true;
        })()""")
    end

    # ── Text-only path is untouched ──────────────────────────────────────
    TH.section("Pure-text send still works (no attachments queued)") do
        n_user_before = TH.dom_count(ctx, ".bt-user-msg")
        TH.type_into(ctx, ".bt-text-input", "plain text after attachments")
        sleep(0.1)
        TH.dom_click(ctx, ".bt-send-btn")
        record("new user bubble appears",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-user-msg').length >= $(n_user_before + 1)";
                   timeout = 3.0))
        last_text = TH.eval_js(ctx, """(() => {
            const bs = document.querySelectorAll('.bt-user-msg');
            return bs[bs.length - 1].innerText;
        })()""")
        record("bubble has just the text, no [attached] footer",
               @TH.test_true (occursin("plain text after attachments", String(last_text)) &&
                              !occursin("[attached files in this message]", String(last_text))))
    end

    # ── JS errors ────────────────────────────────────────────────────────
    TH.section("No JS errors during the attachment exercise") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_eq length(errs) 0)
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "chat-attach final")

finally
    TH.report!("Tier 2k — chat attachments", results)
    TH.shutdown(ctx)
end
