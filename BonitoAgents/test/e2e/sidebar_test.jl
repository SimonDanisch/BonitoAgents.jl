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
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit

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
            had = TK.eval_js(server, "document.querySelectorAll('.bt-proj-thumb').length")
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
                "document.querySelectorAll('.bt-proj-thumb').length > $(had)"; timeout = 60) == true
            # …and it is the real attachment, decoded — not a broken <img>.
            @test TK.wait_for(server, "the icon image decodes",
                """(() => { const i = document.querySelector('.bt-proj-thumb');
                    return !!(i && i.complete && i.naturalWidth > 0); })()"""; timeout = 20) == true
            TK.screenshot(server, joinpath(tempdir(), "sidebar_image_icon.png"))
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
