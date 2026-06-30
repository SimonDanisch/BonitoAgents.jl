# Black-box port of the legacy `test/electron/test_keyed_list.jl` (Tier 2o).
#
# The legacy test exercised Bonito's `KeyedList` widget through the OLD
# internal-API harness: it built a `Bonito.App` directly, opened its own
# electron window, and mutated a Julia-side Observable in-process. The
# WIDGET contract under test is fine-grained DOM identity: a survivor of a
# list update keeps its DOM node (the diff only inserts/removes/moves), so
# we're strictly better than `map(items) do _; render_all() end`.
#
# This is genuinely a KeyedList widget test, but we cover the exact same
# contract BLACK-BOX through `bt_show_app`: the agent mounts a LIVE Bonito
# App inline in the chat whose body is a `KeyedList` over an Observable
# vector. All the list mutation runs IN JULIA (in the Malt worker where the
# app lives), driven by a click `step` counter — every DOM click round-trips
# to the worker, the Julia `map` applies the next mutation, and the KeyedList
# diffs the real DOM. We assert identity exactly as the legacy test did:
# tag a node with a JS property, advance the list, and verify the SAME node
# survives carrying its tag (proving no remount), plus DOM order.
#
# Why a single App with an in-Julia mutation script (not multiple
# `bt_show_app` calls): a fresh `bt_show_app` would mount a NEW App with a
# NEW KeyedList — identity across mounts is meaningless. Identity only has
# meaning ACROSS DIFFS of ONE live KeyedList, so the mutations must hit the
# same Observable in the same session. We get that by driving one app and
# bumping a step counter whose Julia `map` rewrites the items vector.
#
# ISOLATED (its own dev_server + browser), NOT `setup=[SharedServer]`: this
# suite mounts a heavy Malt eval worker via `bt_show_app` (cold Julia + full
# Bonito load), whose cold start can take well over a minute. Under the
# shared soak server, that worker competes with every other e2e suite's load
# and could not reliably come up within the mount wait. A dedicated server
# (like cross_worker_test.jl) gives the worker a clean runway. See run_all.jl.
@testitem "e2e:keyed_list" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    const TK = TestKit

    APP_ENV = abspath(joinpath(@__DIR__, "..", "appenv"))

    # The live app, defined entirely in worker-side Julia. A `step` Observable
    # (bumped by a single DOM button) selects which mutation the Julia `map`
    # applies to `items_obs`; `KeyedList(items_obs)` diffs it into the DOM.
    #
    # LabelCard mirrors the legacy minimal widget: a div whose id is encoded in
    # the class (`kl-id-<id>`) so the test can select it, with a stable instance
    # cached per id (so the same instance — same hash key — is re-emitted across
    # rebuilds, which is what lets the diff recognise a survivor).
    appcode = """using Bonito

    mutable struct LabelCard
        id    :: String
        label :: Observable{String}
    end
    function Bonito.jsrender(session::Bonito.Session, c::LabelCard)
        Bonito.jsrender(session, DOM.div(c.label; class = "kl-card kl-id-\$(c.id)"))
    end

    App() do
        cards = Dict{String, LabelCard}()
        getcard(id, label) = get!(() -> LabelCard(id, Observable(label)), cards, id)

        # The mutation script: step i installs `states[i+1]`. Each entry reuses
        # the SAME cached instances for survivors (identity) and `getcard`s a
        # fresh one only for genuinely new ids. Mirrors the legacy sections:
        #   0 initial a,b,c | 1 append d | 2 remove middle b | 3 reorder d,a,c
        #   4 mixed insert+remove+reorder e,a,d | 5 clear
        states = [
            () -> [getcard("a","Alpha"), getcard("b","Bravo"), getcard("c","Charlie")],
            () -> [getcard("a","Alpha"), getcard("b","Bravo"), getcard("c","Charlie"), getcard("d","Delta")],
            () -> [getcard("a","Alpha"), getcard("c","Charlie"), getcard("d","Delta")],
            () -> [getcard("d","Delta"), getcard("a","Alpha"), getcard("c","Charlie")],
            () -> [getcard("e","Echo"), getcard("a","Alpha"), getcard("d","Delta")],
            () -> LabelCard[],
        ]

        items_obs = Observable(LabelCard[])
        step = Observable(0)
        # The map runs IN JULIA in the worker: it rewrites items_obs for the
        # current step and returns the step text we surface for debugging.
        status = map(step) do i
            idx = clamp(i, 0, length(states) - 1) + 1
            items_obs[] = states[idx]()
            "step=\$(i)"
        end

        next_btn = DOM.div("next"; class = "kl-next",
            onclick = js"(e)=> \$(step).notify(\$(step).value + 1)")

        DOM.div(
            DOM.span("KL-READY "), DOM.span(status; class = "kl-status"),
            next_btn,
            DOM.div(KeyedList(items_obs); id = "kl-container",
                    style = Bonito.Styles("display" => "flex", "flex-direction" => "column"));
            style = "padding:16px")
    end"""

    agent_fn = function (prompt)
        if occursin("app", lowercase(prompt))
            return [TK.text("here's a keyed list:"),
                    TK.bt_show_app(appcode; env_path = APP_ENV)]
        end
        return [TK.text("echo: $(prompt)")]
    end

    s = TK.dev_server(agent = agent_fn)
    try
        TK.open_browser(s)
        TK.refresh_eval_session!(APP_ENV)

        # ── DOM helpers (mirror the legacy dom_ids / tag_node! / read_tag) ────────
        # Current list order, read out of the `kl-id-<id>` class on each card.
        dom_ids(s) = TK.eval_js(s, """
            Array.from(document.querySelectorAll('.kl-card')).map(el => {
                const m = Array.from(el.classList).find(c => c.startsWith('kl-id-'));
                return m ? m.slice('kl-id-'.length) : null;
            })""")
        # Stable-node test: stamp a JS property on a node; if the node is reused
        # across a diff (not remounted) the stamp survives.
        tag_node(s, id, tag) = TK.eval_js(s, """(() => {
            const el = document.querySelector('.kl-id-$(id)');
            if (el) el.__test_tag = $(repr(tag));
            return !!el;
        })()""")
        read_tag(s, id) = TK.eval_js(s, """(() => {
            const el = document.querySelector('.kl-id-$(id)');
            return el ? (el.__test_tag || null) : null;
        })()""")
        count_cards(s) = "document.querySelectorAll('.kl-card').length"
        click_next(s) = TK.eval_js(s, "(() => { const b=document.querySelector('.kl-next'); if(b){b.click();return true} return false })()")

        @testset "KeyedList fine-grained DOM identity (bt_show_app, UI-only)" begin
            TK.new_chat(s; title = "KeyedList")
            TK.send_message(s, "show me the app")

            # The Malt worker cold start + Bonito load is heavy; allow plenty of time.
            @test TK.wait_for(s, "app mounted",
                "document.body.innerText.includes('KL-READY')"; timeout = 180) == true

            # ── 1. Initial mount: three cards in order a,b,c ──────────────────────
            @test TK.wait_for(s, "three cards land", "$(count_cards(s)) === 3"; timeout = 30) == true
            @test dom_ids(s) == ["a", "b", "c"]

            # ── 2. Tag b on its first-mount node; its survival across the next
            # membership diff (append d, which keeps b) is the identity proof. ─────
            @test tag_node(s, "b", "TAG-B") == true

            # ── 3. Append d: only the new card mounts, b keeps its tag ────────────
            @test click_next(s) == true                                   # → state 1
            @test TK.wait_for(s, "four cards", "$(count_cards(s)) === 4"; timeout = 10) == true
            @test dom_ids(s) == ["a", "b", "c", "d"]
            @test read_tag(s, "b") == "TAG-B"                             # b NOT remounted

            # ── 4. Remove middle (b): survivors keep identity, b's node is gone ───
            @test click_next(s) == true                                   # → state 2 (a,c,d)
            @test TK.wait_for(s, "three remain", "$(count_cards(s)) === 3"; timeout = 10) == true
            @test dom_ids(s) == ["a", "c", "d"]
            @test read_tag(s, "b") === nothing                           # b removed from DOM

            # ── 5. Reorder without changing membership: every card retains identity
            @test tag_node(s, "a", "TAG-A") == true
            @test tag_node(s, "d", "TAG-D") == true
            @test click_next(s) == true                                   # → state 3 (d,a,c)
            @test TK.wait_for(s, "reordered to d,a,c",
                "(() => { const e=document.querySelector('.kl-status'); return !!(e && e.innerText==='step=3'); })()"; timeout = 10) == true
            @test dom_ids(s) == ["d", "a", "c"]
            @test read_tag(s, "a") == "TAG-A"                            # moved, not remounted
            @test read_tag(s, "d") == "TAG-D"

            # ── 6. Mixed diff: insert e + remove c + reorder → e,a,d ──────────────
            @test click_next(s) == true                                   # → state 4 (e,a,d)
            @test TK.wait_for(s, "mixed diff applied",
                "(() => { const e=document.querySelector('.kl-status'); return !!(e && e.innerText==='step=4'); })()"; timeout = 10) == true
            @test dom_ids(s) == ["e", "a", "d"]
            @test read_tag(s, "a") == "TAG-A"                            # survivor keeps tag
            @test read_tag(s, "d") == "TAG-D"                            # survivor keeps tag
            @test read_tag(s, "c") === nothing                          # c removed
            @test read_tag(s, "e") === nothing                          # e is brand new

            # ── 7. Clear the list ─────────────────────────────────────────────────
            @test click_next(s) == true                                   # → state 5 (empty)
            @test TK.wait_for(s, "list cleared", "$(count_cards(s)) === 0"; timeout = 10) == true

            # ── 8. No JS errors during the whole exercise ────────────────────────
            @test isempty(TK.js_errors(s))
        end
    finally
        close(s)
    end
end
