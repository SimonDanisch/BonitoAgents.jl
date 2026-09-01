# The chat's scroll position must survive its PANEL BEING MOVED in the DOM.
#
# This is the invariant behind a bug that has been "fixed" many times and keeps
# coming back, because every previous fix — and every previous test — chased a
# symptom (cascade timing, the settle watcher, momentum cancellation, anchor
# restore) instead of the thing that actually breaks.
#
# What actually happens: BonitoWidgets rebuilds its panel tree on every render.
# It parks each `.bw-ws-panel` into `.bw-ws-parking`, then re-places it into its
# group — TWICE per chat switch, in the ~10ms right after the chat pins its own
# scroll. Detaching an element resets `scrollTop` to 0 in the BROWSER. That
# means:
#
#   • no JS ever writes scrollTop, so trapping the property sees nothing;
#   • park + re-place happen in ONE synchronous task, so the container's
#     end-of-frame size never changes and ResizeObserver never fires;
#   • BonitoWidgets' own snapshotScroll skips elements reading `scrollTop === 0`
#     — i.e. exactly the pane that was hidden when the snapshot was taken.
#
# The position is destroyed with no observable event at all, which is why this
# survived so many rounds of fixing.
#
# The existing scroll suites cannot catch it: they scroll WITHIN a pane, and
# their chats are short enough that `scrollTop 0` is roughly the bottom anyway,
# so the reset is invisible. This one asserts the invariant directly — perform
# the same park/re-place BonitoWidgets does, then require the position back. It
# depends on no timing, no chat length beyond "taller than the viewport", and no
# BonitoWidgets internals staying put. Refactor the scroll code and drop the
# recovery, and this goes red immediately.
@testitem "e2e:panel_move_scroll" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    using Test

    # Long replies so the content clears the viewport by a wide margin: the bug
    # is only VISIBLE when scrollTop 0 is far from the bottom.
    agent_script(p) = [TK.text("reply to $(p)\n\n" *
        join(["paragraph $i " * repeat("filler ", 30) for i in 1:6], "\n\n")), TK.end_turn()]

    const C = "document.querySelector('.bt-chatpane[style*=\"flex\"] .bt-messages')"

    metrics_js = """(() => {
        const c = $(C); if (!c) return null;
        return {top: Math.round(c.scrollTop), h: Math.round(c.scrollHeight),
                ch: c.clientHeight,
                fromBottom: Math.round(c.scrollHeight - c.scrollTop - c.clientHeight)};
    })()"""

    # Exactly what BonitoWidgets' render() does: park the panel, then re-place
    # it. Returns the scrollTop the browser left behind immediately after, so
    # the test can confirm the move really did reset it (otherwise the test
    # would pass for the wrong reason on some future DOM layout).
    move_panel_js = """(() => {
        const c = $(C); if (!c) return null;
        const panel = c.closest('.bw-ws-panel'); if (!panel) return 'no-panel';
        const parent = panel.parentElement, next = panel.nextSibling;
        const park = document.querySelector('.bw-ws-parking') ||
                     parent.appendChild(document.createElement('div'));
        park.appendChild(panel);              // detach → scrollTop dies here
        parent.insertBefore(panel, next);     // re-place
        return Math.round(c.scrollTop);
    })()"""

    server = TK.dev_server(agent = agent_script, name = "move-w")
    try
        TK.open_browser(server)
        pid = TK.new_chat(server; cwd = mktempdir(), title = "MovePanel")
        for i in 1:8
            TK.send_message(server, "msg $i")
            sleep(0.4)
        end
        sleep(2)

        m0 = TK.eval_js(server, metrics_js)
        @test m0 !== nothing
        # The premise: content must clear the viewport by a lot, or scrollTop 0
        # would already be "at the bottom" and this test proves nothing.
        @test Int(m0["h"]) - Int(m0["ch"]) > 800

        @testset "following the bottom survives a park/re-place" begin
            TK.eval_js(server, "(() => { const c = $(C); c.scrollTop = c.scrollHeight; return true; })()")
            sleep(1)
            @test Int(TK.eval_js(server, metrics_js)["fromBottom"]) < 60

            right_after = TK.eval_js(server, move_panel_js)
            @test right_after != "no-panel"
            # Guard the guard: if the browser ever stops resetting scrollTop on
            # re-insert, this test is no longer exercising the bug and should
            # say so rather than pass silently.
            @test Int(right_after) == 0

            @test TK.wait_for(server, "back at the bottom after the move",
                "$(metrics_js).fromBottom < 60"; timeout = 15) == true
        end

        @testset "a scrolled-up read position survives a park/re-place" begin
            target = 300
            TK.eval_js(server, """(() => {
                const c = $(C); c.__bt_chat.pendingUserScroll = true;
                c.scrollTop = $(target); c.dispatchEvent(new Event('scroll')); return true; })()""")
            sleep(1)
            before = Int(TK.eval_js(server, metrics_js)["top"])
            @test abs(before - target) < 80        # we really are parked mid-history

            @test Int(TK.eval_js(server, move_panel_js)) == 0
            @test TK.wait_for(server, "read position restored after the move",
                "Math.abs($(metrics_js).top - $(before)) < 80"; timeout = 15) == true
        end
    finally
        close(server)
    end
end
