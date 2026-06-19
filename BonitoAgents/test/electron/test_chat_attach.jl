# Image attachments — paste/drop, multi, remove, send-with-attachments, error
# paths — migrated onto the TestKit harness (real dev_server, real worker
# subprocess, real ACP wire, real Electron browser; only the agent's behaviour
# is faked via the `agent=` callback).
#
# What this exercises (user-visible behaviour preserved from the legacy
# MockTransport version):
#   - Attach a fake PNG via the chat's `_attachAddBlob` hook → thumbnail strip
#     becomes active, one `.bt-attachment-thumb` appears, its <img> uses a
#     data: URL.
#   - Attach two more → three thumbnails; remove the middle one → two remain.
#   - Send with attachments queued → the user bubble carries the
#     `[attached files in this message]` footer with `.bt-attachments/` refs,
#     the files are persisted byte-exact under `<chat cwd>/.bt-attachments/`,
#     and the thumbnail strip + composer are cleared.
#   - Oversized blob (> 5 MB) → client-side `.bt-attach-error` chip, no thumb.
#   - Unsupported mime (application/pdf) → server-side reject surfaces as an
#     `attach_error` chip mentioning mime.
#   - Pure-text send still works (no attachments → no footer).
#
# MIGRATION NOTES vs the legacy MockTransport version:
#   - `TH.make_state`/`TH.mock_transport`/`TH.open_window` are gone. We boot a
#     real `dev_server` and a real chat via `new_chat`, then drive attach via
#     the same `_attachAddBlob` DOM hook the legacy paste/drop fallbacks used
#     (the synthetic ClipboardEvent/DragEvent `dataTransfer.files` forwarding is
#     unreliable headless, so the legacy test already fell back to this hook —
#     we use it directly).
#   - The attachment send round-trips through the REAL comm path: browser →
#     base64 → comm SendCommand → `process_attachments!` → bytes written under
#     `model.cwd/.bt-attachments/`. We assert byte-exact persistence off the
#     live `model.cwd` (the chat dir created by `new_chat`).
#   - The agent default is benign (end_turn) — this is a user-side persistence
#     test, the agent's reply is irrelevant.

using Test, Base64
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, end_turn

# Tiny synthetic byte payload. Doesn't need to be a valid PNG — neither end
# decodes it; the MIME tag drives routing.
const TINY_PNG_BYTES = UInt8[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
]
const TINY_PNG_HEX = lowercase(bytes2hex(TINY_PNG_BYTES))

@testset "image attachments — paste/drop/remove/send/persist/errors" begin
    s = TK.dev_server(; agent = _msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        TK.wait_for(s, "attachments bar mounted",
            "document.querySelector('.bt-attachments') !== null"; timeout = 10)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        chat_cwd = model.cwd   # where .bt-attachments/ lands on disk

        # Drive the chat's `_attachAddBlob(File, mime, filename)` hook directly,
        # building the File from a hex byte string (same payload as legacy).
        attach_hex(filename, hex; mime = "image/png") = TK.eval_js(s, """(() => {
            const hex = $(TK.json(hex));
            const bytes = new Uint8Array(hex.length/2);
            for (let i=0;i<bytes.length;i++) bytes[i]=parseInt(hex.substr(i*2,2),16);
            const file = new File([bytes], $(TK.json(filename)), {type: $(TK.json(mime))});
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachAddBlob(file, file.type, file.name);
            return true; })()""")
        attach_count() = Int(TK.eval_js(s, "document.querySelectorAll('.bt-attachment-thumb').length"))

        # ── Empty state ───────────────────────────────────────────────────────
        @test attach_count() == 0
        @test TK.eval_js(s, "document.querySelector('.bt-attachments').classList.contains('bt-attachments-active')") == false

        # ── Attach one → one thumbnail, bar active, data: URL ─────────────────
        attach_hex("pasted-1.png", TINY_PNG_HEX)
        @test TK.wait_for(s, "one thumb",
            "document.querySelectorAll('.bt-attachment-thumb').length === 1"; timeout = 4)
        @test TK.eval_js(s, "document.querySelector('.bt-attachments').classList.contains('bt-attachments-active')") == true
        @test TK.eval_js(s, """(() => {
            const img = document.querySelector('.bt-attachment-thumb img');
            return !!(img && img.src.startsWith('data:image/')); })()""") == true

        # ── Attach a second → two thumbnails ──────────────────────────────────
        attach_hex("pasted-2.png", TINY_PNG_HEX)
        @test TK.wait_for(s, "two thumbs",
            "document.querySelectorAll('.bt-attachment-thumb').length === 2"; timeout = 4)

        # ── Attach a third → three thumbnails ─────────────────────────────────
        attach_hex("dropped-3.png", TINY_PNG_HEX)
        @test TK.wait_for(s, "three thumbs",
            "document.querySelectorAll('.bt-attachment-thumb').length === 3"; timeout = 4)

        # ── Remove the middle thumbnail → two remain ──────────────────────────
        TK.eval_js(s, """(() => {
            const thumbs = document.querySelectorAll('.bt-attachment-thumb');
            thumbs[1].querySelector('.bt-attachment-remove').click();
            return true; })()""")
        @test TK.wait_for(s, "two thumbs remain",
            "document.querySelectorAll('.bt-attachment-thumb').length === 2"; timeout = 4)

        # ── Send with attachments → footer + byte-exact files on disk ─────────
        before_user = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        TK.send_message(s, "look at these")
        @test TK.wait_for(s, "user bubble appears",
            "document.querySelectorAll('.bt-user-msg').length >= $(before_user + 1)"; timeout = 8)

        bubble_text = String(TK.eval_js(s, """(() => {
            const bs = document.querySelectorAll('.bt-user-msg');
            return bs[bs.length - 1].innerText; })()"""))
        @test occursin("look at these", bubble_text)
        @test occursin("[attached files in this message]", bubble_text)
        @test occursin(".bt-attachments/", bubble_text)

        @test TK.wait_for(s, "thumbs cleared",
            "document.querySelectorAll('.bt-attachment-thumb').length === 0"; timeout = 4)
        @test TK.wait_for(s, "composer cleared",
            "document.querySelector('.bt-text-input').value === ''"; timeout = 4)

        # Files persisted byte-exact under the chat dir's .bt-attachments/.
        # The send round-trips browser→base64→comm→disk async, so poll for the
        # two files to land rather than sampling immediately.
        attach_dir = joinpath(chat_cwd, ".bt-attachments")
        @test timedwait(8.0) do
            isdir(attach_dir) && length(readdir(attach_dir)) == 2
        end === :ok
        files = sort(readdir(attach_dir))
        @test length(files) == 2
        full = joinpath(attach_dir, files[1])
        @test filesize(full) == length(TINY_PNG_BYTES)
        @test read(full) == TINY_PNG_BYTES   # byte-exact: browser→base64→comm→disk

        # ── Oversized blob → client-side error chip, no thumbnail ─────────────
        TK.eval_js(s, """(() => {
            const big = new Uint8Array(6 * 1024 * 1024);
            const file = new File([big], 'huge.png', {type: 'image/png'});
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachAddBlob(file, file.type, file.name);
            return true; })()""")
        @test TK.wait_for(s, "size error chip",
            "document.querySelector('.bt-attach-error') !== null"; timeout = 4)
        @test attach_count() == 0
        err_text = String(TK.eval_js(s, "document.querySelector('.bt-attach-error')?.innerText || ''"))
        @test occursin("too large", lowercase(err_text))

        # ── Unsupported mime → server-side reject (attach_error chip) ─────────
        # Clear any leftover error chip so we detect a fresh one.
        TK.eval_js(s, "(() => { const c=document.querySelector('.bt-attach-error'); if(c)c.remove(); return true; })()")
        # JS doesn't gate mime — it queues the blob and lets the server be the
        # authority (process_attachments! → attachment_ext rejects pdf).
        TK.eval_js(s, """(() => {
            const chat = document.querySelector('.bt-messages').__bt_chat;
            const bytes = new Uint8Array([0xff, 0xd8, 0xff]);
            const file = new File([bytes], 'foo.pdf', {type: 'application/pdf'});
            chat._attachAddBlob(file, file.type, file.name);
            return true; })()""")
        @test TK.wait_for(s, "pdf thumb queued (JS trusts mime)",
            "document.querySelectorAll('.bt-attachment-thumb').length === 1"; timeout = 4)
        TK.eval_js(s, "(() => { const b=document.querySelector('.bt-send-btn'); if(b)b.click(); return true; })()")
        @test TK.wait_for(s, "mime attach_error chip", """
            (() => { const c = document.querySelector('.bt-attach-error');
                     return !!(c && c.innerText.toLowerCase().indexOf('mime') !== -1); })()
        """; timeout = 6)
        # Clean up leftover bad thumb + chip before the text-only section.
        TK.eval_js(s, """(() => {
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachClear();
            const c = document.querySelector('.bt-attach-error'); if (c) c.remove();
            return true; })()""")

        # ── Pure-text send still works (no footer) ────────────────────────────
        before_user2 = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        TK.send_message(s, "plain text after attachments")
        @test TK.wait_for(s, "text-only user bubble",
            "document.querySelectorAll('.bt-user-msg').length >= $(before_user2 + 1)"; timeout = 8)
        last_text = String(TK.eval_js(s, """(() => {
            const bs = document.querySelectorAll('.bt-user-msg');
            return bs[bs.length - 1].innerText; })()"""))
        @test occursin("plain text after attachments", last_text)
        @test !occursin("[attached files in this message]", last_text)

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-attach-final.png"))

        # ── No JS errors across the whole attachment exercise ─────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
