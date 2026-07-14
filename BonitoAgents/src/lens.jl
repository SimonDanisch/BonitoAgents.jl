# ── Lens search ──────────────────────────────────────────────────────────────
# A "lens" is a query that FILTERS the chat in place (hide non-matching
# messages) and optionally applies an ACTION (expand / collapse) to matches.
# It replaces the per-tool toolbar with something expressive:
#
#   /user_message "search string" + /bt_show expand
#     → show user messages fuzzy-matching "search string", AND show every
#       bt_show call expanded. Everything else is hidden.
#
# Grammar — a lens is signed clauses joined by ` + ` (include) / ` - ` (exclude):
#
#   lens   := [op] clause ( op clause )*          op := '+' | '-'
#   clause := ['!'|'-'] [/]key [ params ]
#   params := ( ACTION | "query" | word )*        ACTION := expand | collapse
#
#   • A bare `/bt_show` is ALREADY exclusive — it shows only that type,
#     everything else hidden. So `-` is not needed for the common filter.
#   • <key>  a message-type key (user_message, agent, thought, plan) or a tool
#            name (Bash, bt_show, bt_julia_eval, …) or `tools`; also the
#            wildcard `all` / `*` (matches every message). Subsequence-matched,
#            so `bt_eval` matches `bt_julia_eval`.
#   • A leading `!` / `-`, or a ` - ` join, marks the clause EXCLUDE.
#   • params: a fuzzy text filter ("quoted" or bare words) and/or an action.
#            A bareword equal to a known ACTION is the action; anything else
#            (and anything quoted) is the query. A leading `:` is accepted but
#            optional (`/bt_show: expand` == `/bt_show expand`).
#
# Base rule (apply_lens):  visible = BASE \ ⋃(exclude matches), where
# BASE = ⋃(include matches) if any include clause exists, else ALL messages.
# So `!/thought` alone = everything but thoughts; `/all - /Bash` = all but Bash.
#
# Search runs SERVER-SIDE over the full `msgs_store` (the client only holds a
# virtual-scroll window). `apply_lens` returns the visible 0-based indices +
# per-index actions; the client hides the rest and applies the actions.
using StringDistances: TokenMax, Levenshtein, similarity

const LENS_ACTIONS = ("expand", "collapse")

struct LensClause
    sign   :: Symbol                    # :include | :exclude
    key    :: String                    # "" / "all" / "*" = any message; else type/tool key
    action :: Union{Nothing,String}     # "expand" | "collapse"
    query  :: Union{Nothing,String}
end

# ── Parsing ──────────────────────────────────────────────────────────────────
# Split a lens into (sign, clause-string) on top-level ` + ` / ` - ` (an
# operator inside a quoted query doesn't split). The first segment defaults to
# include unless it carries a leading `!` / `-`.
function split_lens_clauses(str::AbstractString)
    segs = Tuple{Symbol,String}[]
    buf = IOBuffer(); inq = false; sign = :include
    chars = collect(str); i = 1
    isop(c) = c == '+' || c == '-'
    while i <= length(chars)
        c = chars[i]
        if c == '"'
            inq = !inq; print(buf, c); i += 1
        elseif !inq && isop(c) &&
               (i > 1 && isspace(chars[i-1])) &&
               (i < length(chars) && isspace(chars[i+1]))
            push!(segs, (sign, String(take!(buf))))
            sign = c == '-' ? :exclude : :include
            i += 1
        else
            print(buf, c); i += 1
        end
    end
    push!(segs, (sign, String(take!(buf))))
    return segs
end

function parse_clause(sign::Symbol, s::AbstractString)::Union{Nothing,LensClause}
    s = strip(s)
    isempty(s) && return nothing
    # A leading `!` / `-` on the clause itself forces exclude (covers the very
    # first clause, which has no preceding ` - ` operator to carry the sign).
    if startswith(s, '!') || startswith(s, '-')
        sign = :exclude; s = strip(s[2:end])
    end
    isempty(s) && return nothing
    # A leading `/` introduces a structured key; bare text (no slash) is a
    # full-text search across ALL messages (empty key).
    if startswith(s, "/")
        s = strip(s[2:end])
        isempty(s) && return nothing
        m = match(r"^([\w.@*-]+)\s*:?\s*(.*)$", s)   # `:` after the key is optional sugar
        m === nothing && return nothing
        key  = String(m.captures[1])
        rest = String(m.captures[2])
    else
        key  = ""
        rest = String(s)
    end
    action = nothing
    qparts = String[]
    for tok in lens_tokens(rest)
        if tok.quoted
            push!(qparts, tok.text)
        elseif lowercase(tok.text) in LENS_ACTIONS
            action = lowercase(tok.text)
        elseif !isempty(tok.text)
            push!(qparts, tok.text)
        end
    end
    query = isempty(qparts) ? nothing : join(qparts, " ")
    return LensClause(sign, key, action, query)
end

# Tokenize a clause's params into (text, quoted) tokens: "double quoted" stays
# one token (quotes stripped), otherwise split on whitespace.
function lens_tokens(s::AbstractString)
    toks = NamedTuple{(:text, :quoted),Tuple{String,Bool}}[]
    buf = IOBuffer(); inq = false; have = false
    flush!() = (have && push!(toks, (text = String(take!(buf)), quoted = false)); have = false)
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '"'
            flush!()
            j = nextind(s, i); k = findnext('"', s, j)
            stop = k === nothing ? lastindex(s) : prevind(s, k)
            push!(toks, (text = j > lastindex(s) ? "" : String(s[j:stop]), quoted = true))
            i = k === nothing ? nextind(s, lastindex(s)) : nextind(s, k)
        elseif isspace(c)
            flush!(); i = nextind(s, i)
        else
            print(buf, c); have = true; i = nextind(s, i)
        end
    end
    flush!()
    return toks
end

parse_lens(str::AbstractString)::Vector{LensClause} =
    LensClause[c for (sg, s) in split_lens_clauses(str)
               for c in (parse_clause(sg, s),) if c !== nothing]

# ── Per-message keys + searchable text ───────────────────────────────────────
# The keys a message answers to in a `/<key>` clause. Tools answer to BOTH
# the generic `tool`/`tools` and their specific name.
msg_lens_keys(::UserMsg)     = ["user_message", "user"]
msg_lens_keys(::AgentMsg)    = ["agent", "agent_message"]
msg_lens_keys(::ThoughtMsg)  = ["thought", "thinking"]
msg_lens_keys(::SummaryMsg)  = ["summary"]
msg_lens_keys(::TodoListMsg) = ["plan", "todo", "todos"]
msg_lens_keys(m::ToolMsg)    = ["tool", "tools", tool_key(m)]
msg_lens_keys(::ChatMsg)     = String[]

msg_search_text(m::UserMsg)     = m.text
msg_search_text(m::AgentMsg)    = m.text
msg_search_text(m::ThoughtMsg)  = m.text
msg_search_text(m::SummaryMsg)  = m.text
msg_search_text(m::TodoListMsg) = join((e.content for e in m.entries), " ")
function msg_search_text(m::ToolMsg)
    parts = String[tool_title(m), tool_summary(m)]
    if m isa BashToolMsg
        isempty(m.command) || push!(parts, m.command)
        m.description === nothing || push!(parts, m.description)
    elseif m isa TaskToolMsg
        m.task_name === nothing || push!(parts, m.task_name)
    elseif m isa MCPToolMsg
        push!(parts, tool_key(m))
        m isa JuliaEvalCall && !isempty(m.code) && push!(parts, m.code)
    end
    return join(filter(!isempty, parts), " ")
end
msg_search_text(::ChatMsg) = ""

# Case-insensitive subsequence test ("bt_eval" ⊆ "bt_julia_eval"). Used for
# key matching AND the client-side autocomplete (mirrored in JS).
function subseq_match(needle::AbstractString, haystack::AbstractString)
    isempty(needle) && return true
    n = lowercase(needle); h = lowercase(haystack)
    j = 1
    for ch in h
        j > lastindex(n) && break
        ch == n[j] && (j = nextind(n, j))
    end
    return j > lastindex(n)
end

const LENS_FUZZY_THRESHOLD = 0.75

# Does `text` contain `query`? Exact substring (the common case) OR a fuzzy
# token match (typo / word-reorder tolerant — TokenMax(Levenshtein)).
function lens_text_match(query::AbstractString, text::AbstractString)
    q = lowercase(strip(query))
    isempty(q) && return true
    t = lowercase(text)
    occursin(q, t) && return true
    return similarity(q, t, TokenMax(Levenshtein())) >= LENS_FUZZY_THRESHOLD
end

clause_key_match(c::LensClause, keys::Vector{String}) =
    isempty(c.key) || c.key == "*" || lowercase(c.key) == "all" ||
    any(k -> subseq_match(c.key, k), keys)

# ── Apply ────────────────────────────────────────────────────────────────────
"""
    apply_lens(msgs, clauses) -> (visible::Vector{Int}, actions::Dict{Int,String})

`visible` holds the 0-based indices that should remain shown; `actions` maps a
visible index to the action to apply ("expand" / "collapse"). An empty
`clauses` (no lens) shows everything.

Base rule: `visible = BASE \\ ⋃(exclude matches)`, where BASE is the union of
the include clauses' matches, or ALL messages when there is no include clause
(so `!/thought` alone means "everything but thoughts"). Actions come from the
matching include clauses only (excluded messages are hidden).
"""
function apply_lens(msgs::AbstractVector, clauses::Vector{LensClause})
    actions = Dict{Int,String}()
    isempty(clauses) && return (collect(0:length(msgs)-1), actions)
    includes = filter(c -> c.sign === :include, clauses)
    excludes = filter(c -> c.sign === :exclude, clauses)
    visible = Int[]
    for (i, m) in enumerate(msgs)
        idx0 = i - 1
        keys = msg_lens_keys(m)
        isempty(keys) && continue
        text = Ref{Union{Nothing,String}}(nothing)
        matches(c) = clause_key_match(c, keys) && (c.query === nothing || begin
            text[] === nothing && (text[] = msg_search_text(m))
            lens_text_match(c.query, text[])
        end)
        # In the base set? (any include match, or no include clauses at all)
        included = isempty(includes) ? true : any(matches, includes)
        included || continue
        any(matches, excludes) && continue
        push!(visible, idx0)
        for c in includes
            (c.action !== nothing && matches(c)) && (actions[idx0] = c.action)
        end
    end
    return (visible, actions)
end

# Keys actually present in this chat — drives the `/autocomplete` vocabulary.
# `all` is always offered (the explicit wildcard for `/all - /Bash`).
function lens_vocabulary(msgs::AbstractVector)
    keys = Set{String}(["all"])
    for m in msgs, k in msg_lens_keys(m)
        push!(keys, k)
    end
    return sort!(collect(keys))
end

# ── Saved lenses (global, persisted) ─────────────────────────────────────────
struct SavedLens
    title :: String
    query :: String
    color :: String
end

# Global path — shared across every project. Overridable for tests.
lenses_path() = get(ENV, "BONITOAGENTS_LENSES_PATH",
                    joinpath(homedir(), ".config", "bonitoagents", "lenses.json"))

# A stable, pleasant color from the query (same query → same color).
function lens_color(query::AbstractString)
    h = 0
    for ch in query
        h = (h * 31 + Int(ch)) % 360
    end
    return "hsl($(h), 62%, 52%)"
end

# A short chip title: the clause keys, joined, capped — "user · !thought".
# Exclude clauses get a leading `!` so the title reflects the lens shape.
function lens_title(query::AbstractString)
    clauses = parse_lens(query)
    if isempty(clauses)
        t = strip(query)
    else
        label(c) = (c.sign === :exclude ? "!" : "") * (isempty(c.key) ? "·" : c.key)
        t = join((label(c) for c in clauses), " · ")
    end
    t = replace(t, r"\s+" => " ")
    return length(t) > 22 ? string(first(t, 21), "…") : t
end

function load_saved_lenses()::Vector{SavedLens}
    path = lenses_path()
    isfile(path) || return SavedLens[]
    data = try
        JSON.parsefile(path)
    catch e
        @warn "lenses.json unreadable; ignoring" path exception = e
        return SavedLens[]
    end
    data isa AbstractVector || return SavedLens[]
    out = SavedLens[]
    for d in data
        d isa AbstractDict || continue
        q = get(d, "query", nothing)
        q isa AbstractString && !isempty(q) || continue
        push!(out, SavedLens(String(get(d, "title", lens_title(q))), String(q),
                             String(get(d, "color", lens_color(q)))))
    end
    return out
end

function write_saved_lenses(lenses::Vector{SavedLens})
    path = lenses_path()
    mkpath(dirname(path))
    open(path, "w") do io
        JSON.print(io, [Dict("title" => l.title, "query" => l.query,
                             "color" => l.color) for l in lenses])
    end
    return nothing
end

# Save a lens (dedup by query); returns the full updated list.
function save_lens!(query::AbstractString)::Vector{SavedLens}
    q = strip(query)
    lenses = load_saved_lenses()
    any(l -> l.query == q, lenses) && return lenses
    push!(lenses, SavedLens(lens_title(q), String(q), lens_color(q)))
    write_saved_lenses(lenses)
    return lenses
end

function delete_saved_lens!(query::AbstractString)::Vector{SavedLens}
    lenses = filter(l -> l.query != strip(query), load_saved_lenses())
    write_saved_lenses(lenses)
    return lenses
end

# ── Comm wiring (defined here so `SavedLens` is in scope) ─────────────────────
# The command structs + the InitCommand handler live in chat.jl; these are the
# rest of the lens handlers. `handle_command!`/`chat_emit`/`ChatModel`/`Session`
# all come from chat.jl (included earlier).
emit_lens_vocab(model::ChatModel) =
    chat_emit(model, Dict{String,Any}(
        "type" => "lens.vocab",
        "keys" => lens_vocabulary(lock(() -> copy(model.msgs_store), shared(model).lock))))

emit_saved_lenses(model::ChatModel, lenses::Vector{SavedLens}) =
    chat_emit(model, Dict{String,Any}(
        "type" => "lens.saved",
        "lenses" => [Dict("title" => l.title, "query" => l.query, "color" => l.color)
                     for l in lenses]))

# Per-tab independence on a broadcast channel: the result carries the `q` it
# answers, so a tab applies ONLY results for the query it currently has pending.
function handle_command!(model::ChatModel, ::Session, cmd::LensQueryCommand)
    msgs = lock(() -> copy(model.msgs_store), shared(model).lock)
    visible, actions = apply_lens(msgs, parse_lens(cmd.query))
    chat_emit(model, Dict{String,Any}(
        "type"    => "lens.result",
        "q"       => cmd.query,
        "active"  => !isempty(strip(cmd.query)),
        "visible" => visible,
        "actions" => Dict{String,Any}(string(k) => v for (k, v) in actions)))
    return nothing
end

handle_command!(model::ChatModel, ::Session, cmd::LensSaveCommand) =
    emit_saved_lenses(model, save_lens!(cmd.query))

handle_command!(model::ChatModel, ::Session, cmd::LensDeleteCommand) =
    emit_saved_lenses(model, delete_saved_lens!(cmd.query))
