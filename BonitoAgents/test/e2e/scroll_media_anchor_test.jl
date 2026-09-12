# A tool can announce completion before its media metadata arrives. Its
# collapsed header may already have been measured and evicted by then.
# Switching that cached node to a media display must invalidate the header's
# height, and mounting the media must replace the estimate with its real size.
# Both the ResizeObserver and off-screen measurement skip unfinished bodies;
# completed static rows still retain their measurements for stable anchoring.
@testitem "e2e:scroll_media_anchor" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    mp4 = "/tmp/bt_e2e_scroll_media_$(getpid()).mp4"
    write(mp4, UInt8.((0:29999) .% 256))

    # Enough history follows the video to evict it in follow mode. It may
    # briefly render while streaming; that is how the stale header height was
    # recorded. Tool rows keep adjacent text events from coalescing.
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
        for i in 1:20
            push!(evs, TK.text("tail bubble number $(i) — a short line of prose"))
            push!(evs, TK.tool(kind = "read", title = "tail tool $(i)", id = "tail-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    s.agent_fn[] = media_agent

    pid = TK.new_chat(s; title = "MediaAnchor")
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "seeded bubbles rendered",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 5";
        timeout = 60) == true
    @test TK.wait_for(s, "transcript overflows",
        "(() => { const c=[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent); return !!c && c.scrollHeight > c.clientHeight + 800; })()";
        timeout = 20) == true

    CH = "[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent).__bt_chat"

    # The video's cached node, what `heights` says about it, and what it really
    # measures right now. `real` is only meaningful while the node is connected.
    VIDEO_PROBE = """(() => {
        const ch = $CH;
        for (const [idx, node] of ch.cache) {
            if (!node.querySelector || !node.querySelector('video')) continue;
            return { idx,
                     recorded:  ch.heights.get(idx) ?? null,
                     real:      node.isConnected ? node.offsetHeight : null,
                     connected: !!node.isConnected,
                     rendered:  ch.rendered.has(idx),
                     mime:      (node.dataset && node.dataset.showMime) || null,
                     loading:   !!node.querySelector('.bt-collapsable-loading'),
                     hasVideo:  !!node.querySelector('video'),
                     cls:       node.className,
                     est:       ch.EST_HEIGHT };
        }
        return null;
    })()"""

    @test TK.wait_for(s, "the video message is cached",
        "!!($VIDEO_PROBE)"; timeout = 30) == true
    # It must genuinely be OUT of the render window, or `recorded` is just the
    # live ResizeObserver value and the comparison below proves nothing.
    @test TK.wait_for(s, "the video scrolled out of the render window",
        "(() => { const p = $VIDEO_PROBE; return !!p && !p.rendered; })()";
        timeout = 30) == true
    offscreen = TK.eval_js(s, VIDEO_PROBE)
    @info "video measured OFF-SCREEN" offscreen

    # Scroll the video into the render window so it mounts for real. It sits in
    # the MIDDLE of the history, so walk up the transcript until the probe says
    # it is rendered rather than jumping to the top (which lands far past it).
    scroll_to!(frac) = TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
        c.scrollTop = Math.round(c.scrollHeight * $frac);
        c.dispatchEvent(new Event('scroll', {bubbles: true}));
        return true;
    })()""")
    for frac in 0.70:-0.05:0.05
        scroll_to!(frac)
        sleep(0.5)
        p = TK.eval_js(s, VIDEO_PROBE)
        p !== nothing && p["connected"] == true && p["real"] !== nothing && p["real"] > 0 && break
    end
    @test TK.wait_for(s, "the video mounted in the live column",
        "(() => { const p = $VIDEO_PROBE; return !!p && p.connected && p.real > 0; })()";
        timeout = 30) == true
    # Let the height correction settle before comparing.
    prev = nothing; live = nothing
    for _ in 1:40
        sleep(0.05)
        live = TK.eval_js(s, VIDEO_PROBE)
        if prev !== nothing && live !== nothing && live["real"] == prev["real"]
            break
        end
        prev = live
    end
    @info "video measured LIVE" live

    @testset "a recorded height never disagrees with the real one" begin
        @test live !== nothing && live["real"] > 0
        # The header's earlier measurement must not survive the switch to
        # media. A fully mounted video may already have a valid measurement.
        rec0 = offscreen["recorded"]
        rec0 === nothing || @info "off-screen entry survived" recorded=rec0 live=live["real"]
        @test rec0 === nothing || abs(Float64(rec0) - Float64(live["real"])) <= 4
        # Once the node really renders, the observer records the truth.
        @test live["recorded"] !== nothing
        @test abs(Float64(live["real"]) - Float64(live["recorded"])) <= 4

        # And that holds for EVERY entry, not just the video: whatever is in
        # the map must match the node it describes.
        bad = TK.eval_js(s, """(() => {
            const ch = $CH;
            const out = [];
            for (const [idx, h] of ch.heights) {
                const n = ch.cache.get(idx);
                if (!n || !n.isConnected || n.style.display === 'none') continue;
                if (Math.abs(n.offsetHeight - h) > 4) out.push({idx, recorded: h, real: n.offsetHeight});
            }
            return out;
        })()""")
        isempty(bad) || @info "heights entries disagreeing with their nodes" bad
        @test isempty(bad)
    end

    rm(mp4; force = true)
    s.agent_fn[] = S.default_agent
    @test isempty(TK.js_errors(s))
end
