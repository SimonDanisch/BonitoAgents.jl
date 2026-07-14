# Toggling a message-TYPE filter (the `hiddenTypes` toolbar) while scrolled up in
# history must NOT move the view. Hiding/showing a type reflows the transcript
# (matching rows collapse to / expand from 0px) — a bulk above-viewport height
# change. `setKeyHidden` captures the top-visible SURVIVING row BEFORE the reflow
# and re-pins it after refresh; pre-fix the reflow jumped the reader several
# messages down (marker 9 -> 15 in the repro) because refresh's own anchor ran
# only AFTER the jump and faithfully preserved the wrong spot (#48).
@testitem "e2e:filter_scroll" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer; s = S.server(); TK = S.TK

    function seed_agent(prompt)
        occursin("seed", lowercase(prompt)) || return [TK.text("echo")]
        evs = Any[]
        for i in 1:30
            push!(evs, TK.text("marker bubble number $(i) — a short line of prose"))
            push!(evs, TK.tool(kind = "read", title = "probe tool $(i)", id = "probe-$(i)"))
        end
        evs
    end
    s.agent_fn[] = seed_agent

    TK.new_chat(s; title = "FilterScroll")
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "seeded",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 5"; timeout = 30) == true
    @test TK.wait_for(s, "overflows",
        "(() => { const c=[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent); return !!c && c.scrollHeight > c.clientHeight + 800; })()"; timeout = 15) == true

    CH = "[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent).__bt_chat"
    # Top-visible MARKER number (a text bubble; skip the tool rows so a hidden
    # tool sitting at the very top isn't itself counted as a "jump").
    MARKER = """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const st = c.scrollTop;
        const nodes = [...c.querySelectorAll('.bt-agent-msg')].filter(n=>n.offsetParent).sort((a,b)=>a.offsetTop-b.offsetTop);
        for (const n of nodes) if (n.offsetTop + n.offsetHeight > st + 1) {
            const m = (n.innerText||'').match(/number (\\d+)/);
            return {mk: m?+m[1]:-1, off: Math.round(n.offsetTop - st)};
        }
        return null;
    })()"""

    # Scroll to the MIDDLE of history (a text marker at the top), not following.
    TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        c.dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
        c.scrollTop = Math.round(c.scrollHeight * 0.5);
        c.dispatchEvent(new Event('scroll', {bubbles:true}));
    })()""")
    sleep(0.6)
    before = TK.eval_js(s, MARKER)
    @test before !== nothing && before["mk"] > 0

    @testset "hiding a type holds the top marker" begin
        TK.eval_js(s, "(() => { ($CH).setKeyHidden('tool:read', true); })()")
        sleep(0.6)
        hid = TK.eval_js(s, MARKER)
        @test hid !== nothing
        @test hid["mk"] == before["mk"]                       # same marker → view held
        @test abs(Int(hid["off"]) - Int(before["off"])) <= 4  # same screen position
    end

    @testset "showing it again holds the top marker" begin
        TK.eval_js(s, "(() => { ($CH).setKeyHidden('tool:read', false); })()")
        sleep(0.6)
        shown = TK.eval_js(s, MARKER)
        @test shown !== nothing
        @test shown["mk"] == before["mk"]
        @test abs(Int(shown["off"]) - Int(before["off"])) <= 6
    end

    @test isempty(TK.js_errors(s))
end
