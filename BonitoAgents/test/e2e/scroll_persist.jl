# End-to-end scroll + persistence, UI-only via TestKit. No internal-API calls.
#
# Behaviour these tests are built around (verified by probing the live DOM):
#   * The messages list is windowed/virtualised — `.bt-user-msg` and
#     `.bt-messages.innerText` reflect only the currently-rendered window. So we
#     assert against the NEWEST exchange, which follow-mode keeps pinned at the
#     bottom and therefore rendered.
#   * Reading the chat's own client-side state (`.bt-messages.__bt_chat.*`) is
#     fair game — it's the UI's state, not a Julia internal.
#
# Driving the scroll from headless: a synthetic `wheel`/`mouseWheel` input does
# NOT move the custom pan/spring scroller, but you CAN park the view by setting
# the chat's own state directly — `__bt_chat.setFollowMode(false)` then
# `container.scrollTop = N` sticks (verified). That's what the view-switch test
# below uses to put the chat off-bottom before exercising hide/show.
#
# The "parked chat is not chased to the bottom" test guards the intermittent
# scroll-jumps-to-bottom-on-switch bug: it needs a LONG history (a real bottom
# to chase, and stable fixed-pixel parking — a 2-row chat clamps oddly), built
# with a "fill N" agent prompt that streams N short tool-message rows.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# A fenced code block renders as a <pre> that preserves its 90 lines, so the
# messages container genuinely overflows (plain text collapses newlines and
# wouldn't).
const CODE = "```\n" * join(["row $(i) of generated output" for i in 1:90], "\n") * "\n```"

# "fill N" streams N short tool messages → N virtual-scroll rows (a long history
# with a real bottom to chase). "code" → one tall block. Else → a plain echo.
function agent_script(prompt)
    m = match(r"fill (\d+)", lowercase(prompt))
    if m !== nothing
        n = parse(Int, m.captures[1])
        evs = Any[TK.tool(; kind = "execute", title = "step $(i)",
                          content = [TK.text_block("result:\nline a\nline b\nline c")]) for i in 1:n]
        push!(evs, TK.text("done $(n)"))
        return evs
    end
    occursin("code", lowercase(prompt)) ? [TK.text(CODE)] : [TK.text("Echo: $(prompt)")]
end

const AT_BOTTOM = "(() => { const c=document.querySelector('.bt-messages'); return !!c && (c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()"
marker_present(s, m) = TK.wait_for(s, "marker $(m)",
    "(() => { const c=document.querySelector('.bt-messages'); return !!c && c.innerText.includes($(TK.json(m))); })()"; timeout = 20)

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents scroll + persistence (UI-only)" begin
        pid = TK.new_chat(server; title = "Scroll")

        @testset "new content follows to the bottom" begin
            TK.send_message(server, "show me code")
            @test TK.wait_for(server, "code rendered",
                "!!document.querySelector('.bt-agent-msg pre')"; timeout = 20) == true
            # the message overflows the viewport...
            @test TK.wait_for(server, "overflowing",
                "(() => { const c=document.querySelector('.bt-messages'); return !!c && c.scrollHeight > c.clientHeight + 500; })()"; timeout = 8) == true
            # ...and the newest content is pinned at the bottom, follow-mode on.
            @test TK.wait_for(server, "pinned at bottom", AT_BOTTOM; timeout = 8) == true
            @test TK.eval_js(server, "document.querySelector('.bt-messages').__bt_chat.followMode") == true
        end

        @testset "parked chat is not chased to the bottom on a view switch" begin
            # Regression for the intermittent "scroll jumps to the bottom when I
            # switch chats" bug. Mechanism: a chat parked off-bottom (followMode
            # false) is hidden on a view switch; display:none collapses the
            # container to clientHeight 0, which fires a `scroll` event with
            # scrollTop clamped to 0. `atBottom()` is then trivially true
            # (0 - 0 - 0 < AT_BOTTOM_PX), so if the switch lands within the
            # "user-driven" window that event flips followMode back to true — and
            # the next onShown chases the pane to the bottom, losing the read
            # position. The fix ignores scroll events on a zero-height container.
            #
            # Build a real history (many rows) so there's a genuine bottom to
            # chase and a fixed-pixel park is stable (a 2-row chat clamps oddly).
            # Two turns of 100 — a single 200-burst stalls the stream at ~130.
            for turn in 1:2
                TK.send_message(server, "fill 100")
                @test TK.wait_for(server, "history fill $(turn)",
                    "(() => { const c=document.querySelector('.bt-messages'); return c&&c.__bt_chat&&c.__bt_chat.totalCount>=$(turn*101); })()"; timeout = 40) == true
            end
            sleep(0.6)   # let the fill's final scroll-to-bottom chase settle
            # Park off-bottom as a real user scroll would (followMode false);
            # cancel any pending chase so it can't snap us back to the bottom.
            TK.eval_js(server, """(() => {
                const c = document.querySelector('.bt-messages').__bt_chat;
                c.setFollowMode(false);
                if (c._cancelPendingScroll) c._cancelPendingScroll();
                c._lastUserInputT = performance.now();
                c.container.scrollTop = 200;
                return true; })()""")
            sleep(0.4)   # let the park's own scroll event settle
            @test TK.eval_js(server, "Math.abs(document.querySelector('.bt-messages').scrollTop - 200) < 60") == true
            # Arm the NEXT scroll event (the imminent display:none collapse) as
            # user-driven — deterministic regardless of nav round-trip latency,
            # which is exactly the condition under which the bug bites.
            TK.eval_js(server, "document.querySelector('.bt-messages').__bt_chat._pendingUserScroll = true")
            # Switch away (dashboard) and back through the real nav path.
            TK.to_dashboard(server)
            TK.open_chat(server, pid)
            sleep(0.5)   # cover onShown's 0/raf/50/200ms restore cascade
            # followMode must NOT have flipped, and the pane must NOT be pinned to
            # the bottom — it should sit back at roughly where we parked it.
            @test TK.eval_js(server, "document.querySelector('.bt-messages').__bt_chat.followMode") == false
            # Stayed up near where we parked it (top region) — NOT chased down to
            # the bottom. (Exact-pixel restore drifts under virtual-scroll height
            # re-measurement; the bug we guard is the jump-to-bottom, so we assert
            # it stayed well within the top of a very tall history.)
            top  = TK.eval_js(server, "document.querySelector('.bt-messages').scrollTop")
            maxs = TK.eval_js(server, "(() => { const c=document.querySelector('.bt-messages'); return c.scrollHeight - c.clientHeight; })()")
            @info "scroll after switch" top maxs
            @test isa(maxs, Number) && maxs > 5000        # genuinely long history
            @test isa(top, Number) && top < 0.1 * maxs    # parked near top, not chased to bottom

            # Restore the default follow-at-bottom state for the next testset.
            TK.eval_js(server, "(() => { const c=document.querySelector('.bt-messages').__bt_chat; c.setFollowMode(true); c.scrollToBottom(); return true; })()")
            sleep(0.3)
        end

        @testset "pan momentum is cancelled on hide (no reset-to-top on switch)" begin
            # Regression for the intermittent "switching between busy chats resets
            # the scroll to the very top" bug. The custom pan/spring scroller runs
            # momentum + spring-back via requestAnimationFrame, writing scrollTop
            # every frame. If the pane is hidden (chat switch / dashboard) WHILE a
            # fling is still decaying, those rAFs used to keep running on the now
            # zero-height pane; an upward fling decays toward scrollTop 0, so the
            # saved read position was driven to the top and "reset to the start" on
            # return. `onHidden()` now cancels momentum/spring/chase before saving.
            #
            # NOTE: this needs POINTER events — a synthetic `wheel` does not drive
            # the pan scroller (see the file header), which is why nothing caught
            # this before. Pane-scoped selector since the soak server has many.
            sel = ".bt-chatpane[data-pane-pid=\"$pid\"] .bt-messages"
            # A REALISTIC upward fling: the pointermoves are spaced in REAL time so
            # the pan scroller derives a FINITE velocity. Dispatching the whole burst
            # synchronously gives every move dt≈0 → unbounded velocity, and under
            # OSR's real 60fps momentum that overshoots straight to scrollTop 0 before
            # the hide even fires (the old ~1.5fps hidden-window path moved too little
            # per frame to expose it). Spacing the moves keeps the fling realistic.
            pd(t, y) = TK.eval_js(server, """(()=>{document.querySelector($(repr(sel)))
                .dispatchEvent(new PointerEvent("$(t)",{bubbles:true,pointerId:1,button:0,pointerType:'mouse',clientY:$(y)}));return true;})()""")
            TK.eval_js(server, "(()=>{document.querySelector($(repr(sel))).scrollTop=1000;return true;})()")
            pd("pointerdown", 300)
            for y in 312:14:520; pd("pointermove", y); sleep(0.01); end
            pd("pointerup", 520)
            momentum = TK.eval_js(server, """(()=>{const ch=document.querySelector($(repr(sel))).__bt_chat;
                return ch._momentumRaf!==null || ch._springRaf!==null;})()""")
            @test momentum === true                       # the fling engaged the pan momentum
            TK.to_dashboard(server)                        # hide mid-fling → onHidden
            sleep(0.1)
            # The fix: onHidden cancelled both rAFs (none left mutating scrollTop on
            # the hidden pane) and froze a non-top saved position.
            @test TK.eval_js(server, """(() => { const ch=document.querySelector($(repr(sel))).__bt_chat;
                return ch._momentumRaf===null && ch._springRaf===null; })()""") === true
            @test TK.eval_js(server, "Math.round(document.querySelector($(repr(sel))).__bt_chat._savedScrollTop)") > 100
            TK.open_chat(server, pid); sleep(0.3)
            TK.eval_js(server, "(() => { const c=document.querySelector($(repr(sel))).__bt_chat; c.setFollowMode(true); c.scrollToBottom(); return true; })()")
            sleep(0.2)
        end

        @testset "history survives a browser reconnect" begin
            # A short, distinctive LAST message (echo, not a tall block) so the
            # marker stays in the bottom render window follow-mode pins to.
            marker = "MARKER-7f3a91"
            TK.send_message(server, marker)
            @test marker_present(server, marker) == true
            @test TK.wait_for(server, "pinned at bottom", AT_BOTTOM; timeout = 20) == true

            # Reconnect: a fresh Electron window onto the same running server.
            TK.open_browser(server)
            TK.open_chat(server, pid)
            @test marker_present(server, marker) == true
        end

    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
