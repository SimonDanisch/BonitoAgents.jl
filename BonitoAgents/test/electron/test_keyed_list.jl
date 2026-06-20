# Tier 2o — KeyedList: fine-grained list manager.
#
# Verifies the contract: widgets that survive a list update keep their
# DOM node (identity preserved across diffs), and only the diff's
# inserts/removes/moves are applied. The widget identity test is the
# point of the whole abstraction — if we lose it we'd be no better off
# than `map(items) do _; render_all() end`.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using Bonito, JSON

# Minimal widget: a paragraph with one Observable<String> binding.
# Stable per-instance identity (mutable struct + Observable field → hash
# is based on objectids → unchanged across rebuilds when the same value
# is reused).
mutable struct LabelCard
    id     :: String
    label  :: Observable{String}
end

function Bonito.jsrender(session::Bonito.Session, c::LabelCard)
    # Encode test-id into the class — Bonito/Hyperscript kwargs can't
    # natively express `data-test-id` (underscore→dash conversion
    # produces `data-_test-_id`, not what we want). The class-based
    # selector is enough for tests; the abstraction itself doesn't
    # require any DOM markers.
    Bonito.jsrender(session,
        Bonito.DOM.div(c.label;
            class = "kl-card kl-id-$(c.id)"))
end

# Mount a minimal Bonito App that exposes a KeyedList against a Julia-
# side Observable we can mutate from the test.
items_obs = Observable(LabelCard[])
const cards = Dict{String, LabelCard}()
make_card(id, label) = get!(cards, id) do
    LabelCard(id, Observable(label))
end

app = Bonito.App() do session
    Bonito.DOM.div(
        Bonito.KeyedList(items_obs);
        id = "kl-container",
        style = Bonito.Styles("display" => "flex",
                               "flex-direction" => "column"))
end

disp = Bonito.use_electron_display(;
    devtools = false,
    options  = Dict{String,Any}("show" => false, "width" => 800, "height" => 600),
    electron_args = ["--ozone-platform=x11"])
display(disp, app)
sleep(0.6)
ctx = (; disp = disp, app = app, session = app.session[], state = nothing)
run(disp.window, """
    window.__errs = [];
    window.addEventListener('error', e => window.__errs.push(String(e.message)));
""")

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# Helper: how the list looks in the DOM right now. Pull the id from the
# class list ("kl-id-<id>") since we're encoding it there.
dom_ids() = TH.eval_js(ctx, """
    Array.from(document.querySelectorAll('.kl-card')).map(el => {
        const m = Array.from(el.classList).find(c => c.startsWith('kl-id-'));
        return m ? m.slice('kl-id-'.length) : null;
    })
""")

# Helper: stable-node test. Tag a node with a JS property; if the same
# node is reused across a diff, the tag survives.
tag_node!(id::String, tag::String) = TH.eval_js(ctx, """(() => {
    const el = document.querySelector('.kl-id-$id');
    if (el) el.__test_tag = $(JSON.json(tag));
    return !!el;
})()""")
read_tag(id::String) = TH.eval_js(ctx, """(() => {
    const el = document.querySelector('.kl-id-$id');
    return el ? (el.__test_tag || null) : null;
})()""")

try
    # ── 1. Initial mount ─────────────────────────────────────────────────
    TH.section("Initial mount with three items") do
        items_obs[] = [make_card("a", "Alpha"),
                       make_card("b", "Bravo"),
                       make_card("c", "Charlie")]
        record("three cards land in order",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.kl-card').length === 3";
                   timeout = 3.0))
        record("DOM order is a,b,c", @TH.test_eq dom_ids() ["a", "b", "c"])
    end

    # ── 2. Identity preserved when label changes ────────────────────────
    TH.section("Mutating widget Observable doesn't remount the node") do
        record("tag stuck on 'b'", @TH.test_eq tag_node!("b", "TAG-B") true)
        cards["b"].label[] = "Bravo (edited)"
        sleep(0.4)
        record("'b' tag survives label update",
               @TH.test_eq read_tag("b") "TAG-B")
        text = TH.eval_js(ctx, """document.querySelector('.kl-id-b').innerText""")
        record("'b' text reflects new label",
               @TH.test_true occursin("edited", String(text)))
    end

    # ── 3. Append a new item ─────────────────────────────────────────────
    TH.section("Append: only the new card mounts") do
        items_obs[] = [cards["a"], cards["b"], cards["c"],
                       make_card("d", "Delta")]
        record("four cards present",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.kl-card').length === 4";
                   timeout = 2.0))
        record("order a,b,c,d", @TH.test_eq dom_ids() ["a","b","c","d"])
        record("'b' tag still there (not remounted)",
               @TH.test_eq read_tag("b") "TAG-B")
    end

    # ── 4. Remove middle item ────────────────────────────────────────────
    TH.section("Remove middle: surviving cards keep identity") do
        items_obs[] = [cards["a"], cards["c"], cards["d"]]
        record("three cards remain",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.kl-card').length === 3";
                   timeout = 2.0))
        record("order a,c,d", @TH.test_eq dom_ids() ["a","c","d"])
        record("'b' tag is gone (b was removed)",
               @TH.test_eq read_tag("b") nothing)
    end

    # ── 5. Reorder without changing membership ──────────────────────────
    TH.section("Reorder: every card retains identity") do
        # Tag a and d before the move so we can detect remount.
        tag_node!("a", "TAG-A")
        tag_node!("d", "TAG-D")
        items_obs[] = [cards["d"], cards["a"], cards["c"]]
        sleep(0.5)
        record("DOM order matches", @TH.test_eq dom_ids() ["d","a","c"])
        record("'a' tag survived reorder", @TH.test_eq read_tag("a") "TAG-A")
        record("'d' tag survived reorder", @TH.test_eq read_tag("d") "TAG-D")
    end

    # ── 6. Insert at position + remove + reorder in one diff ────────────
    TH.section("Mixed diff: insert + remove + reorder") do
        items_obs[] = [make_card("e", "Echo"), cards["a"], cards["d"]]
        sleep(0.5)
        record("'a' and 'd' still tagged after mixed diff",
               @TH.test_true (read_tag("a") == "TAG-A" &&
                               read_tag("d") == "TAG-D"))
        record("'c' is gone", @TH.test_eq read_tag("c") nothing)
        record("'e' is new (no tag)", @TH.test_eq read_tag("e") nothing)
        record("DOM order e,a,d", @TH.test_eq dom_ids() ["e","a","d"])
    end

    # ── 7. Clear list ────────────────────────────────────────────────────
    TH.section("Clear list") do
        items_obs[] = LabelCard[]
        record("no cards in DOM",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.kl-card').length === 0";
                   timeout = 2.0))
    end

    # ── 8. No JS errors ─────────────────────────────────────────────────
    TH.section("No JS errors during the exercise") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_eq length(errs) 0)
        isempty(errs) || @info "JS errors:" errs
    end

    TH.emit_screenshot(ctx; label = "keyed-list final")

finally
    TH.report!("Tier 2o — KeyedList", results)
    try close(disp) catch end
end
