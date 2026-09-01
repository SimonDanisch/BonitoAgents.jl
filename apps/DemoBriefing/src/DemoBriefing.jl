"""
    DemoBriefing

Reference app for the BonitoAgents App interface (see APPS_SPEC.md).

It is the "morning briefing" workflow in miniature, and it exists to exercise
the shape end to end before any server plumbing exists:

  1. plain code produces a list of issues (fixture data, so a run is deterministic)
  2. one subagent per issue triages it, fanned out through `Apps.map_agents`
  3. the verdicts drive a live Bonito dashboard
  4. the dashboard's buttons call back into `Apps.agent` and `Apps.spawn_chat`

Under `Apps.ReplayContext` the agent calls are canned, so the whole thing runs
with no server, no worker and no tokens.
"""
module DemoBriefing

using Bonito
using Observables
import BonitoMCP: Apps

export Briefing

struct Briefing <: Apps.App end

Apps.name(::Briefing)        = "Demo Briefing"
Apps.description(::Briefing) = "Triage open issues and PRs, draft replies, pick one up"
Apps.config(::Briefing)      = (; repos = Apps.Field("Repositories", "MakieOrg/Makie.jl"))

# ── Data ─────────────────────────────────────────────────────────────────────

struct Issue
    number::Int
    repo::String
    title::String
    is_pr::Bool
    age_days::Int
end

url(i::Issue) = "https://github.com/$(i.repo)/$(i.is_pr ? "pull" : "issues")/$(i.number)"

# What the triage subagent must answer with. Opaque to ReplayContext; the live
# Context turns it into a structured-output tool.
const TRIAGE_SCHEMA = Dict{String,Any}(
    "type" => "object",
    "properties" => Dict{String,Any}(
        "bucket" => Dict("type" => "string",
                         "enum" => ["act_now", "needs_info", "watch", "ignore"]),
        "why"    => Dict("type" => "string",
                         "description" => "One sentence on what to do about it"),
    ),
    "required" => ["bucket", "why"],
)

const BUCKETS = ["act_now", "needs_info", "watch", "ignore"]
const BUCKET_LABEL = Dict("act_now"    => "Act now",
                          "needs_info" => "Needs info",
                          "watch"      => "Watch",
                          "ignore"     => "Ignore")

bucket_rank(b::AbstractString) = something(findfirst(==(b), BUCKETS), length(BUCKETS) + 1)

# Stands in for the GitHub API call. Deterministic on purpose: a demo whose
# output changes under it cannot be asserted on.
function fetch_issues(repos::AbstractString)
    parts = filter(!isempty, map(strip, split(repos, ','; keepempty = false)))
    repo = isempty(parts) ? "MakieOrg/Makie.jl" : String(first(parts))
    return [
        Issue(4821, repo, "Segfault in GLMakie when resizing during animation", false, 1),
        Issue(4822, repo, "Add `colorrange` support to `heatmap!` recipes", true, 2),
        Issue(4815, repo, "Docs: `Axis` limits section contradicts itself", false, 5),
        Issue(4830, repo, "Colorbar ticks overlap at small figure sizes", false, 3),
        Issue(4799, repo, "Bump Julia compat to 1.11", true, 12),
        Issue(4788, repo, "How do I make a log-scaled 3D axis?", false, 21),
    ]
end

triage_prompt(i::Issue) = """
    Triage this $(i.is_pr ? "pull request" : "issue") for a morning review.

    $(i.repo)#$(i.number): $(i.title)
    Opened $(i.age_days) day$(i.age_days == 1 ? "" : "s") ago.

    Pick the bucket that matches how actionable it is right now, and say in one
    sentence what to do about it.
    """

draft_prompt(i::Issue) = """
    Draft a reply to $(i.repo)#$(i.number) ("$(i.title)").

    Be concrete and short. Do not post it: the user reviews and sends.
    """

# ── The run ──────────────────────────────────────────────────────────────────

struct Board
    items::Vector{Issue}
    verdicts::Dict{Int,Any}
    drafts::Dict{Int,Observable{String}}
    busy::Dict{Int,Observable{Bool}}
    # The board's handlers are ordinary closures over these: the dashboard is
    # built in the same worker the app runs in, so there is no boundary to cross.
    ctx::Apps.Context
    chat::Apps.Chat
end

function Apps.run(app::Briefing, ctx::Apps.Context, chat::Apps.Chat)
    repos = Apps.config(ctx).repos
    items = fetch_issues(repos)
    Apps.send(chat, Apps.Note("Triaging $(length(items)) open items from $repos…"))

    # The judgment step: one scoped subagent per item, in flight together.
    verdicts = Apps.map_agents(ctx, items) do item
        item.number => Apps.agent(ctx, triage_prompt(item);
                                  schema = TRIAGE_SCHEMA,
                                  label = "triage-#$(item.number)")
    end |> Dict

    # Most actionable first; within a bucket the item that has been sitting
    # longest goes on top.
    sort!(items; by = i -> (bucket_rank(verdicts[i.number]["bucket"]), -i.age_days))

    board = Board(items, verdicts,
                  Dict(i.number => Observable("") for i in items),
                  Dict(i.number => Observable(false) for i in items),
                  ctx, chat)

    # The app runs in this chat's worker, so the App object goes over as a
    # value: the server parks it with `remote_ref` and the chat mounts it live.
    # `to_agent` is written here because only the app knows what its own board
    # means; it is app-authored text, never a paste of fetched issue content.
    Apps.send(chat, Apps.BtJuliaEval(render(board); pin = true);
              to_agent = "Displayed a triage board: $(counts_line(board)). " *
                         "Ranked most actionable first, oldest first within a bucket.")
    Apps.send(chat, Apps.Note(summary(board)))
    Apps.state!(ctx, "last_run_count", length(items))
    return board
end

count_in(board::Board, bucket) =
    count(i -> board.verdicts[i.number]["bucket"] == bucket, board.items)

counts_line(board::Board) =
    join(["$(count_in(board, b)) $(lowercase(BUCKET_LABEL[b]))"
          for b in BUCKETS if count_in(board, b) > 0], ", ")

function summary(board::Board)
    parts = ["**$(count_in(board, b)) $(lowercase(BUCKET_LABEL[b]))**"
             for b in BUCKETS if count_in(board, b) > 0]
    return "Briefing ready: " * join(parts, ", ") *
           ". The board is in the panel; ask me about any of them."
end

# ── UI ───────────────────────────────────────────────────────────────────────

const BoardStyles = Bonito.Styles(
    Bonito.CSS(".db-board",
        "font-family" => "Inter, system-ui, sans-serif",
        "display" => "flex", "flex-direction" => "column", "gap" => "14px",
        "padding" => "16px", "background" => "#f8fafc",
        "color" => "#0f172a", "height" => "100%",
        "overflow-y" => "auto", "box-sizing" => "border-box"),
    Bonito.CSS(".db-head",
        "display" => "flex", "align-items" => "baseline", "gap" => "10px"),
    Bonito.CSS(".db-title", "font-size" => "16px", "font-weight" => "650"),
    Bonito.CSS(".db-sub", "font-size" => "12px", "color" => "#64748b"),
    Bonito.CSS(".db-counts", "display" => "flex", "gap" => "6px", "flex-wrap" => "wrap"),
    Bonito.CSS(".db-count",
        "font-size" => "11px", "font-weight" => "600",
        "padding" => "3px 9px", "border-radius" => "999px",
        "background" => "#e2e8f0", "color" => "#334155"),
    Bonito.CSS(".db-count[data-bucket=\"act_now\"]",
        "background" => "#fee2e2", "color" => "#991b1b"),
    Bonito.CSS(".db-count[data-bucket=\"needs_info\"]",
        "background" => "#dbeafe", "color" => "#1e40af"),

    Bonito.CSS(".db-card",
        "background" => "#ffffff", "border" => "1px solid #e2e8f0",
        "border-left" => "3px solid #cbd5e1",
        "border-radius" => "8px", "padding" => "11px 13px",
        "display" => "flex", "flex-direction" => "column", "gap" => "7px"),
    Bonito.CSS(".db-card[data-bucket=\"act_now\"]", "border-left-color" => "#ef4444"),
    Bonito.CSS(".db-card[data-bucket=\"needs_info\"]", "border-left-color" => "#3b82f6"),
    Bonito.CSS(".db-card[data-bucket=\"watch\"]", "border-left-color" => "#94a3b8"),
    Bonito.CSS(".db-card[data-bucket=\"ignore\"]", "opacity" => "0.6"),

    Bonito.CSS(".db-row",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "min-width" => "0"),
    Bonito.CSS(".db-kind",
        "font-size" => "10px", "font-weight" => "700", "letter-spacing" => "0.04em",
        "padding" => "2px 6px", "border-radius" => "4px",
        "background" => "#f1f5f9", "color" => "#475569", "flex-shrink" => "0"),
    Bonito.CSS(".db-num", "font-size" => "12px", "color" => "#64748b", "flex-shrink" => "0"),
    Bonito.CSS(".db-name",
        "font-size" => "13.5px", "font-weight" => "600",
        "color" => "#0f172a", "text-decoration" => "none",
        "white-space" => "nowrap", "overflow" => "hidden", "text-overflow" => "ellipsis"),
    Bonito.CSS(".db-name:hover", "text-decoration" => "underline"),
    Bonito.CSS(".db-why",
        "font-size" => "12px", "line-height" => "1.45", "color" => "#475569"),
    # background/color are explicit: Bonito's base stylesheet gives form
    # controls a dark surface, which renders dark-on-dark inside a light card.
    Bonito.CSS(".db-draft",
        "width" => "100%", "box-sizing" => "border-box",
        "font-family" => "inherit", "font-size" => "12px", "line-height" => "1.45",
        "padding" => "7px 9px", "border" => "1px solid #e2e8f0",
        "border-radius" => "6px", "resize" => "vertical",
        "background" => "#ffffff", "color" => "#0f172a"),
    Bonito.CSS(".db-draft::placeholder", "color" => "#94a3b8"),
    Bonito.CSS(".db-draft:focus",
        "outline" => "none", "border-color" => "#3b82f6"),
    Bonito.CSS(".db-actions", "display" => "flex", "gap" => "6px", "align-items" => "center"),
    Bonito.CSS(".db-busy", "font-size" => "11px", "color" => "#3b82f6"),
)

const ButtonStyle = Bonito.Styles(
    Bonito.CSS("font-family" => "inherit", "font-size" => "12px", "font-weight" => "600",
        "padding" => "5px 11px", "border-radius" => "6px",
        "border" => "1px solid #cbd5e1", "background" => "#ffffff",
        "color" => "#334155", "cursor" => "pointer"),
    Bonito.CSS(":hover", "background" => "#f1f5f9", "border-color" => "#94a3b8"),
)

# The draft field. `parent` is the run-scoped source of truth so the agent's
# fill-in reaches every open tab; the session-local mirror is what this render
# subscribes to, so it goes away with the session instead of piling up.
function draft_field(session::Bonito.Session, parent::Observable{String})
    mirror = map(identity, session, parent)
    area = DOM.textarea(parent[]; class = "db-draft", rows = "3",
                        placeholder = "Draft a reply, or ask the agent to…",
                        oninput = js"event => $(parent).notify(event.target.value)")
    onjs(session, mirror, js"""value => {
        const el = $(area);
        if (el && el.value !== value) el.value = value;
    }""")
    return area
end

function card(session::Bonito.Session, board::Board, item::Issue)
    v = board.verdicts[item.number]
    draft = board.drafts[item.number]
    busy = board.busy[item.number]

    write_btn = Bonito.Button("Draft reply"; style = ButtonStyle)
    on(session, write_btn.value) do _
        busy[] = true
        Base.errormonitor(@async try
            draft[] = Apps.agent(board.ctx, draft_prompt(item);
                                 label = "draft-#$(item.number)")
        finally
            busy[] = false
        end)
    end

    work_btn = Bonito.Button(item.is_pr ? "Check out PR" : "Work on it"; style = ButtonStyle)
    on(session, work_btn.value) do _
        Base.errormonitor(@async Apps.open_chat(board.ctx;
                                                title = "#$(item.number) $(item.title)",
                                                github = url(item)))
    end

    busy_label = map(b -> b ? "asking the agent…" : "", session, busy)

    return DOM.div(
        DOM.div(
            DOM.span(item.is_pr ? "PR" : "ISSUE"; class = "db-kind"),
            DOM.span("#$(item.number)"; class = "db-num"),
            DOM.a(item.title; class = "db-name", href = url(item), target = "_blank");
            class = "db-row"),
        DOM.div(v["why"]; class = "db-why"),
        draft_field(session, draft),
        DOM.div(write_btn, work_btn, DOM.span(busy_label; class = "db-busy");
                class = "db-actions");
        class = "db-card", dataBucket = v["bucket"])
end

function render(board::Board)
    return App() do session
        counts = [DOM.span("$(BUCKET_LABEL[b]) $(count_in(board, b))";
                           class = "db-count", dataBucket = b)
                  for b in BUCKETS if count_in(board, b) > 0]
        return DOM.div(
            BoardStyles,
            DOM.div(DOM.span("Morning Briefing"; class = "db-title"),
                    DOM.span("$(length(board.items)) open items"; class = "db-sub");
                    class = "db-head"),
            DOM.div(counts...; class = "db-counts"),
            (card(session, board, i) for i in board.items)...;
            class = "db-board")
    end
end

# ── Fixture ──────────────────────────────────────────────────────────────────

"""
    replay_context() -> Apps.ReplayContext

A `ReplayContext` scripted with a canned answer for every agent call this app
makes, so `Apps.run(Briefing(), replay_context())` is a complete offline run.
Used by the tests and by `demo.jl`.
"""
function replay_context()
    triage = Dict(
        4821 => ("act_now",    "Crash with a clean repro and a stack trace; reproduce it and bisect against the last release."),
        4830 => ("act_now",    "Layout regression from the tick-placement change; small fix, ship it in the next patch."),
        4822 => ("needs_info", "Recipe change looks right but has no tests; ask the author to add one before review."),
        4815 => ("needs_info", "Two doc sections disagree; confirm which behaviour is current before editing either."),
        4799 => ("watch",      "Compat bump is blocked on an upstream release; re-check when that lands."),
        4788 => ("ignore",     "Support question, already answered on Discourse; point at the thread and close."),
    )
    drafts = Dict(
        4821 => "Thanks for the report, the stack trace is exactly what we needed. This looks like the resize path racing the render loop. Could you confirm which GLMakie version you are on?",
        4830 => "Good catch. This came in with the tick-placement change; the fix is to reserve label width before layout. Patch incoming.",
        4822 => "This looks reasonable to me. Could you add a test covering the `colorrange` path so we do not regress it?",
        4815 => "You are right that these contradict. The limits section is the current behaviour; I will update the other one.",
        4799 => "Holding this until the upstream release lands, then I will rerun CI here.",
        4788 => "This was answered on Discourse: <link>. Closing here, but reopen if that does not cover your case.",
    )
    replies = Dict{String,Any}()
    for (n, (bucket, why)) in triage
        replies["triage-#$n"] = Dict("bucket" => bucket, "why" => why)
    end
    for (n, text) in drafts
        replies["draft-#$n"] = text
    end
    return Apps.ReplayContext(; replies, config = (; repos = "MakieOrg/Makie.jl"))
end

end # module DemoBriefing
