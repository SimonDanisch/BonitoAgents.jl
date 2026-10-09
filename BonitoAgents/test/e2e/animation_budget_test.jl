# An endless animation draws a frame only when its picture changes (stepped
# timing). A smooth one keeps the browser making 60 frames a second for as long
# as it runs, whatever it animates: measured with a GPU, the busy dots alone
# cost 40% of a core for every agent turn, and each live tool card's pulse as
# much again, for as long as the task ran. Stepped, the two together cost 17%.
@testitem "e2e:animation_budget" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    s.agent_fn[] = _ -> [TK.tool(kind = "execute", title = "a long tool", id = "anim-$(rand(UInt32))",
                                 status = "in_progress", complete = false),
                         TK.delay(8_000), TK.end_turn()]
    TK.new_chat(s; title = "Animations")
    TK.send_message(s, "go")
    @test TK.wait_for(s, "the busy dots and a live tool card",
        "!!document.querySelector('.bt-busy.bt-busy-active') && !!document.querySelector('.bt-tool-live')";
        timeout = 30) == true

    # Every element and pseudo-element on the page with an endless animation.
    animations = TK.eval_js(s, """(() => {
        const out = [];
        for (const el of document.querySelectorAll('*')) {
            for (const pseudo of [null, '::before', '::after']) {
                const cs = getComputedStyle(el, pseudo);
                if (cs.animationName === 'none' || !cs.animationIterationCount.includes('infinite')) continue;
                out.push({what: (typeof el.className === 'string' ? el.className : el.tagName) + (pseudo || ''),
                          name: cs.animationName, timing: cs.animationTimingFunction});
            }
        }
        return out;
    })()""")
    # Not vacuous: the busy dots and the live card's pulse are among them.
    @test any(a -> a["name"] == "bt-pulse", animations)
    @test any(a -> a["name"] == "bt-pulse-glow", animations)
    smooth = [a for a in animations if !startswith(a["timing"], "steps")]
    isempty(smooth) || @info "endless animations with smooth timing" smooth
    @test isempty(smooth)

    @test TK.wait_for(s, "the turn ends", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 30) == true
    s.agent_fn[] = S.default_agent
end
