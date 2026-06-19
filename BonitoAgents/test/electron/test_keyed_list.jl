# KeyedList: fine-grained list manager — a PURE Bonito component test.
#
# This test never used a fake transport (no agent, no ChatModel, no ACP): it
# mounts a minimal Bonito App exposing a `KeyedList` against a Julia-side
# Observable and asserts the contract directly in a real Electron DOM. So it
# stays a standalone component test (NOT on the TestKit chat harness — there's
# no chat involved), just made self-contained: its own Electron display, its own
# JS-eval/poll helpers, `@testset`/`@test`, a `window.__errs` sink, and a
# `try/finally close(disp)`.
#
# Contract under test: widgets that survive a list update keep their DOM node
# (identity preserved across diffs), and only the diff's inserts/removes/moves
# are applied. The identity property is the whole point of the abstraction — lose
# it and we'd be no better off than `map(items) do _; render_all() end`.

using Test
using Bonito, JSON
import ElectronCall

# Detect the live X socket so the headless Electron window can render (the same
# plumbing TestKit.ensure_display! does; this file doesn't use the chat harness).
if isempty(get(ENV, "DISPLAY", ""))
    socks = filter(s -> startswith(s, "X"), readdir("/tmp/.X11-unix"))
    isempty(socks) || (ENV["DISPLAY"] = ":" * first(sort(socks; rev = true))[2:end])
end

# Minimal widget: a paragraph with one Observable<String> binding. Stable
# per-instance identity (mutable struct + Observable field → object-id hash →
# unchanged across rebuilds when the same instance is reused).
mutable struct LabelCard
    id    :: String
    label :: Observable{String}
end

function Bonito.jsrender(session::Bonito.Session, c::LabelCard)
    # Encode the test id into the class — Bonito/Hyperscript kwargs can't
    # natively express `data-test-id`. A class selector is enough for the test.
    Bonito.jsrender(session, Bonito.DOM.div(c.label; class = "kl-card kl-id-$(c.id)"))
end

@testset "KeyedList — widget identity preserved across list diffs" begin
    items_obs = Observable(LabelCard[])
    cards = Dict{String, LabelCard}()
    make_card(id, label) = get!(() -> LabelCard(id, Observable(label)), cards, id)

    app = Bonito.App() do session
        Bonito.DOM.div(Bonito.KeyedList(items_obs);
            id = "kl-container",
            style = Bonito.Styles("display" => "flex", "flex-direction" => "column"))
    end

    disp = Bonito.use_electron_display(;
        devtools = false,
        options  = Dict{String,Any}("show" => false, "width" => 800, "height" => 600),
        electron_args = ["--ozone-platform=x11"])
    try
        display(disp, app)
        sleep(0.8)
        run(disp.window, """
            window.__errs = [];
            window.addEventListener('error', e => window.__errs.push(String(e.message)));
        """)

        evjs(code::AbstractString) = run(disp.window, code)
        # Hard-deadline poll: a true hang fails here rather than wedging the suite.
        function wait_js(predicate::AbstractString; timeout::Real = 3.0, interval::Real = 0.05)
            deadline = time() + timeout
            while time() < deadline
                try
                    evjs("(() => { return ($predicate); })()") === true && return true
                catch; end
                sleep(interval)
            end
            return false
        end

        # How the list looks in the DOM right now — id pulled from "kl-id-<id>".
        dom_ids() = evjs("""
            Array.from(document.querySelectorAll('.kl-card')).map(el => {
                const m = Array.from(el.classList).find(c => c.startsWith('kl-id-'));
                return m ? m.slice('kl-id-'.length) : null; })
        """)
        # Stable-node test: tag a node with a JS property; if the same node is
        # reused across a diff, the tag survives.
        tag_node!(id, tag) = evjs("""(() => {
            const el = document.querySelector('.kl-id-$id');
            if (el) el.__test_tag = $(JSON.json(tag)); return !!el; })()""")
        read_tag(id) = evjs("""(() => {
            const el = document.querySelector('.kl-id-$id');
            return el ? (el.__test_tag || null) : null; })()""")

        # ── 1. Initial mount with three items ───────────────────────────────
        items_obs[] = [make_card("a", "Alpha"), make_card("b", "Bravo"), make_card("c", "Charlie")]
        @test wait_js("document.querySelectorAll('.kl-card').length === 3"; timeout = 3.0)
        @test dom_ids() == ["a", "b", "c"]

        # ── 2. Mutating a widget Observable doesn't remount the node ─────────
        @test tag_node!("b", "TAG-B") == true
        cards["b"].label[] = "Bravo (edited)"
        sleep(0.4)
        @test read_tag("b") == "TAG-B"
        @test occursin("edited", String(evjs("document.querySelector('.kl-id-b').innerText")))

        # ── 3. Append: only the new card mounts ─────────────────────────────
        items_obs[] = [cards["a"], cards["b"], cards["c"], make_card("d", "Delta")]
        @test wait_js("document.querySelectorAll('.kl-card').length === 4"; timeout = 2.0)
        @test dom_ids() == ["a", "b", "c", "d"]
        @test read_tag("b") == "TAG-B"     # not remounted

        # ── 4. Remove middle: surviving cards keep identity ─────────────────
        items_obs[] = [cards["a"], cards["c"], cards["d"]]
        @test wait_js("document.querySelectorAll('.kl-card').length === 3"; timeout = 2.0)
        @test dom_ids() == ["a", "c", "d"]
        @test read_tag("b") === nothing    # b was removed

        # ── 5. Reorder without changing membership ──────────────────────────
        tag_node!("a", "TAG-A")
        tag_node!("d", "TAG-D")
        items_obs[] = [cards["d"], cards["a"], cards["c"]]
        sleep(0.5)
        @test dom_ids() == ["d", "a", "c"]
        @test read_tag("a") == "TAG-A"     # survived reorder
        @test read_tag("d") == "TAG-D"     # survived reorder

        # ── 6. Mixed diff: insert + remove + reorder in one update ──────────
        items_obs[] = [make_card("e", "Echo"), cards["a"], cards["d"]]
        sleep(0.5)
        @test read_tag("a") == "TAG-A"
        @test read_tag("d") == "TAG-D"
        @test read_tag("c") === nothing    # c is gone
        @test read_tag("e") === nothing    # e is new (no tag)
        @test dom_ids() == ["e", "a", "d"]

        # ── 7. Clear list ───────────────────────────────────────────────────
        items_obs[] = LabelCard[]
        @test wait_js("document.querySelectorAll('.kl-card').length === 0"; timeout = 2.0)

        # ── 8. No JS errors across the whole exercise ───────────────────────
        @test isempty(evjs("window.__errs || []"))
    finally
        try close(disp) catch end
    end
end
