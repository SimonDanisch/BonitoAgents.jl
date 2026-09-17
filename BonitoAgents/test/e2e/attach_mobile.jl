# The composer at PHONE width.
#
# The attach button exists for touch: paste needs a clipboard holding a file and
# drag-drop needs a pointer, so before the button a phone had no way to attach
# an image at all. Which means the one place it must not be broken is the one
# place the shared suite never looks — every other e2e item runs in a 1280px
# window, where a 40px button costs nothing.
#
# Its own window, because width is the whole point and `open_browser` sizes the
# window at open time; resizing the SHARED window would hand every later item a
# 390px viewport. Its own server for the same reason the review-scope item has
# one: an isolated window needs an isolated server to attach to.
#
# 390×780 is an iPhone 14 in CSS pixels, comfortably inside the `max-width:
# 480px` block in styles.jl, so the mobile rules are the ones under test.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

function run_suite(s)
    s.agent_fn[] = _prompt -> [TK.end_turn()]

    pid = TK.new_chat(s)
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    @test TK.wait_for(s, "composer mounted",
        "document.querySelector('$(P).bt-text-input') !== null"; timeout = 30)
    @test TK.wait_for(s, "attach button mounted",
        "document.querySelector('$(P).bt-attach-btn') !== null"; timeout = 10)

    # The window really is phone-sized and the mobile block really applied. If
    # this fails everything below is measuring a desktop layout and passing for
    # the wrong reason.
    @test TK.eval_js(s, "window.innerWidth") <= 480
    @test TK.eval_js(s, """(() => {
        const cwd = document.querySelector('.bt-header-cwd');
        return cwd === null || getComputedStyle(cwd).display === 'none';
    })()""") === true

    m = TK.eval_js(s, """(() => {
        const row  = document.querySelector('$(P).bt-input-row');
        const btn  = document.querySelector('$(P).bt-attach-btn');
        const ta   = document.querySelector('$(P).bt-text-input');
        const area = document.querySelector('$(P).bt-input-area');
        const r = e => { const b = e.getBoundingClientRect();
                         return {x: b.left, r: b.right, w: b.width, h: b.height}; };
        return {
            btn: r(btn), ta: r(ta), row: r(row),
            rowOverflow:  row.scrollWidth  - row.clientWidth,
            areaOverflow: area.scrollWidth - area.clientWidth,
            vw: window.innerWidth,
        };
    })()""")

    # Tap target survives the narrow layout — nothing in the mobile block may
    # shrink it, since this is the width where it matters most.
    @test m["btn"]["w"] >= 40
    @test m["btn"]["h"] >= 40

    # The icon actually LOADED. Every assertion here passes just as happily with
    # a broken-image glyph sitting in a correctly-sized box: a typo in the asset
    # name, or an svg the server does not serve, would leave the button looking
    # empty and nothing else would notice. `naturalWidth` stays 0 until the
    # image decodes, so this pins that the file resolves AND parses.
    @test TK.wait_for(s, "the paperclip icon decoded", """(() => {
        const img = document.querySelector('$(P).bt-attach-btn img');
        return !!(img && img.complete && img.naturalWidth > 0);
    })()"""; timeout = 10) == true

    # Fully on screen. A flex row that overflows pushes its FIRST child off the
    # left edge, where nothing can tap it and no assertion about its size would
    # notice.
    @test m["btn"]["x"] >= 0
    @test m["btn"]["r"] <= m["vw"]

    # Nothing overflows horizontally. `.bt-input-row` is a flex row of
    # button + textarea + controls column; if the textarea failed to shrink
    # (a missing `min-width: 0`) the row would scroll sideways instead.
    @test m["rowOverflow"] <= 1
    @test m["areaOverflow"] <= 1

    # And the textarea is still the composer, not a slot between two toolbars.
    # Half the row is a deliberate floor: the button (40) plus the send/stop
    # column plus gaps is roughly a third of a 390px screen, so anything under
    # 50% means the chrome has started eating the message.
    @test m["ta"]["w"] >= 0.5 * m["row"]["w"]

    # It still works, not just fits: the button drives the hidden input (stubbed
    # — a real click opens an OS-modal picker) and a picked file queues a thumb.
    TK.eval_js(s, """(() => {
        const inp = document.querySelector('$(P).bt-attach-input');
        window.__btPickerOpened = 0;
        inp.click = () => { window.__btPickerOpened++; };
        return true;
    })()""")
    TK.click(s, "$(P).bt-attach-btn")
    @test TK.wait_for(s, "tap opens the picker",
        "window.__btPickerOpened === 1"; timeout = 5)

    TK.eval_js(s, """(() => {
        const b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
        const bin = atob(b64); const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const dt = new DataTransfer();
        dt.items.add(new File([bytes], 'phone.png', {type: 'image/png'}));
        const inp = document.querySelector('$(P).bt-attach-input');
        inp.files = dt.files;
        inp.dispatchEvent(new Event('change', {bubbles: true}));
        return true;
    })()""")
    @test TK.wait_for(s, "picked image queues a thumbnail",
        "document.querySelectorAll('$(P).bt-attachment-thumb').length === 1"; timeout = 5)

    # The thumbnail strip must not push the composer off screen either.
    @test TK.eval_js(s, """(() => {
        const a = document.querySelector('$(P).bt-input-area');
        return a.scrollWidth - a.clientWidth;
    })()""") <= 1

    # Focus lands back in the textarea so the caption is one tap away, not two.
    @test TK.eval_js(s, """document.activeElement ===
        document.querySelector('$(P).bt-text-input')""") === true

    # `BT_SHOT=/tmp/x.png` to get an actual picture of this layout. Off by
    # default, so it costs a CI run nothing. Worth keeping: every assertion here
    # is a measurement, and measurements pass just as happily on a composer that
    # is subtly wrong to look at. The icon-decodes check above exists because a
    # screenshot showed what the numbers could not.
    get(ENV, "BT_SHOT", "") == "" || TK.screenshot(s, ENV["BT_SHOT"])

    @test isempty(TK.js_errors(s))
end
