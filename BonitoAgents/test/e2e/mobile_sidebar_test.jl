# The phone's sidebar is an icon rail for switching chats, and nothing on it
# closes one. It used to show a ✕ on the icon itself (a phone keeps `:hover` on
# what was tapped last), and every few taps closed and shut down the chat that
# was meant to be opened. Closing lives in the whole sidebar instead, which the
# sidebar's toggle opens over the page: names, and a ✕ of finger size at each
# row's right edge. Choosing a chat there, or tapping beside it, closes it.
@testitem "e2e:mobile_sidebar" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TK
    s = SharedServer.server()
    a = TK.new_chat(s; title = "PhoneKeep")
    TK.send_message(s, "hello keep")
    b = TK.new_chat(s; title = "PhoneClose")
    TK.send_message(s, "hello close")
    ROW(pid) = ".bt-side-item[data-project-id=\"$(pid)\"]"
    SIDE = "document.querySelector('.bt-sidebar')"
    # Both turns over first, so the list does not change under the taps. A run
    # after eight other items once saw the first tap switch nothing.
    active(pid) = "document.querySelector($(TK.json(ROW(pid)))).closest('.bt-side-chat')" *
                  ".querySelector('.bt-side-icon-wrap').classList.contains('bt-glow-active')"
    @test TK.wait_for(s, "both idle", "!$(active(a)) && !$(active(b))"; timeout = 30) == true
    TK.emulate_phone(s) do
        @test TK.wait_for(s, "the phone rail", "$(SIDE).getBoundingClientRect().width < 60"; timeout = 5) == true
        # ── the rail: switching only ────────────────────────────────────────
        TK.tap(s, ROW(a))
        @test TK.wait_for(s, "chat A on screen",
            "document.querySelector('.bt-main-views').dataset.activeView === $(TK.json(a))"; timeout = 15) == true
        # Right after the tap, with the tapped icon still "hovered": no ✕.
        @test TK.eval_js(s, "getComputedStyle(document.querySelector($(TK.json(ROW(a) * " .bt-side-close")))).display") == "none"
        @test TK.eval_js(s, "$(SIDE).getBoundingClientRect().width") ≈ 56 atol = 1

        # ── the open sidebar ────────────────────────────────────────────────
        stage_left = TK.eval_js(s, "document.querySelector('.bt-stage').getBoundingClientRect().left")
        TK.tap(s, ".bt-side-collapse")
        @test TK.wait_for(s, "the sidebar open", "$(SIDE).classList.contains('bt-side-open')"; timeout = 5) == true
        open_state = TK.eval_js(s, """(() => {
            const side = $(SIDE), r = side.getBoundingClientRect();
            const row = side.querySelector($(TK.json(ROW(b))));
            const x = row.querySelector('.bt-side-close').getBoundingClientRect();
            const icon = row.querySelector('.bt-proj-icon').getBoundingClientRect();
            return {width: Math.round(r.width), name: getComputedStyle(row.querySelector('.bt-side-name')).display,
                    closeSize: [Math.round(x.width), Math.round(x.height)],
                    clear: x.left >= icon.right + 20,
                    stage: Math.round(document.querySelector('.bt-stage').getBoundingClientRect().left)}; })()""")
        @test open_state["width"] > 200
        @test open_state["name"] != "none"                  # the names are there
        @test all(>=(30), open_state["closeSize"])          # a ✕ a finger can hit
        @test open_state["clear"] == true                   # far from the icon
        @test open_state["stage"] == round(Int, stage_left) # nothing behind it moved
        TK.screenshot(s, joinpath(tempdir(), "mobile_sidebar_open.png"))

        # The ✕ closes chat B; the sidebar stays open for the next one.
        TK.tap(s, ROW(b) * " .bt-side-close")
        @test TK.wait_for(s, "chat B gone", "!document.querySelector($(TK.json(ROW(b))))"; timeout = 15) == true
        @test TK.eval_js(s, "$(SIDE).classList.contains('bt-side-open')") == true
        @test TK.eval_js(s, "!!document.querySelector($(TK.json(ROW(a))))") == true

        # Choosing a chat closes it.
        TK.tap(s, ".bt-side-item[data-project-id=\"\"]")          # Home
        @test TK.wait_for(s, "home, sidebar closed",
            "document.querySelector('.bt-main-views').dataset.activeView === '' && !$(SIDE).classList.contains('bt-side-open')";
            timeout = 10) == true
        # And so does a tap beside it, which lands on nothing else.
        TK.tap(s, ".bt-side-collapse")
        @test TK.wait_for(s, "open again", "$(SIDE).classList.contains('bt-side-open')"; timeout = 5) == true
        w, h = TK.eval_js(s, "[innerWidth, innerHeight]")
        TK.touch(s, "await T('touchStart', $(w - 20), $(h ÷ 2)); await T('touchEnd', $(w - 20), $(h ÷ 2));")
        @test TK.wait_for(s, "closed by the backdrop", "!$(SIDE).classList.contains('bt-side-open')"; timeout = 5) == true
        @test TK.eval_js(s, "document.querySelector('.bt-main-views').dataset.activeView") == ""
    end
    @test isempty(TK.js_errors(s))
end
