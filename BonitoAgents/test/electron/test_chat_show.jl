# bt_show preview rendering, migrated onto the TestKit harness (real dev_server,
# real worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked, via the `agent=` callback).
#
# `bt_show` is the BonitoMCP tool that writes a file to the project's cwd and
# emits a `shown: <relpath> (<mime>, <size>)` text marker in a tool_call. The
# chat detects the marker (`find_show_reference`) and renders an inline preview:
# image/* → a served `<img>` (a /assets/ URL, never a multi-MB `data:` blob);
# text/* → a read-only Monaco editor. When the referenced file already lives on
# the server mirror (`joinpath(model.cwd, relpath)`), rendering is synchronous.
#
# We cover that synchronous path for two MIME categories — image/png and
# text/plain — by writing the files directly into the chat's server-side cwd
# (`model.cwd`) BEFORE the agent emits the `shown:` tool bubbles, exactly as the
# real `bt_show` tool would have left them there. The agent reuses the harness's
# generic `tool(...)` event, whose content is a single `text_block("shown: …")`.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, tool, text_block, end_turn

# 5x5 PNG (tiny but valid) — same bytes the legacy test used.
const PNG_BYTES = UInt8[
    0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,
    0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,
    0x00,0x00,0x00,0x05,0x00,0x00,0x00,0x05,
    0x08,0x02,0x00,0x00,0x00,0x02,0x0d,0xb1,
    0xb2,0x00,0x00,0x00,0x1f,0x49,0x44,0x41,
    0x54,0x18,0x57,0x63,0xfc,0xcf,0xc0,0xf0,
    0x9f,0x81,0xe1,0x3f,0x03,0xc3,0x7f,0x06,
    0x86,0xff,0x0c,0x0c,0xff,0x19,0x18,0xfe,
    0x33,0x30,0xfc,0x67,0x60,0xf8,0xcf,0xc0,
    0x00,0x00,0xa3,0xfa,0x06,0x01,0xea,0x42,
    0xa6,0x95,0x00,0x00,0x00,0x00,0x49,0x45,
    0x4e,0x44,0xae,0x42,0x60,0x82,
]
const TXT_BODY = "Hello from bt_show preview test\nLine two"

@testset "bt_show — PNG + text previews render inline from the cwd mirror" begin
    # The agent answers ANY prompt with two bt_show-style tool bubbles: a PNG
    # show and a text show. Their `shown:` markers point at files we pre-write
    # into the chat's server-side cwd, so the chat renders both synchronously.
    s = TK.dev_server(; agent = msg -> [
        text("Showing the files."),
        tool(; id = "show-1", kind = "other", title = "bt_show tiny.png",
               status = "completed",
               content = [text_block("shown: show/tiny.png (image/png, $(length(PNG_BYTES)) bytes)")]),
        tool(; id = "show-2", kind = "other", title = "bt_show hello.txt",
               status = "completed",
               content = [text_block("shown: show/hello.txt (text/plain, $(length(codeunits(TXT_BODY))) bytes)")]),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        # Drop the PNG + text file into the chat's SERVER-SIDE cwd (model.cwd),
        # the directory `shown: <relpath>` resolves against in show_server_path.
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        showdir = joinpath(model.cwd, "show")
        mkpath(showdir)
        write(joinpath(showdir, "tiny.png"), PNG_BYTES)
        write(joinpath(showdir, "hello.txt"), TXT_BODY)

        TK.send_message(s, "show stuff")

        # Both tool bubbles arrive.
        TK.wait_for(s, "two tool bubbles arrive",
            "document.querySelectorAll('.bt-tool-msg').length >= 2"; timeout = 30)

        # ── PNG preview — synchronous render from cwd mirror ────────────────
        # NO click: a bt_show result auto-expands (has_show_reference forces the
        # body open + ships show_mime). A header click would TOGGLE it closed.
        TK.wait_for(s, "img element appears in PNG tool body", """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="show-1"]');
                return slot && slot.querySelector('img') !== null;
            })()
        """; timeout = 20)
        # bt_show points <img src> at a served Bonito.Asset (range-capable),
        # NOT a multi-MB data: blob. The src resolves to a /assets/<key> URL.
        img_src = TK.eval_js(s, """
            (() => {
                const img = document.querySelector('.bt-tool-body[data-tool-id="show-1"] img');
                return img ? img.src : null;
            })()
        """)
        @test img_src isa AbstractString
        @test !startswith(img_src, "data:")
        @test occursin("/assets/", img_src)

        # ── Text preview — Monaco read-only inside tool body ────────────────
        # Same auto-expand contract; Monaco renders inside .monaco-editor.
        TK.wait_for(s, "monaco editor appears", """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="show-2"]');
                return slot && slot.querySelector('.monaco-editor') !== null;
            })()
        """; timeout = 25)
        # The editor mounted with a real height (it laid out, not a 0px stub).
        @test TK.wait_for(s, "monaco editor body has content", """
            (() => {
                const slot = document.querySelector('.bt-tool-body[data-tool-id="show-2"]');
                const me   = slot ? slot.querySelector('.monaco-editor') : null;
                return me && me.getBoundingClientRect().height > 10;
            })()
        """; timeout = 10)

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-show-final.png"))

        # No JS errors fired during preview rendering.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
