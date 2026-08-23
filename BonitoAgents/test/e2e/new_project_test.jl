# Creating a project is a WORKER-ONLY flow — this pins the four ways it wasn't.
#
# Reported against the "+ Project" card, all four reproduced in a live page
# before the fix:
#
#   1. The picker opened at the worker's $HOME instead of its working directory
#      (`projects_root`, which BonitoWorker defaults to the pwd it was installed
#      from), so every create started by browsing down from /home/<user>.
#   2. Form text was WHITE ON WHITE. The page inherits `color-scheme: dark` from
#      the OS, so an `<input>` that sets a light `background` but no `color` got
#      the UA's `fieldtext` = white. You typed a folder/project name into an
#      invisible field. (`html:root { color-scheme: light }` + explicit `color`.)
#   3. Create refused the folder the breadcrumb was pointing at — only the
#      Choose button ever wrote `selected` — with "Pick a folder on the worker
#      first" about that very folder.
#   4. The dashboard form's Name was mandatory in practice: leaving it blank
#      came back as "Project name must not be empty (folder has no basename?)".
#
# Its own dev_server, deliberately: the assertion in (1) is about the state a
# worker card is in when it is FIRST used, and the shared soak server's card has
# been navigated by whatever ran before it.
#
# Black-box throughout — the worker's working directory is read from the card's
# own meta line, and the picker's location from the breadcrumb, so nothing here
# knows a server-side path.
@testitem "e2e:new_project" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    using Test

    agent_script(_p) = [TK.text("hi"), TK.end_turn()]

    # Worker's working directory as the dashboard itself renders it: the last
    # " · " segment of the worker card's meta line (see `worker_subtitle`).
    const WORKER_ROOT_JS = """(() => {
        const m = document.querySelector('.bt-card-meta');
        if (!m) return "";
        const parts = (m.innerText || '').split(' · ');
        return parts[parts.length - 1].trim();
    })()"""

    # Where the VISIBLE picker is currently standing. `address_bar` stamps the
    # cumulative full path on each breadcrumb segment's `title`, so the last
    # segment's title IS the current folder.
    const PICKER_PATH_JS = """(() => {
        const bar = [...document.querySelectorAll('.bt-addr-bar')].find(b => b.offsetParent !== null);
        if (!bar) return "";
        const segs = [...bar.querySelectorAll('.bt-addr-seg')];
        return segs.length ? (segs[segs.length - 1].getAttribute('title') || "") : "";
    })()"""

    # Visible form controls whose text colour equals the background they are
    # painted on — i.e. unreadable. Walks up for the first non-transparent
    # background so it catches inherit-through cases too, not just the one
    # element that happened to set `background` itself.
    const UNREADABLE_JS = """(() => {
        const effBg = el => {
            for (let n = el; n; n = n.parentElement) {
                const c = getComputedStyle(n).backgroundColor;
                if (c && c !== 'transparent' && c !== 'rgba(0, 0, 0, 0)') return c;
            }
            return 'rgb(255, 255, 255)';
        };
        const bad = [];
        document.querySelectorAll('.bt-form input, .bt-form select, .bt-picker-newname, .bt-addr-input')
            .forEach(el => {
                if (el.offsetParent === null) return;
                const cs = getComputedStyle(el);
                if (cs.color === effBg(el)) bad.push((el.className || el.tagName) + ':' + cs.color);
            });
        return bad.join(', ');
    })()"""

    err_text(s) = TK.eval_js(s, """(() => {
        const e = [...document.querySelectorAll('.bt-error')].find(e => e.offsetParent !== null);
        return e ? (e.innerText || '').trim() : ''; })()""")

    # "+ Project" is a TOGGLE (`picker_state` flips between this worker and ""),
    # so it must NOT go through `click_text_until`: that re-clicks blind on a
    # fixed interval and flips the form straight back shut, which is exactly how
    # this suite hung for 30s on a form a single click opens fine. (The
    # dashboard's "+ New project" IS idempotent — it assigns `which_form` — so
    # `click_text_until` is right for that one.) Check first, click once, wait;
    # only retry if nothing opened, which still covers the cold-mount race where
    # Bonito wires the handler after the first synthetic click lands.
    const PICKER_OPEN_JS = "[...document.querySelectorAll('.bt-picker-newname')].some(e => e.offsetParent)"
    const CARD_BTN_JS = """[...document.querySelectorAll('button')].some(b =>
        b.offsetParent && (b.innerText || '').trim() === '+ Project')"""
    function open_card_picker!(s; tries = 5)
        # `to_dashboard` only settles 0.6s, which isn't always enough for the
        # dashboard view to mount after a chat — a bare `click_text` then dies
        # with "no visible button labelled +Project" instead of waiting.
        TK.wait_for(s, "worker card on screen", CARD_BTN_JS; timeout = 30)
        for _ in 1:tries
            TK.eval_js(s, PICKER_OPEN_JS) === true && return true
            TK.click_text(s, "+ Project")
            for _ in 1:30                     # ~6s for the notify round-trip
                TK.eval_js(s, PICKER_OPEN_JS) === true && return true
                sleep(0.2)
            end
        end
        return false
    end

    # Make a fresh folder ON THE WORKER through the picker's "+ New folder"
    # (a `make_dir` RPC), then confirm the picker navigated into it.
    function new_folder!(s, name)
        TK.set_input(s, ".bt-picker-newname", name)
        TK.click_text(s, "+ New folder")
        @test TK.wait_for(s, "picker moved into $name",
            "$(PICKER_PATH_JS).endsWith($(TK.json("/" * name)))"; timeout = 20) == true
    end

    # Wait for the freshly created project's chat to be the open one.
    function wait_chat_titled(s, name)
        TK.wait_for(s, "chat for $name opened",
            """(() => {
                if (document.querySelector('.bt-error')) return true;
                const a = document.querySelector('.bt-side-item.bt-side-active');
                return !!a && (a.innerText || '').includes($(TK.json(name)));
            })()"""; timeout = 90)
    end

    server = TK.dev_server(agent = agent_script, name = "np-worker")
    try
        TK.open_browser(server)
        TK.to_dashboard(server)
        @test TK.wait_for(server, "worker card rendered",
            "!!document.querySelector('.bt-card-meta')"; timeout = 30) == true

        worker_root = String(TK.eval_js(server, WORKER_ROOT_JS))
        @test !isempty(worker_root)

        @testset "+ Project opens at the worker's working directory" begin
            @test open_card_picker!(server)
            @test TK.wait_for(server, "picker listed the worker root",
                "$(PICKER_PATH_JS) === $(TK.json(worker_root))"; timeout = 30) == true
        end

        @testset "form text is not white-on-white" begin
            @test TK.eval_js(server, UNREADABLE_JS) == ""
            # And the picker's name field specifically carries the app's text
            # token rather than whatever the UA's `fieldtext` resolves to.
            @test TK.eval_js(server,
                "getComputedStyle(document.querySelector('.bt-picker-newname')).color") ==
                "rgb(15, 23, 42)"
        end

        @testset "Create takes the folder the breadcrumb is showing" begin
            new_folder!(server, "e2e-np-card")
            # NO "Choose" click — that is the bug: navigating writes `cur`, only
            # Choose wrote `selected`, and Create read `selected`.
            TK.click_text(server, "Create")
            @test wait_chat_titled(server, "e2e-np-card") == true
            @test err_text(server) == ""
        end

        @testset "a typed path is respected without pressing Enter or Choose" begin
            # The address bar only committed `cur` on Enter. Type a path, then
            # click "+ New folder" (or Choose, or Create) and the bar went on
            # showing what you typed while every action used the PREVIOUS
            # folder — "new folder doesn't respect the path at all, even after
            # pressing Choose". Actions now read `picker_path`, which is the
            # bar's live text while it is being edited.
            #
            # Deliberately no Enter and no blur here: blur doesn't fire at all
            # in an offscreen renderer, so a fix that leaned on it would pass
            # by accident in a real window and still be wrong here.
            TK.to_dashboard(server)
            @test open_card_picker!(server)
            nested = worker_root * "/e2e-np-card/typed-parent"
            TK.click_until(server, ".bt-addr-icon-btn",
                "[...document.querySelectorAll('.bt-addr-input')].some(e => e.offsetParent)";
                timeout = 30)
            @test TK.eval_js(server, """(() => {
                const i = [...document.querySelectorAll('.bt-addr-input')].find(e => e.offsetParent);
                if (!i) return false;
                const set = Object.getOwnPropertyDescriptor(i.constructor.prototype, 'value').set;
                set.call(i, $(TK.json(worker_root * "/e2e-np-card")));
                i.dispatchEvent(new Event('input', {bubbles: true}));
                return true; })()""") === true
            sleep(1.0)
            TK.set_input(server, ".bt-picker-newname", "typed-parent")
            TK.click_text(server, "+ New folder")
            # It lands under the TYPED folder, and the bar drops back to
            # breadcrumbs pointing at what was actually created.
            @test TK.wait_for(server, "new folder under the typed path",
                "$(PICKER_PATH_JS) === $(TK.json(nested))"; timeout = 30) == true
        end

        @testset "a folder that isn't there is refused BY THE WORKER" begin
            # The breadcrumb is a free-text field, so Create can be handed a path
            # no `list_dir` ever produced. Nothing on the server can adjudicate
            # that — the folder would live on the worker — so the worker is
            # asked, and it is the worker that says no. Before this, the project
            # registered happily and every session bring-up then failed with an
            # inexplicable cwd.
            TK.to_dashboard(server)   # the previous create left us in its chat
            @test open_card_picker!(server)
            TK.click_until(server, ".bt-addr-icon-btn",
                "[...document.querySelectorAll('.bt-addr-input')].some(e => e.offsetParent)";
                timeout = 30)
            bogus = worker_root * "/definitely-not-here-9f3a"
            @test TK.eval_js(server, """(() => {
                const inp = [...document.querySelectorAll('.bt-addr-input')].find(e => e.offsetParent);
                if (!inp) return false;
                inp.focus();
                const set = Object.getOwnPropertyDescriptor(inp.constructor.prototype, 'value').set;
                set.call(inp, $(TK.json(bogus)));
                inp.dispatchEvent(new Event('input', {bubbles: true}));
                inp.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', keyCode: 13, bubbles: true}));
                return true; })()""") === true
            @test TK.wait_for(server, "picker took the typed path",
                "$(PICKER_PATH_JS) === $(TK.json(bogus))"; timeout = 20) == true
            TK.click_text(server, "Create")
            @test TK.wait_for(server, "worker rejected the missing folder",
                """(() => {
                    const e = [...document.querySelectorAll('.bt-error')].find(e => e.offsetParent);
                    return !!e && (e.innerText || '').includes('No such folder');
                })()"""; timeout = 30) == true
            # …and it named the WORKER, not a server path.
            @test occursin("np-worker", String(err_text(server)))
            # Nothing was registered: no chat opened for that folder.
            @test TK.eval_js(server, """(() => [...document.querySelectorAll('.bt-side-item')]
                .some(e => (e.innerText||'').includes('definitely-not-here-9f3a')))()""") === false
            TK.click_text(server, "Cancel")
        end

        @testset "New project form: a blank Name means the folder's name" begin
            TK.to_dashboard(server)
            TK.click_text_until(server, "+ New project",
                "[...document.querySelectorAll('.bt-np-name')].some(e => e.offsetParent)";
                timeout = 30)
            # This form seeds the picker from the worker's projects_root too.
            @test TK.wait_for(server, "form picker at the worker root",
                "$(PICKER_PATH_JS) === $(TK.json(worker_root))"; timeout = 30) == true
            @test TK.eval_js(server, UNREADABLE_JS) == ""

            new_folder!(server, "e2e-np-form")
            @test TK.eval_js(server, "document.querySelector('.bt-np-name').value") == ""
            TK.click_text(server, "Create")
            @test wait_chat_titled(server, "e2e-np-form") == true
            @test err_text(server) == ""
        end
    finally
        close(server)
    end
end
