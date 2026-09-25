# The sidebar's "Open chats" list: what must survive, and what must update.
#
# The list body is a reactive `map` over `chat_signal`, `projects` and
# `workers`, so ANY structural notify re-renders the whole subtree — every
# entry, every per-chat file tree. Bonito does not diff observable content
# (see Bonito's AGENTS.md §5), so this is a full tear-down and re-mount, and
# the cost grows with the number of open chats rather than with the change.
# `state.workers` alone notifies on every worker reconnect.
#
# That churn is invisible until something stateful lives inside a row — which
# it does: a per-chat file tree with expanded folders. The existing code
# already works around it by caching the tree components in a `Dict` OUTSIDE
# the map and re-applying `.bt-tree-open` from `tree.active[]` on each render.
# This test pins the contract directly, so the workaround can be replaced by
# stable per-entry instances + `KeyedList` (the pattern used for chat panes in
# the same file) without guessing what it protected.
#
# The in-place paths are deliberately covered too, because they are what makes
# the rebuild unnecessary in the first place: navigation toggles
# `.bt-side-active` from JS on `data-project-id`, the status LED is rewritten
# by `status_obs`, and ✕ is a delegated handler on the aside.
@testitem "e2e:sidebar" tags = [:e2e] begin
    import BonitoAgents as BT
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit

    parseInt_px(v) = (m = match(r"^([0-9.]+)px$", String(v)); m === nothing ? -1.0 : parse(Float64, m[1]))
    ITEMS = ".bt-side-item[data-project-id]:not([data-project-id=''])"
    # Mark every chat row; a rebuilt row loses the mark.
    stamp = """(() => { let n = 0;
        document.querySelectorAll($(repr(ITEMS))).forEach(e => { e.dataset.keep = '1'; n++; });
        const l = document.querySelector('.bt-side-list'); if (l) l.dataset.keep = '1';
        return n; })()"""
    kept = """(() => {
        const l = document.querySelector('.bt-side-list');
        let k = 0, t = 0;
        document.querySelectorAll($(repr(ITEMS))).forEach(e => { t++; if (e.dataset.keep === '1') k++; });
        return [l && l.dataset.keep === '1' ? 1 : 0, k, t]; })()"""
    active_pid = "(document.querySelector('.bt-side-item.bt-side-active')||{dataset:{}}).dataset.projectId"

    server = TK.dev_server(agent = _ -> [TK.text("ok"), TK.end_turn()])
    try
        TK.open_browser(server)
        a = TK.new_chat(server; cwd = mktempdir(), title = "alpha")
        b = TK.new_chat(server; cwd = mktempdir(), title = "beta")
        sleep(1.5)

        @testset "both chats are listed" begin
            @test TK.wait_for(server, "two chat rows",
                "document.querySelectorAll($(repr(ITEMS))).length >= 2"; timeout = 30) == true
        end

        @testset "navigation moves the highlight without rebuilding the list" begin
            @test TK.eval_js(server, stamp) >= 2
            TK.eval_js(server, "document.querySelector($(repr(ITEMS))).click(); true")
            sleep(1.0)
            # The highlight is toggled from JS on `data-project-id` — no
            # re-render is needed, and none may happen.
            @test TK.eval_js(server, active_pid) in (a, b)
            @test TK.eval_js(server, kept) == Any[1, 2, 2]
        end

        @testset "a turn does not rebuild the list" begin
            # THE regression this file exists for. A reply arriving must not
            # tear down and re-mount every row: rows carry state (an expanded
            # file tree) and re-mounting is O(open chats) per turn.
            @test TK.eval_js(server, stamp) >= 2
            TK.send_message(server, "hello")
            @test TK.wait_for(server, "the reply rendered",
                "(document.body.innerText||'').includes('ok')"; timeout = 60) == true
            sleep(1.5)
            @test TK.eval_js(server, kept) == Any[1, 2, 2]
        end

        @testset "an open file tree stays open across a structural change" begin
            hint = "document.querySelector('.bt-side-chat .bt-side-tree-hint')"
            if TK.eval_js(server, "!!$(hint)") == true
                TK.eval_js(server, "$(hint).click(); true")
                @test TK.wait_for(server, "the tree opened",
                    "!!document.querySelector('.bt-side-chat.bt-tree-open')"; timeout = 20) == true
                TK.send_message(server, "again")
                sleep(2.0)
                @test TK.eval_js(server,
                    "!!document.querySelector('.bt-side-chat.bt-tree-open')") == true
            end
        end

        @testset "a chat that has shown an image wears it as its icon" begin
            # The identicon is the fallback, not the identity: a plot or a
            # screenshot is what makes a row findable in a list. Same composer
            # path `e2e:overview` uses to give a dashboard card its thumbnail.
            had = TK.eval_js(server, "document.querySelectorAll('.bt-proj-icon-img').length")
            TK.eval_js(server, """(() => {
                const b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
                const bin = atob(b64); const bytes = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                const file = new File([bytes], 'side-thumb.png', {type: 'image/png'});
                const m = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent);
                m.__bt_chat.attachAddBlob(file, file.type, file.name);
                return true; })()""")
            @test TK.wait_for(server, "thumb queued in the composer",
                "document.querySelectorAll('.bt-attachment-thumb').length >= 1"; timeout = 10) == true
            TK.send_message(server, "look at this")
            @test TK.wait_for(server, "the row wears the image",
                "document.querySelectorAll('.bt-proj-icon-img').length > $(had)"; timeout = 60) == true
            # …and it is the real attachment, decoded — not a broken <img>.
            @test TK.wait_for(server, "the icon image decodes",
                """(() => { const i = document.querySelector('.bt-proj-icon-img .bt-proj-thumb');
                    return !!(i && i.complete && i.naturalWidth > 0); })()"""; timeout = 20) == true
            # Every icon wears the worker's initials as the same badge, picture
            # or identicon: which machine a chat runs on is always readable.
            worker = only(values(server.h.state.workers[]))
            tags = TK.eval_js(server, "[...document.querySelectorAll('.bt-side-item[data-project-id] .bt-proj-tag')].map(e => e.textContent)")
            @test !isempty(tags) && all(==(BT.worker_initials(worker)), tags)
            @test TK.eval_js(server, "document.querySelectorAll('.bt-side-item[data-project-id] .bt-proj-icon').length") == length(tags)
            # Hovering an icon names the worker in full, then the folder.
            titles = TK.eval_js(server, "[...document.querySelectorAll('.bt-side-item[data-project-id] .bt-proj-icon')].map(e => e.title)")
            @test all(startswith(worker.name * " · "), titles)
            TK.screenshot(server, joinpath(tempdir(), "sidebar_image_icon.png"))
        end

        @testset "icons wear the worker's ring and pulse while working, no dot" begin
            # Machine = a ring in the worker's fixed colour; liveness = the icon
            # pulses during a turn and greys out when the worker is down. Idle
            # is plain. The old presence LED is gone.
            @test TK.eval_js(server, "document.querySelectorAll('.bt-side-led').length") == 0
            wrap = "[...document.querySelectorAll('.bt-side-item.bt-side-active .bt-side-icon-wrap')].find(e => e.offsetParent)"
            @test TK.wait_for(server, "the open chat's icon is online",
                "!!$(wrap)?.classList.contains('bt-glow-online')"; timeout = 20) == true
            ring = TK.eval_js(server, """(() => {
                const cs = getComputedStyle($(wrap));
                const icon = getComputedStyle($(wrap).querySelector('.bt-proj-icon'));
                return {worker: cs.getPropertyValue('--bt-worker').trim(),
                        border: cs.borderTopWidth, shadow: icon.boxShadow,
                        ringColor: icon.backgroundColor, pad: icon.paddingTop,
                        thumbRadius: getComputedStyle($(wrap).querySelector('.bt-proj-thumb')).borderTopLeftRadius,
                        badgeColor: getComputedStyle($(wrap).querySelector('.bt-proj-tag')).backgroundColor};
            })()""")
            @test startswith(ring["worker"], "oklch(")
            # The ring is the tile's own BACKGROUND with the picture inset and
            # rounded tighter, not a second shape sharing the picture's curved
            # edge — two shapes on one curve are each anti-aliased against it and
            # smear the picture's colour along the corner. Idle draws no shadow.
            @test parseInt_px(ring["border"]) == 0
            @test ring["shadow"] == "none"
            @test parseInt_px(ring["pad"]) > 0
            @test parseInt_px(ring["thumbRadius"]) > 0
            # The badge wears the machine's colour too — exactly the ring's, so
            # the two read as one identity.
            @test ring["badgeColor"] == ring["ringColor"]
            # Every chat on this worker shares the colour.
            @test TK.eval_js(server, """(() => {
                const wraps = [...document.querySelectorAll('.bt-side-item[data-project-id] .bt-side-icon-wrap')].filter(e => e.offsetParent);
                return [...new Set(wraps.map(e => getComputedStyle(e).getPropertyValue('--bt-worker').trim()))];
            })()""") == [ring["worker"]]
            # A turn in flight breathes, then settles; only the wrapper's class moves.
            server.agent_fn[] = _ -> [TK.delay(2500), TK.text("done"), TK.end_turn()]
            TK.eval_js(server, "window.__glowIcon = $(wrap).querySelector('.bt-proj-icon'); true")
            TK.send_message(server, "glow")
            @test TK.wait_for(server, "the icon pulses while the agent works",
                "!!$(wrap)?.classList.contains('bt-glow-active')"; timeout = 20) == true
            @test TK.eval_js(server, "getComputedStyle($(wrap).querySelector('.bt-proj-icon')).animationName") == "bt-icon-glow"
            TK.screenshot(server, joinpath(tempdir(), "sidebar_ring_glow.png"))
            @test TK.wait_for(server, "and settles when the turn ends",
                "!!$(wrap)?.classList.contains('bt-glow-online')"; timeout = 30) == true
            @test TK.eval_js(server, "$(wrap).querySelector('.bt-proj-icon') === window.__glowIcon")
            server.agent_fn[] = _ -> [TK.text("ok"), TK.end_turn()]
        end

        @testset "image identity survives new output and source deletion; right-click sets it" begin
            dir = mktempdir()
            cwd = mktempdir()
            red = joinpath(dir, "identity-red.svg")
            blue = joinpath(dir, "identity-blue.svg")
            write(red, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"73\" height=\"41\"><rect width=\"73\" height=\"41\" fill=\"red\"/></svg>")
            write(blue, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"97\" height=\"53\"><rect width=\"97\" height=\"53\" fill=\"blue\"/></svg>")
            menuitem = "document.querySelector('.bt-chat-icon-menu [role=menuitem]')"
            visible = "[...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent)"
            rightclick(target) = TK.eval_js(server, "$(target).dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, cancelable:true, clientX:420, clientY:300})); true")
            try
                server.agent_fn[] = prompt -> begin
                    path = occursin("second", prompt) ? blue : red
                    [TK.tool(; kind="other", tool_name="bt_show", title=basename(path),
                        content=[TK.text_block("shown: $path (image/svg+xml, 120B)")]),
                     TK.text("picture ready"), TK.end_turn()]
                end
                pid = TK.new_chat(server; cwd, title="recognizable chat")
                icon = ".bt-side-item[data-project-id=\"$pid\"] .bt-proj-thumb"
                thumb = ".bt-ov-card[data-project-id=\"$pid\"] .bt-ov-thumb"
                decoded(width) = "(() => { const i=document.querySelector($(repr(icon))); return !!i && i.complete && i.naturalWidth === $width; })()"
                TK.send_message(server, "first picture")
                @test TK.wait_for(server, "worker image becomes a decoded icon", decoded(73); timeout=60)
                original = TK.eval_js(server, "document.querySelector($(repr(icon))).src")
                TK.eval_js(server, "window.__recognitionIcon = document.querySelector($(repr(icon))); true")
                rm(red)  # the icon must be independent of the worker's original
                TK.send_message(server, "second picture")
                shown = "[...$(visible).querySelectorAll('.bt-media')].find(i => i.naturalWidth === 97)"
                @test TK.wait_for(server, "new image shown in chat", "!!$(shown)"; timeout=60)
                @test TK.eval_js(server, "document.querySelector($(repr(icon))) === window.__recognitionIcon")
                @test TK.eval_js(server, "document.querySelector($(repr(icon))).src") == original
                @test TK.eval_js(server, decoded(73))

                # Right-click on the new picture in the chat: its one action
                # makes it the icon. Opening the menu alone changes nothing.
                rightclick(shown)
                @test TK.wait_for(server, "the picture's menu opens", "!!$(menuitem)"; timeout=10)
                menu = TK.eval_js(server, """(() => {
                    const b = $(menuitem);
                    const r = b.getBoundingClientRect();
                    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
                    return {label: b.textContent,
                            onscreen: r.width > 0 && r.height > 0 && r.left >= 0 && r.top >= 0 &&
                                      r.right <= innerWidth && r.bottom <= innerHeight,
                            hit: hit === b ? 'menu' : (hit ? hit.tagName + '.' + hit.className : 'nothing'),
                            font: getComputedStyle(b).fontFamily,
                            chatFont: getComputedStyle($(visible)).fontFamily};
                })()""")
                @test menu["label"] == "Set as chat icon"
                @test menu["onscreen"] == true
                @test menu["hit"] == "menu"
                @test menu["font"] == menu["chatFont"]  # styled like the chat it floats over
                TK.screenshot(server, joinpath(tempdir(), "chat_icon_menu.png"))
                @test TK.eval_js(server, "document.querySelector($(repr(icon))).src") == original
                TK.eval_js(server, "$(menuitem).click(); true")
                @test TK.wait_for(server, "the picked picture becomes the icon", decoded(97); timeout=30)
                @test TK.eval_js(server, "!document.querySelector('.bt-chat-icon-menu')")
                @test TK.eval_js(server, "document.querySelector($(repr(icon))).src") != original

                # A user attachment is picked the same way.
                server.agent_fn[] = _ -> [TK.text("ok"), TK.end_turn()]
                TK.eval_js(server, """(() => {
                    const b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
                    const bin = atob(b64); const bytes = new Uint8Array(bin.length);
                    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                    const file = new File([bytes], 'identity-dot.png', {type: 'image/png'});
                    $(visible).__bt_chat.attachAddBlob(file, file.type, file.name);
                    return true; })()""")
                @test TK.wait_for(server, "attachment queued in the composer",
                    "document.querySelectorAll('.bt-attachment-thumb').length >= 1"; timeout=10)
                TK.send_message(server, "and this one")
                attached = "[...$(visible).querySelectorAll('.bt-user-att-img')].find(i => i.complete && i.naturalWidth === 1)"
                @test TK.wait_for(server, "attachment shown in chat", "!!$(attached)"; timeout=60)
                rightclick(attached)
                @test TK.wait_for(server, "the attachment's menu opens", "!!$(menuitem)"; timeout=10)
                TK.eval_js(server, "$(menuitem).click(); true")
                @test TK.wait_for(server, "the attachment becomes the icon", decoded(1); timeout=30)
                chosen = TK.eval_js(server, "document.querySelector($(repr(icon))).src")

                # Both sources are gone; the identity is a copy and survives a reload.
                rm(blue)
                rm(joinpath(cwd, ".bt-attachments"); recursive=true)
                TK.navigate(server, "/?pid=$pid")
                @test TK.wait_for(server, "chosen picture decodes after reload without its source", decoded(1); timeout=60)
                @test TK.eval_js(server, "document.querySelector($(repr(icon))).src") == chosen

                TK.to_dashboard(server)
                @test TK.wait_for(server, "overview shares the same identity",
                    "document.querySelector($(repr(thumb * " img")))?.src === $(repr(chosen))"; timeout=20)
                TK.open_chat(server, pid)
                @test TK.wait_for(server, "identity survives reopening", decoded(1); timeout=30)
                TK.screenshot(server, joinpath(tempdir(), "sidebar_persistent_icon.png"))
            finally
                rm(dir; recursive=true, force=true)
                server.agent_fn[] = _ -> [TK.text("ok"), TK.end_turn()]
            end
        end

        @testset "the rail is resizable, and remembers it" begin
            # Reported as "one cant even resize the sidebar to get some more
            # space". The handle is a sibling of the aside (the aside is the
            # scroll container), writes `--bt-side-w`, and persists it.
            @test TK.eval_js(server, "!!document.querySelector('.bt-side-resize')") == true
            w0 = TK.eval_js(server,
                "Math.round(document.querySelector('.bt-sidebar').getBoundingClientRect().width)")
            # A real pointer drag: down on the strip, move right, up.
            TK.eval_js(server, """(() => {
                const el = document.querySelector('.bt-side-resize');
                const r = el.getBoundingClientRect();
                const opt = (x) => ({bubbles: true, cancelable: true, pointerId: 1,
                                     pointerType: 'mouse', clientX: x,
                                     clientY: Math.round(r.top + r.height / 2)});
                el.dispatchEvent(new PointerEvent('pointerdown', opt(Math.round(r.left + 2))));
                el.dispatchEvent(new PointerEvent('pointermove', opt(Math.round(r.left + 120))));
                el.dispatchEvent(new PointerEvent('pointerup',   opt(Math.round(r.left + 120))));
            })()""")
            @test TK.wait_for(server, "the rail got wider",
                "document.querySelector('.bt-sidebar').getBoundingClientRect().width > $(w0) + 60";
                timeout = 10) == true
            stored = TK.eval_js(server, "localStorage.getItem('bt-sidebar-width')")
            @test stored !== nothing
            @test parse(Float64, String(stored)) > w0 + 60
            # Clamped, not unbounded: a drag past the cap stops at 560.
            TK.eval_js(server, """(() => {
                const el = document.querySelector('.bt-side-resize');
                const r = el.getBoundingClientRect();
                const opt = (x) => ({bubbles: true, cancelable: true, pointerId: 1,
                                     pointerType: 'mouse', clientX: x,
                                     clientY: Math.round(r.top + r.height / 2)});
                el.dispatchEvent(new PointerEvent('pointerdown', opt(Math.round(r.left + 2))));
                el.dispatchEvent(new PointerEvent('pointermove', opt(4000)));
                el.dispatchEvent(new PointerEvent('pointerup',   opt(4000)));
            })()""")
            @test TK.wait_for(server, "width clamps at the cap",
                "document.querySelector('.bt-sidebar').style.getPropertyValue('--bt-side-w') === '560px'";
                timeout = 10) == true
            # Double-click resets to the breakpoint default.
            TK.eval_js(server, "document.querySelector('.bt-side-resize').dispatchEvent(new MouseEvent('dblclick', {bubbles: true})); true")
            @test TK.wait_for(server, "reset to the default width",
                "!document.querySelector('.bt-sidebar').style.getPropertyValue('--bt-side-w') && " *
                "Math.abs(document.querySelector('.bt-sidebar').getBoundingClientRect().width - $(w0)) <= 2";
                timeout = 10) == true
            @test TK.eval_js(server, "localStorage.getItem('bt-sidebar-width')") === nothing
            # The collapsed rail has nothing to resize — the handle goes away.
            TK.eval_js(server, "document.querySelector('.bt-side-collapse').click(); true")
            @test TK.wait_for(server, "handle hidden in the icon rail",
                "document.querySelector('.bt-side-resize').offsetParent === null"; timeout = 10) == true
            TK.eval_js(server, "document.querySelector('.bt-side-collapse').click(); true")
            @test TK.wait_for(server, "handle back",
                "document.querySelector('.bt-side-resize').offsetParent !== null"; timeout = 10) == true
        end

        @testset "✕ closes a chat" begin
            before = TK.eval_js(server, "document.querySelectorAll($(repr(ITEMS))).length")
            TK.eval_js(server, "document.querySelector($(repr(ITEMS)) + ' .bt-side-close').click(); true")
            @test TK.wait_for(server, "one row fewer",
                "document.querySelectorAll($(repr(ITEMS))).length === $(before - 1)";
                timeout = 30) == true
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
