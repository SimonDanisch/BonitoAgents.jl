# Media above the reader: a `bt_show` video's row arrives as a short header and
# grows to the video's size once its body mounts, which happens after the row
# is in the page. Scrolling UP loads such rows above the viewport, so the
# growth lands above the reader, and the view must not move with it.
@testitem "e2e:scroll_media_anchor" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    mp4 = "/tmp/bt_e2e_scroll_media_$(getpid()).mp4"
    write(mp4, UInt8.((0:29999) .% 256))

    # The video sits in the middle, with enough history after it that the
    # block opening at the newest rows does not hold it. Tool rows keep
    # adjacent text events from coalescing.
    function media_agent(prompt)
        occursin("seed", lowercase(prompt)) || return [TK.text("echo: $(prompt)")]
        evs = Any[]
        for i in 1:20
            push!(evs, TK.text("lead bubble number $(i) — a short line of prose"))
            push!(evs, TK.tool(kind = "read", title = "lead tool $(i)", id = "lead-$(i)"))
        end
        push!(evs, TK.tool(; kind = "other", tool_name = "bt_show", title = "clip.mp4",
                             content = [TK.text_block("shown: $(mp4) (video/mp4, 30000B)")],
                             id = "vid-anchor"))
        for i in 1:40
            push!(evs, TK.text("tail bubble number $(i) — a short line of prose"))
            push!(evs, TK.tool(kind = "read", title = "tail tool $(i)", id = "tail-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    s.agent_fn[] = media_agent

    pid = TK.new_chat(s; title = "MediaAnchor")
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "the turn",
        "[...document.querySelectorAll('.bt-agent-msg')].some(e => e.offsetParent && (e.innerText||'').includes('tail bubble number 40'))";
        timeout = 60) == true
    # Reopen: the pane starts from its newest rows, without the video.
    TK.navigate(s, "/")
    TK.open_chat(s, pid)
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    C = "document.querySelector($(TK.json(P * ".bt-messages")))"
    CH = "$C.__bt_chat"
    @test TK.wait_for(s, "the newest rows", "!!$CH && $CH.order.length > 0"; timeout = 20) == true
    TK.eval_js(s, "(() => { const ch = $CH; ch.setFollowMode(false); ch.cancelPendingScroll(); return true; })()")
    @test TK.eval_js(s, "!$C.querySelector('[data-msg-id*=\"vid-anchor\"]')") == true

    TOP_PROBE = """(() => { const c = $C;
        for (const n of c.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg')) {
            if (n.offsetParent === null) continue;
            if (n.offsetTop + n.offsetHeight > c.scrollTop + 4)
                return {text: (n.innerText||'').replace(/\\s+/g,' ').slice(0, 40),
                        off: Math.round(n.offsetTop - c.scrollTop)};
        }
        return null; })()"""
    VIDEO = "$C.querySelector('[data-msg-id*=\"vid-anchor\"]')"

    @testset "loading and mounting the video above the reader keeps the view" begin
        before = nothing
        for _ in 1:20
            TK.eval_js(s, "!!$VIDEO") && break
            # To the top of the block, what is read there, and the load, in
            # one synchronous step (the offscreen renderer fires no scroll
            # event for a programmatic write, hence the dispatch).
            before, plo = TK.eval_js(s, """(() => { const c = $C; c.scrollTop = 0;
                const top = $TOP_PROBE, plo = $CH.plo;
                c.dispatchEvent(new Event('scroll'));
                return [top, plo]; })()""")
            TK.wait_for(s, "older rows", "$CH.plo < $(plo)"; timeout = 10)
        end
        @test TK.eval_js(s, "!!$VIDEO") == true
        # The video's row is above the reader; its body mounts and grows.
        @test TK.wait_for(s, "the video mounted",
            "(() => { const v = $VIDEO; const el = v && v.querySelector('video'); return !!el && el.offsetHeight > 0; })()";
            timeout = 30) == true
        sleep(0.5)
        # The row that was read is where it was. Not "the top row now": the
        # rows loaded above end just inside the viewport (the gap the block
        # had above its first row), so the video's last pixels show there.
        @test before !== nothing
        after = TK.eval_js(s, """(() => { const c = $C;
            const e = [...c.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg')]
                .find(e => (e.innerText||'').replace(/\\s+/g,' ').slice(0, 40) === $(TK.json(before["text"])));
            return e ? Math.round(e.offsetTop - c.scrollTop) : null; })()""")
        @test after !== nothing
        @test abs(Int(after) - Int(before["off"])) <= 3
        # It really was above: the video row starts above the viewport.
        @test TK.eval_js(s, "$VIDEO.offsetTop < $C.scrollTop") == true
    end

    rm(mp4; force = true)
    s.agent_fn[] = S.default_agent
    @test isempty(TK.js_errors(s))
end
