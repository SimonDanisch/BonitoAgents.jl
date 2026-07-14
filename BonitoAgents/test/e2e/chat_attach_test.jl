# Black-box port of the legacy electron/test_chat_attach.jl (Tier 2k — image
# attachments) onto the shared soak server.
#
# What this exercises, all through the REAL composer running on a real
# dev_server, asserting on rendered DOM only (no server-disk introspection):
#   • Paste a fake PNG via a synthetic ClipboardEvent + DataTransfer → the
#     attachments bar goes active and one `.bt-attachment-thumb` appears, its
#     <img> carrying a `data:image/` URL (FileReader → readAsDataURL path).
#   • Paste a second image → two thumbnails.
#   • Drop a third via a synthetic DragEvent on `.bt-app` → three thumbnails,
#     and the `.bt-drag-over` class is cleared after the drop.
#   • Click the × on the middle thumb → that one disappears, two remain
#     (attachments persist in the composer until removed / sent / cleared).
#   • Send with attachments queued → the user bubble lands AND the thumbnail
#     strip + textarea are cleared (attachments consumed on send).
#   • Oversize blob (6 MB > 5 MB) → client-side reject: `.bt-attach-error` chip
#     appears mentioning "too large", NO thumbnail added.
#   • Unsupported-mime blob (application/pdf) → JS doesn't gate mime, so a thumb
#     queues; on send the SERVER rejects it (`attachment_ext` raises) and the
#     `attach_error` event surfaces a chip whose text mentions "mime".
#   • Pure-text send still works (no attachments, no [attached] footer path).
#
# IMAGE INJECTION — how the synthetic File reaches the composer:
#   The legacy test built a `File` from raw bytes in JS and dispatched a
#   `ClipboardEvent('paste', {clipboardData: dt})` / `DragEvent('drop',
#   {dataTransfer: dt})`. Under Electron's Chromium the *constructed* event
#   does NOT reliably forward `clipboardData`/`dataTransfer` onto the dispatched
#   instance (the composer's `e.clipboardData?.items` / `e.dataTransfer.files`
#   come back empty), so the legacy test already carried an `_attachAddBlob`
#   fallback. We keep BOTH paths: dispatch the real event first (exercising the
#   composer's `_onPaste`/`_onDrop` wiring), and if no thumbnail materialised
#   within the event tick, fall back to the chat's `_attachAddBlob(file, mime,
#   name)` helper (the same private method the listeners call). The File itself
#   is always a genuine browser `File` built from a Uint8Array — the bytes flow
#   blob → FileReader → data URL exactly as in production.
#
# GAP (documented, not handwaved): a black-box e2e cannot read the project's
# server-side `<cwd>/.bt-attachments/` dir, so the legacy disk assertions
# (files persisted, byte-exact round-trip, `.bt-attachments/<ts>.png` footer in
# the bubble text) are NOT reproduced here — they belong in a unit test of
# `process_attachments!` / `save_attachment`. We assert the DOM-observable
# contract: thumbnails appear/persist/clear, reject chips show, the bubble
# lands. SharedServer is fine: this is pure composer UI with no special server
# state.
@testitem "e2e:chat_attach" setup = [SharedServer] tags = [:e2e] begin
    S  = SharedServer
    s  = S.server()
    TK = S.TK

    # The mock end-turns immediately (no agent updates) — we only care about the
    # user-side composer DOM + the user bubble landing.
    s.agent_fn[] = _prompt -> [TK.end_turn()]

    # Fresh chat → fresh composer with an empty attachments bar. SCOPE every query
    # to THIS chat's pane (`P`): the soak server keeps prior items' chat panes
    # mounted (keep-alive KeyedList), so a bare `document.querySelector('.bt-
    # attachments')` / a global `.bt-attachment-thumb` count would read a STALE
    # pane and flake (worse the later this item runs in the soak). Other e2e items
    # pane-scope for exactly this reason.
    pid = TK.new_chat(s)
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    @test TK.wait_for(s, "chat input mounted",
        "document.querySelector('$(P).bt-text-input') !== null"; timeout = 30)
    @test TK.wait_for(s, "attachments bar mounted",
        "document.querySelector('$(P).bt-attachments') !== null"; timeout = 10)

    # Tiny synthetic byte payload. Not a valid PNG — neither end decodes it; the
    # MIME tag drives routing. Shipped as a JS hex→Uint8Array snippet.
    const TINY_PNG_HEX =
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"

    js_bytes_from_hex(hex) = """
        (() => {
            const hex = $(repr(hex));
            const out = new Uint8Array(hex.length / 2);
            for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i*2, 2), 16);
            return out;
        })()
    """

    attach_count() = TK.eval_js(s, "document.querySelectorAll('$(P).bt-attachment-thumb').length")

    # Build a real File in JS, dispatch the real ClipboardEvent against the
    # textarea, and fall back to the composer's `_attachAddBlob` if the
    # constructed event didn't forward the File (Chromium-under-Electron quirk).
    function paste_image(filename, hex; mime = "image/png")
        TK.eval_js(s, """(() => {
            const bytes = $(js_bytes_from_hex(hex));
            const file  = new File([bytes], $(repr(filename)), {type: $(repr(mime))});
            const dt = new DataTransfer();
            dt.items.add(file);
            const ta  = document.querySelector('$(P).bt-text-input');
            const evt = new ClipboardEvent('paste',
                {clipboardData: dt, bubbles: true, cancelable: true});
            ta.dispatchEvent(evt);
            if (!evt.clipboardData || evt.clipboardData.files.length === 0) {
                const chat = document.querySelector('$(P).bt-messages').__bt_chat;
                chat._attachAddBlob(file, file.type, file.name);
            }
            return true;
        })()""")
    end

    # Same, but a synthetic dragover+drop on `.bt-app`.
    function drop_image(filename, hex; mime = "image/png")
        TK.eval_js(s, """(() => {
            const bytes = $(js_bytes_from_hex(hex));
            const file  = new File([bytes], $(repr(filename)), {type: $(repr(mime))});
            const dt = new DataTransfer();
            dt.items.add(file);
            const app = document.querySelector('$(P).bt-app');
            app.dispatchEvent(new DragEvent('dragover',
                {dataTransfer: dt, bubbles: true, cancelable: true}));
            const drop = new DragEvent('drop',
                {dataTransfer: dt, bubbles: true, cancelable: true});
            app.dispatchEvent(drop);
            if (!drop.dataTransfer || drop.dataTransfer.files.length === 0) {
                const chat = document.querySelector('$(P).bt-messages').__bt_chat;
                chat._attachAddBlob(file, file.type, file.name);
            }
            return true;
        })()""")
    end

    # ── Empty state ─────────────────────────────────────────────────────────
    @test attach_count() == 0
    @test TK.eval_js(s, """document.querySelector('$(P).bt-attachments')
        .classList.contains('bt-attachments-active')""") === false

    # ── Paste one image → one thumbnail, bar active, <img> is a data: URL ─────
    paste_image("pasted-1.png", TINY_PNG_HEX)
    @test TK.wait_for(s, "one thumbnail",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 1"; timeout = 5)
    @test TK.eval_js(s, """document.querySelector('$(P).bt-attachments')
        .classList.contains('bt-attachments-active')""") === true
    @test TK.eval_js(s, """(() => {
        const img = document.querySelector('$(P).bt-attachment-thumb img');
        return !!(img && img.src.startsWith('data:image/'));
    })()""") === true

    # ── Paste a second image → two thumbnails ────────────────────────────────
    paste_image("pasted-2.png", TINY_PNG_HEX)
    @test TK.wait_for(s, "two thumbnails",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 2"; timeout = 5)

    # ── Drop a third onto .bt-app → three thumbnails, drag-over cleared ───────
    drop_image("dropped-3.png", TINY_PNG_HEX)
    @test TK.wait_for(s, "three thumbnails",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 3"; timeout = 5)
    @test TK.eval_js(s, """document.querySelector('$(P).bt-app')
        .classList.contains('bt-drag-over')""") === false

    # ── Click × on the middle thumb → two remain (persistence until removed) ──
    TK.eval_js(s, """(() => {
        const thumbs = document.querySelectorAll('$(P).bt-attachment-thumb');
        thumbs[1].querySelector('.bt-attachment-remove').click();
        return true;
    })()""")
    @test TK.wait_for(s, "two thumbnails remain",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 2"; timeout = 5)

    # ── Send with attachments → bubble lands, strip + textarea cleared ────────
    n_user_before = TK.eval_js(s, "document.querySelectorAll('$(P).bt-user-msg').length")
    TK.send_message(s, "look at these")
    @test TK.wait_for(s, "user bubble appears",
        "document.querySelectorAll('$(P).bt-user-msg').length >= $(n_user_before + 1)"; timeout = 10)
    bubble = String(TK.eval_js(s, """(() => {
        const bs = document.querySelectorAll('$(P).bt-user-msg');
        return bs[bs.length - 1].innerText;
    })()"""))
    @test occursin("look at these", bubble)
    @test TK.wait_for(s, "thumbs cleared on send",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 0"; timeout = 5)
    @test TK.wait_for(s, "textarea cleared on send",
        "document.querySelector('$(P).bt-text-input').value === ''"; timeout = 5)

    # ── Oversize image is rejected client-side (no thumb, "too large" chip) ───
    # A 6 MB Uint8Array trips the .size guard in `_attachAddBlob` before any
    # bytes are read; we never ship it across the wire.
    TK.eval_js(s, """(() => {
        const big  = new Uint8Array(6 * 1024 * 1024);
        const file = new File([big], 'huge.png', {type: 'image/png'});
        document.querySelector('$(P).bt-messages').__bt_chat
            ._attachAddBlob(file, file.type, file.name);
        return true;
    })()""")
    @test TK.wait_for(s, "error chip appears",
        "document.querySelector('$(P).bt-attach-error') !== null"; timeout = 5)
    @test attach_count() == 0
    @test occursin("too large", lowercase(String(
        TK.eval_js(s, "document.querySelector('$(P).bt-attach-error')?.innerText || ''"))))

    # ── Server-side reject for unsupported mime → attach_error chip ───────────
    # Clear any leftover chip so we can detect a FRESH one, then queue a PDF
    # (JS trusts the browser mime; the server is the authority).
    TK.eval_js(s, """(() => {
        const c = document.querySelector('$(P).bt-attach-error'); if (c) c.remove();
        return true;
    })()""")
    TK.eval_js(s, """(() => {
        const bytes = new Uint8Array([0xff, 0xd8, 0xff]);
        const file  = new File([bytes], 'foo.pdf', {type: 'application/pdf'});
        document.querySelector('$(P).bt-messages').__bt_chat
            ._attachAddBlob(file, file.type, file.name);
        return true;
    })()""")
    @test TK.wait_for(s, "pdf thumb queued (JS doesn't gate mime)",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 1"; timeout = 5)
    TK.click(s, "$(P).bt-send-btn")
    @test TK.wait_for(s, "attach_error chip mentions mime", """(() => {
        const c = document.querySelector('$(P).bt-attach-error');
        return !!(c && c.innerText.toLowerCase().indexOf('mime') !== -1);
    })()"""; timeout = 5)
    # Cleanup the bad thumb + chip before the text-only check.
    TK.eval_js(s, """(() => {
        const chat = document.querySelector('$(P).bt-messages').__bt_chat;
        chat._attachClear();
        const c = document.querySelector('$(P).bt-attach-error'); if (c) c.remove();
        return true;
    })()""")

    # ── Pure-text send still works (no attachments queued) ────────────────────
    n_user_before2 = TK.eval_js(s, "document.querySelectorAll('$(P).bt-user-msg').length")
    TK.send_message(s, "plain text after attachments")
    @test TK.wait_for(s, "new user bubble",
        "document.querySelectorAll('$(P).bt-user-msg').length >= $(n_user_before2 + 1)"; timeout = 10)
    last_text = String(TK.eval_js(s, """(() => {
        const bs = document.querySelectorAll('$(P).bt-user-msg');
        return bs[bs.length - 1].innerText;
    })()"""))
    @test occursin("plain text after attachments", last_text)
    @test !occursin("[attached files in this message]", last_text)

    # ── Attached image renders INLINE in the bubble (not the path-list text) ──
    # A VALID 1×1 PNG this time (the earlier TINY_PNG_HEX is a truncated header
    # that can't decode — fine for the queue/save plumbing above, useless for
    # asserting an <img> actually renders). Contract: the bubble shows the typed
    # text + a `.bt-user-att-img` loaded from the /attachment/<pid> route, and
    # never the raw "[attached files …]" suffix.
    TK.eval_js(s, """(() => {
        const b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
        const bin = atob(b64); const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const file = new File([bytes], 'inline-probe.png', {type: 'image/png'});
        document.querySelector('$(P).bt-messages').__bt_chat
            ._attachAddBlob(file, file.type, file.name);
        return true;
    })()""")
    @test TK.wait_for(s, "probe thumb queued",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 1"; timeout = 5)
    TK.send_message(s, "inline image probe")
    @test TK.wait_for(s, "bubble with inline gallery",
        """(() => {
            const b = [...document.querySelectorAll('$(P).bt-user-msg')]
                .find(e => (e.textContent||'').includes('inline image probe'));
            return !!(b && b.querySelector('.bt-user-att-img'));
        })()"""; timeout = 10)
    gallery = TK.eval_js(s, """(() => {
        const b = [...document.querySelectorAll('$(P).bt-user-msg')]
            .find(e => (e.textContent||'').includes('inline image probe'));
        const img = b.querySelector('.bt-user-att-img');
        return { raw: (b.textContent||'').includes('[attached files'),
                 route: img.getAttribute('src').startsWith('/attachment/'),
                 n: b.querySelectorAll('.bt-user-att-img').length };
    })()""")
    @test gallery["raw"] == false           # suffix text never shows
    @test gallery["route"] == true          # served via the attachment route
    @test gallery["n"] == 1
    # The image DECODES (route 200 + real mime). Poll: decode is async.
    @test TK.wait_for(s, "inline image decodes",
        """(() => {
            const b = [...document.querySelectorAll('$(P).bt-user-msg')]
                .find(e => (e.textContent||'').includes('inline image probe'));
            const img = b && b.querySelector('.bt-user-att-img');
            return !!(img && img.complete && img.naturalWidth > 0);
        })()"""; timeout = 10)

    @test isempty(TK.js_errors(s))
end
