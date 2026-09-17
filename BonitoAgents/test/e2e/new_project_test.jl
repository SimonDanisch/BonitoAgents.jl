# Creating a project is a WORKER-ONLY flow — this pins the four ways it wasn't.
#
# The picker was redesigned from a breadcrumb/address-bar + separate Name field
# into a SINGLE editable path text field (`.bt-picker-path`) that IS the
# selection: browsing the tree or the ↑ button just writes new values into it,
# and Create reads it directly. The old "+ New folder" / "Choose" / "Name"
# steps are gone; a path that doesn't exist yet ("type /newname to create it")
# is created on the WORKER at Create time via the `ensure_dir` RPC.
#
# Black-box throughout — the worker's working directory is read from the card's
# own meta line, and the picker's selection from the path field, so nothing here
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

    # What the picker is currently pointing at: the path field's value. This IS
    # the selection — no breadcrumb to read.
    const PICKER_PATH_JS = """(() => {
        const i = [...document.querySelectorAll('.bt-picker-path')].filter(e => e && e.offsetParent !== null)[0];
        return i ? (i.value || '') : '';
    })()"""

    # The existence note the picker stamps under the path: ".bt-picker-exist
    # .bt-picker-exist-missing" (will be created) / ".bt-picker-exist-file"
    # (that's a file). Cosmetic — Create always asks the worker either way.
    const EXIST_NOTE_JS = """(() => {
        const n = [...document.querySelectorAll('.bt-picker-exist')].filter(e => e && e.offsetParent !== null)[0];
        return n ? (n.innerText || '').trim() : '';
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
        document.querySelectorAll('.bt-form input, .bt-form select')
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
    # fixed interval and flips the form straight back shut. Check first, click
    # once, wait; only retry if nothing opened, which still covers the
    # cold-mount race where Bonito wires the handler after the first synthetic
    # click lands.
    const PICKER_OPEN_JS = "[...document.querySelectorAll('.bt-picker-path')].some(e => e && e.offsetParent)"
    const CARD_BTN_JS = """[...document.querySelectorAll('button')].some(b =>
        b.offsetParent && (b.innerText || '').trim() === '+ Project')"""
    function open_card_picker!(s; tries = 5)
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

    # Type `path` into the path field (dispatches an input event so the picker
    # round-trips it) and wait for the field to actually carry it.
    function type_path!(s, path)
        TK.set_input(s, ".bt-picker-path", path)
        TK.wait_for(s, "path field taken the typed value",
            "$(PICKER_PATH_JS) === $(TK.json(path))"; timeout = 20) === true ||
            error("type_path!: field did not settle on $path")
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
            @test TK.wait_for(server, "picker path field seeded at the worker root",
                "$(PICKER_PATH_JS) === $(TK.json(worker_root))"; timeout = 30) == true
        end

        @testset "form text is not white-on-white" begin
            @test TK.eval_js(server, UNREADABLE_JS) == ""
            # The picker's path field specifically carries the app's text token
            # rather than whatever the UA's `fieldtext` resolves to.
            @test TK.eval_js(server,
                "getComputedStyle(document.querySelector('.bt-picker-path')).color") ==
                "rgb(15, 23, 42)"
        end

        @testset "Create takes exactly the typed path (path field IS the selection)" begin
            # No "Choose"/breadcrumb to commit through: typing a path then
            # clicking Create must open THAT folder. Nothing else to resolve.
            sub = worker_root * "/e2e-np-typed"
            type_path!(server, sub)
            TK.click_text(server, "Create")
            @test wait_chat_titled(server, "e2e-np-typed") == true
            @test err_text(server) == ""
        end

        @testset "a typed path that doesn't exist is CREATED on the worker" begin
            # The old testset asserted the WORKER REFUSED a missing folder with
            # "No such folder". The redesign inverted that: a missing path is
            # now the "type /newname to create it" case, materialised via the
            # `ensure_dir` RPC (mkpath) before import — so Create makes the
            # folder and opens a chat for it.
            TK.to_dashboard(server)
            @test open_card_picker!(server)
            fresh = worker_root * "/brand-new-9f3a"
            type_path!(server, fresh)
            # Cosmetic note: the picker stamps that the path will be created.
            @test TK.wait_for(server, "picker flags the path as creatable",
                "(() => { const n = [...document.querySelectorAll('.bt-picker-exist-missing')].filter(e => e && e.offsetParent !== null); return n.length > 0; })()";
                timeout = 30) == true
            TK.click_text(server, "Create")
            @test wait_chat_titled(server, "brand-new-9f3a") == true
            @test err_text(server) == ""
            # It exists ON DISK (the folder a user sees in their editor).
            @test isdir(fresh)
        end

        @testset "a path that is a FILE is refused BY THE WORKER" begin
            # `ensure_dir` deliberately refuses a path that exists as a
            # non-directory (mkpath would silently create a sibling). The
            # rejection surfaces on the card's error line and no chat opens.
            TK.to_dashboard(server)
            @test open_card_picker!(server)
            file_path = worker_root * "/some-file-9f3a.txt"
            write(file_path, "not a folder")
            type_path!(server, file_path)
            @test TK.wait_for(server, "picker flags the path as a file",
                "(() => { const n = [...document.querySelectorAll('.bt-picker-exist-file')].filter(e => e && e.offsetParent !== null); return n.length > 0; })()";
                timeout = 30) == true
            TK.click_text(server, "Create")
            @test TK.wait_for(server, "worker rejected the non-directory path",
                """(() => {
                    const e = [...document.querySelectorAll('.bt-error')].find(e => e.offsetParent);
                    return !!e && (e.innerText || '').includes('not a directory');
                })()"""; timeout = 30) == true
            # Nothing was registered: no chat opened for that path.
            @test TK.eval_js(server, """(() => [...document.querySelectorAll('.bt-side-item')]
                .some(e => (e.innerText||'').includes('some-file-9f3a')))()""") === false
            TK.click_text(server, "Cancel")
        end
    finally
        close(server)
    end
end
