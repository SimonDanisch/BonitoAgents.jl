# ── Recent-chats overview ────────────────────────────────────────────────
# The dashboard header's overview section: the last `OVERVIEW_LIMIT` chats as
# cards, each showing the chat's persistent title, its message count + last
# activity, the last few user prompts (system tags stripped), and a stable
# image chosen from the chat (user attachment or bt_show result).
#
# Titles and messages come from chat history; the image is a persistent
# snapshot shared with the sidebar (chat_icons.jl).

const OVERVIEW_LIMIT = 6
const OVERVIEW_SNIPPETS = 3

struct ChatCardData
    pid         :: String
    title       :: String
    msg_count   :: Int
    snippets    :: Vector{String}   # last user prompts, oldest first
    image       :: Any              # nothing | Bonito.Asset (persistent snapshot)
    last_active :: Float64          # unix mtime of chat.md
    status      :: Symbol           # chat_status: :offline | :online | :active
end

# One user prompt → card snippet: drop the attachment suffix and interruption
# markers, then reuse `meaningful_title` (peels `<system-reminder>`-style tag
# blocks, collapses whitespace, truncates). `nothing` for system-only text.
function overview_user_snippet(provider::AgentProvider, text::AbstractString)
    base, _ = split_attachment_suffix(text)
    base = replace(base, r"\[Request interrupted[^\]]*\]" => " ")
    return meaningful_title(provider, base)
end

# These messages come off disk (chat.md), so the wrapper rules that have to be
# peeled off them are the ones of the agent that WROTE them — Claude injects
# `<system-reminder>` and friends, the others don't. Callers that have the
# project pass `project_provider(p)`; the default stands for a caller that
# doesn't, and matches what every project did before the provider was recorded.
function overview_snippets(msgs::Vector{ChatMsg};
                           limit::Int = OVERVIEW_SNIPPETS,
                           provider::AgentProvider = find_provider("ClaudeCode"))
    out = String[]
    for m in Iterators.reverse(msgs)
        m isa UserMsg || continue
        m.auto && continue                       # Yolo auto-continue nudges aren't prompts
        s = overview_user_snippet(provider, m.text)
        s === nothing && continue
        pushfirst!(out, s)
        length(out) >= limit && break
    end
    return out
end

# Messages + chat_dir for a project: the live model's store when the chat is
# open (fresh, no re-parse), else the persisted chat.md history.
function overview_msgs(state::ServerState, p::ProjectInfo)
    model = lock(state.lock) do
        get(state.chat_models, p.id, nothing)
    end
    if model !== nothing
        s = shared(model)
        msgs = lock(() -> copy(s.msgs_store), s.lock)
        return msgs, model.chat_dir
    end
    chat_dir = chat_storage_dir(state, p.id, p.server_path)
    return load_history(load_session(chat_dir, p.server_path)), chat_dir
end

"""
    recent_chat_cards(state; limit = OVERVIEW_LIMIT) -> Vector{ChatCardData}

The last `limit` chats by activity (chat.md mtime — bumped on every persisted
message, live or not), dismissed chats included: the overview is for finding
past work, and opening a dismissed chat un-dismisses it.
"""
function recent_chat_cards(state::ServerState; limit::Int = OVERVIEW_LIMIT)
    candidates = Tuple{Float64,ProjectInfo}[]
    for (_, p) in state.projects[]
        # New-style storage only (state_dir/chats/<pid>); computed directly so
        # listing the dashboard never mkpaths a dir for chat-less projects.
        f = joinpath(state.state_dir, "chats", p.id, "chat.md")
        isfile(f) || continue
        push!(candidates, (mtime(f), p))
    end
    sort!(candidates; by = first, rev = true)
    cards = ChatCardData[]
    for (mt, p) in candidates[1:min(limit, length(candidates))]
        msgs, chat_dir = overview_msgs(state, p)
        push!(cards, ChatCardData(
            p.id,
            p.title[],
            length(msgs),
            overview_snippets(msgs; provider = project_provider(p)),
            chat_icon_image(state, p),
            mt,
            chat_status(state, p)))
    end
    return cards
end

function relative_time_label(t::Float64)
    d = max(0.0, time() - t)
    d < 90      && return "just now"
    d < 3600    && return "$(round(Int, d / 60))m ago"
    d < 86400   && return "$(round(Int, d / 3600))h ago"
    return "$(round(Int, d / 86400))d ago"
end

const OverviewStyles = Bonito.Styles(
    # Full-width line inside the wrapping `.bt-header` flex row.
    CSS(".bt-overview",
        "flex-basis" => "100%", "min-width" => "0",
        "width" => "100%"),
    CSS(".bt-ov-grid",
        "display" => "grid",
        "grid-template-columns" => "repeat(auto-fill, minmax(230px, 1fr))",
        "gap" => "12px",
        "margin-top" => "10px"),
    CSS(".bt-ov-card",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "overflow" => "hidden",
        "cursor" => "pointer",
        "display" => "flex", "flex-direction" => "column",
        "transition" => "border-color 120ms ease, box-shadow 120ms ease"),
    CSS(".bt-ov-card:hover",
        "border-color" => "var(--bt-border-strong)",
        "box-shadow" => "var(--bt-shadow-sm)"),
    # Thumb strip: fixed height so the grid rows stay even; the image covers.
    # The no-image placeholder centers the project icon on a soft surface.
    CSS(".bt-ov-thumb",
        "height" => "96px", "flex-shrink" => "0",
        "background" => "var(--bt-surface-2)",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "overflow" => "hidden"),
    CSS(".bt-ov-thumb img.bt-ov-img",
        "width" => "100%", "height" => "100%", "object-fit" => "cover",
        "display" => "block"),
    CSS(".bt-ov-body",
        "padding" => "9px 11px 10px",
        "display" => "flex", "flex-direction" => "column", "gap" => "5px",
        "min-width" => "0"),
    CSS(".bt-ov-title-row",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "min-width" => "0"),
    CSS(".bt-ov-led",
        "width" => "8px", "height" => "8px", "border-radius" => "50%",
        "flex-shrink" => "0",
        "background" => "var(--bt-text-faint)"),
    CSS(".bt-ov-led[data-status=\"online\"]", "background" => "var(--bt-status-online)"),
    CSS(".bt-ov-led[data-status=\"active\"]", "background" => "var(--bt-status-active)"),
    CSS(".bt-ov-led[data-status=\"offline\"]", "background" => "var(--bt-status-offline)"),
    CSS(".bt-ov-title",
        "font-size" => "13px", "font-weight" => "600",
        "color" => "var(--bt-text)",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "min-width" => "0"),
    CSS(".bt-ov-meta",
        "font-size" => "11px", "color" => "var(--bt-text-muted)"),
    CSS(".bt-ov-snippets",
        "display" => "flex", "flex-direction" => "column", "gap" => "2px",
        "min-width" => "0"),
    CSS(".bt-ov-snippet",
        "font-size" => "11.5px", "line-height" => "1.35",
        "color" => "var(--bt-text-muted)",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-ov-empty",
        "font-size" => "12px", "color" => "var(--bt-text-muted)",
        "padding" => "6px 0"),
)

function overview_card_dom(state::ServerState, c::ChatCardData)
    p = get(state.projects[], c.pid, nothing)
    thumb = if c.image !== nothing
        DOM.img(; src = c.image, alt = "", class = "bt-ov-img", loading = "lazy")
    elseif p !== nothing
        project_icon(state, p)                # identicon placeholder
    else
        DOM.div()
    end
    snippets = [DOM.div(s; class = "bt-ov-snippet", title = s) for s in c.snippets]
    DOM.div(
        DOM.div(thumb; class = "bt-ov-thumb"),
        DOM.div(
            DOM.div(
                DOM.span(""; class = "bt-ov-led", dataStatus = string(c.status)),
                DOM.span(c.title; class = "bt-ov-title", title = c.title);
                class = "bt-ov-title-row"),
            DOM.div("$(c.msg_count) message$(c.msg_count == 1 ? "" : "s") · $(relative_time_label(c.last_active))";
                    class = "bt-ov-meta"),
            DOM.div(snippets...; class = "bt-ov-snippets");
            class = "bt-ov-body");
        class = "bt-ov-card",
        dataProjectId = c.pid)
end

# The header section. Re-renders the card grid on `turn_signal` (a chat's
# content changed — every turn boundary), `chat_signal` (chat open/close) and
# `projects` (title edit / rename / new project). One delegated click handler on
# the LONG-LIVED wrapper routes card clicks to `current_view` — per-card
# handlers would re-register on every refresh.
#
# Cost note for anyone adding a signal here: a rebuild runs `recent_chat_cards`,
# which stats one `chat.md` per project and — for the `OVERVIEW_LIMIT` chats it
# actually shows — copies each OPEN chat's `msgs_store` under its lock
# (`overview_msgs`). That is bounded and fine at turn granularity (twice a turn,
# six chats), but it is not free per frame: don't wire this to a signal that
# fires per streamed chunk.
function recent_chats_dom(session::Bonito.Session, state::ServerState,
                          current_view::Union{Observable{String},Nothing})
    grid = map(state.chat_signal, state.turn_signal, state.projects) do _, _turn, _projects
        cards = recent_chat_cards(state)
        isempty(cards) && return DOM.div("No chats yet — create a project below.";
                                          class = "bt-ov-empty")
        DOM.div((overview_card_dom(state, c) for c in cards)...; class = "bt-ov-grid")
    end
    current_view === nothing &&
        return DOM.div(OverviewStyles, grid; class = "bt-overview")
    return DOM.div(OverviewStyles, grid;
        class = "bt-overview",
        onclick = js"""event => {
            const card = event.target.closest('.bt-ov-card');
            if (card && card.dataset.projectId)
                $(current_view).notify(card.dataset.projectId);
        }""")
end
