# ── Change review ───────────────────────────────────────────────────────────
# A workspace tab showing the git diff of the chat's project, with a comment
# affordance on every line. Two modes, because reviewing code is two different
# activities and mixing them is what makes review UIs annoying:
#
#   • ASK — "why is this a Dict?" You want the answer NOW, in the conversation.
#     The question is sent as a chat message the moment you submit it, with the
#     file, line and surrounding code attached so the agent doesn't have to
#     guess what you're pointing at.
#
#   • FEEDBACK — "this should use `muladd`." You are walking the whole diff and
#     collecting changes to make. Sending each one immediately would start N
#     turns that each see a fifth of your intent. So they BATCH: comments pile
#     up in the header, and one Send delivers them as a single numbered
#     instruction the agent can work through.
#
# The diff itself comes from the worker (`git_diff_on_worker`) as one unified
# patch and is parsed here — parsing on the server keeps the worker side to
# plumbing and makes `parse_unified_diff` testable headlessly.

# ── unified diff parsing ────────────────────────────────────────────────────

"""
    DiffLine(kind, old_no, new_no, text)

One rendered row of a diff. `kind` is `:context`, `:add`, `:del` or `:note` (a
`\\ No newline at end of file` marker). Line numbers are 0 where that side has
none — a `:add` row has no old number, a `:del` row has no new one.
"""
struct DiffLine
    kind   :: Symbol
    old_no :: Int
    new_no :: Int
    text   :: String
end

struct DiffHunk
    header :: String            # the raw `@@ … @@ heading` line
    lines  :: Vector{DiffLine}
end

mutable struct DiffFile
    path      :: String         # the NEW path (the old one for a deletion)
    old_path  :: String
    status    :: Symbol         # :modified | :added | :deleted | :renamed
    binary    :: Bool
    hunks     :: Vector{DiffHunk}
    additions :: Int
    deletions :: Int
end

DiffFile(path::AbstractString) =
    DiffFile(String(path), String(path), :modified, false, DiffHunk[], 0, 0)

diff_total_lines(files) = sum(f -> sum(h -> length(h.lines), f.hunks; init = 0), files; init = 0)

# `diff --git a/x b/x` → the two paths.
#
# Paths CAN contain spaces, so splitting on whitespace is wrong for exactly the
# files people complain about. What makes this parseable at all is that for
# everything except a rename the two halves are the SAME path: try each " b/" as
# the separator and take the one where the tails match. That is exact for spaces
# and for multibyte names (the offsets land on the ASCII separator, never inside
# a character).
#
# A rename (`diff --git a/old b/new`) has no matching tails and falls back to the
# last space — ambiguous in principle, but the `rename from` / `rename to` lines
# that follow it carry the real names and overwrite these.
function parse_diff_git_line(rest::AbstractString)
    s = String(rest)
    if startswith(s, "a/")
        for m in eachmatch(r" b/", s)
            a = s[3:(m.offset - 1)]
            b = s[(m.offset + 3):end]
            a == b && return (a, b)
        end
    end
    sp = findlast(' ', s)
    sp === nothing && return (s, s)
    a = s[1:(sp - 1)]; b = s[(sp + 1):end]
    strip_prefix(p) = startswith(p, "a/") || startswith(p, "b/") ? p[3:end] : p
    return (strip_prefix(a), strip_prefix(b))
end

# The path off a `--- ` / `+++ ` header. Unified diff separates the path from an
# optional timestamp with a TAB, so everything from the first tab on is metadata,
# not part of the name.
function diff_header_path(rest::AbstractString)
    s = String(rest)
    t = findfirst('\t', s)
    return t === nothing ? s : s[1:prevind(s, t)]
end

# `@@ -12,7 +12,9 @@ heading` → (old_start, new_start). A one-line range omits
# the count (`@@ -1 +1 @@`), which is why the counts are optional here.
const HUNK_RX = r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"

"""
    parse_unified_diff(patch) -> Vector{DiffFile}

Parse `git diff` output into per-file hunks with both sides' line numbers.
Handles adds / deletes / renames / binary files, and tolerates the surrounding
`index`, `mode` and `similarity` lines git emits. Content lines are kept
verbatim minus their leading +/-/space marker.
"""
function parse_unified_diff(patch::AbstractString)
    files = DiffFile[]
    cur::Union{DiffFile,Nothing} = nothing
    hunk::Union{DiffHunk,Nothing} = nothing
    old_no = new_no = 0
    for raw in eachsplit(patch, '\n')
        line = String(raw)
        if startswith(line, "diff --git ")
            a, b = parse_diff_git_line(line[12:end])
            cur = DiffFile(b); cur.old_path = a
            hunk = nothing
            push!(files, cur)
        elseif cur === nothing
            continue                       # preamble before the first file
        elseif startswith(line, "new file mode")
            cur.status = :added
        elseif startswith(line, "deleted file mode")
            cur.status = :deleted
        elseif startswith(line, "rename from ")
            cur.status = :renamed; cur.old_path = line[13:end]
        elseif startswith(line, "rename to ")
            cur.status = :renamed; cur.path = line[11:end]
        elseif startswith(line, "Binary files ") || startswith(line, "GIT binary patch")
            cur.binary = true
        elseif startswith(line, "--- ")
            p = diff_header_path(line[5:end])
            p == "/dev/null" ? (cur.status = :added) :
                (cur.old_path = startswith(p, "a/") ? p[3:end] : p)
        elseif startswith(line, "+++ ")
            p = diff_header_path(line[5:end])
            p == "/dev/null" ? (cur.status = :deleted) :
                (cur.path = startswith(p, "b/") ? p[3:end] : p)
        elseif (m = match(HUNK_RX, line)) !== nothing
            old_no = parse(Int, m.captures[1])
            new_no = parse(Int, m.captures[2])
            hunk = DiffHunk(line, DiffLine[])
            push!(cur.hunks, hunk)
        elseif hunk !== nothing
            if startswith(line, "+")
                push!(hunk.lines, DiffLine(:add, 0, new_no, line[2:end]))
                new_no += 1; cur.additions += 1
            elseif startswith(line, "-")
                push!(hunk.lines, DiffLine(:del, old_no, 0, line[2:end]))
                old_no += 1; cur.deletions += 1
            elseif startswith(line, "\\")
                push!(hunk.lines, DiffLine(:note, 0, 0, strip(line[2:end])))
            elseif startswith(line, " ") || isempty(line)
                # A fully empty context line loses its leading space in some
                # producers; treat it as the empty context row it is. But an
                # empty FINAL element is just the trailing newline of the patch.
                push!(hunk.lines, DiffLine(:context, old_no, new_no, isempty(line) ? "" : line[2:end]))
                old_no += 1; new_no += 1
            end
        end
    end
    # A trailing "" line from the patch's final newline lands as one bogus
    # context row on the last hunk; drop it so line numbers stay honest.
    if !isempty(files) && !isempty(files[end].hunks)
        h = files[end].hunks[end]
        if !isempty(h.lines) && h.lines[end].kind === :context && isempty(h.lines[end].text) &&
           !endswith(patch, "\n\n")
            pop!(h.lines)
        end
    end
    return files
end

# ── the panel ───────────────────────────────────────────────────────────────

"""
    ReviewComment(file, line, end_line, side, snippet, text)

One note the user attached to a diff line — or to a BLOCK of them, which is what
most review comments are actually about ("this loop", "this branch"). `end_line`
equals `line` for a single-line note; shift-clicking a second `+` in the same
hunk extends the range.

`snippet` is the code context as it was ON SCREEN (the browser sends it with the
comment), so the message the agent receives shows exactly what the user was
looking at — no re-derivation, no drift if the file changed in between.
"""
struct ReviewComment
    file     :: String
    line     :: Int
    end_line :: Int
    side     :: String       # "new" | "old"
    snippet  :: String
    text     :: String
end

ReviewComment(file, line, side, snippet, text) =
    ReviewComment(file, line, line, side, snippet, text)

# How a comment names its target, for the agent and for the pending-comment chip.
comment_location(c::ReviewComment) =
    c.end_line > c.line ? "$(c.file):$(c.line)-$(c.end_line)" : "$(c.file):$(c.line)"

# A comment on a DELETED line carries its OLD line number — that line isn't in
# the file any more, so handing the agent a bare `path:42` sends it to read
# whatever occupies line 42 now, which is unrelated code. Say which side the
# number is from. Only for the old side: the new-side numbers (the overwhelming
# majority, and the ones a `path:line` reference is expected to mean) stay clean.
old_side_note(c::ReviewComment) =
    c.side == "old" ? " — a line this change REMOVED, so that number is from before the change" : ""

# Rendering the whole diff of a big branch would put a hundred thousand nodes in
# the DOM. Cap it and SAY SO in the header — a review pane that silently drops
# half the changes is worse than one that admits it.
const REVIEW_MAX_LINES = 15_000
# Files bigger than this open collapsed (still in the DOM, just not laid out).
const REVIEW_AUTO_OPEN_LINES = 400

struct ReviewPanel
    model     :: ChatModel
    base      :: Observable{String}          # "" ⇒ working tree vs HEAD
    mode      :: Observable{String}          # "ask" | "feedback"
    comments  :: Observable{Vector{ReviewComment}}
    reload    :: Observable{Int}
    status    :: Observable{String}
    # JS → Julia: a submitted comment box,
    # `{file, line, end_line, side, snippet, text}`.
    submit    :: Observable{Any}
    # JS → Julia: drop the comment at this 1-based index (the ✕ on a pending chip).
    drop      :: Observable{Int}
    # JS → Julia: pulse to send the batch.
    send      :: Observable{Int}
    # JS → Julia: open this repo-relative path as a file tab. Reading a diff and
    # wanting the whole file is the most common next move there is.
    open_path :: Observable{String}
end

ReviewPanel(model::ChatModel; base::AbstractString = "") =
    ReviewPanel(model, Observable(String(base)), Observable("ask"),
                Observable(ReviewComment[]), Observable(0), Observable(""),
                Observable{Any}(nothing), Observable(0), Observable(0), Observable(""))

review_tab_id(project_id::AbstractString) = "review:" * String(project_id)

# The worker path whose repository we review: the project's own directory.
function review_worker_path(model::ChatModel)
    proj = get(model.state.projects[], model.project_id, nothing)
    proj === nothing && return model.cwd
    return proj.worker_path
end

function review_worker_id(model::ChatModel)
    proj = get(model.state.projects[], model.project_id, nothing)
    return proj === nothing ? "" : proj.worker_id
end

# ── message composition ─────────────────────────────────────────────────────
# What the agent actually receives. Worth getting right: a comment without its
# file, line and code is a riddle, and a batch without numbering gets half
# addressed.

"""
    fence_for(text) -> String

A code fence long enough to contain `text`. Reviewing this repo means reviewing
its markdown, and a snippet lifted out of a `.md` diff routinely contains its own
```` ``` ```` — inside a three-backtick fence that ends the block early and the
rest of the comment lands as prose. CommonMark's rule is that the closing fence
must be at least as long as the opening one, so we open with one backtick more
than the longest run in the snippet.
"""
function fence_for(text::AbstractString)
    longest = 0
    run = 0
    for ch in text
        if ch == '`'
            run += 1
            run > longest && (longest = run)
        else
            run = 0
        end
    end
    return "`"^max(3, longest + 1)
end

# Emit `snippet` as a fenced block that can't be broken out of, always ending on
# its own line (a snippet without a trailing newline would otherwise glue the
# closing fence onto the last line of code).
function print_fenced(io::IO, snippet::AbstractString)
    fence = fence_for(snippet)
    println(io, fence)
    print(io, snippet)
    endswith(snippet, "\n") || println(io)
    println(io, fence)
    return nothing
end

function review_ask_message(c::ReviewComment, repo::AbstractString)
    io = IOBuffer()
    println(io, "Question about `", comment_location(c), "`",
                isempty(repo) ? "" : " (in `$(repo)`)", old_side_note(c), ":")
    println(io)
    print_fenced(io, c.snippet)
    println(io)
    println(io, c.text)
    return String(take!(io))
end

function review_feedback_message(comments::Vector{ReviewComment},
                                 repo::AbstractString, base::AbstractString)
    io = IOBuffer()
    n = length(comments)
    println(io, "Code review: ", n, n == 1 ? " comment" : " comments", " on the changes",
                isempty(repo) ? "" : " in `$(repo)`",
                isempty(base) ? "" : " (diff vs `$(base)`)", ".")
    println(io)
    println(io, "Please address each one. Stick to what the comments ask for — ",
                "don't refactor anything they don't mention.")
    for (i, c) in enumerate(comments)
        println(io)
        println(io, "## ", i, ". `", comment_location(c), "`", old_side_note(c))
        println(io)
        print_fenced(io, c.snippet)
        println(io)
        println(io, c.text)
    end
    return String(take!(io))
end

# ── DOM ─────────────────────────────────────────────────────────────────────

diff_status_label(f::DiffFile) =
    f.status === :added   ? "added"   :
    f.status === :deleted ? "deleted" :
    f.status === :renamed ? "renamed" : "modified"

function review_line_row(file::AbstractString, l::DiffLine)
    cls = l.kind === :add  ? "bt-rv-line bt-rv-add" :
          l.kind === :del  ? "bt-rv-line bt-rv-del" :
          l.kind === :note ? "bt-rv-line bt-rv-note" : "bt-rv-line"
    # A note row (`\ No newline at end of file`) is metadata, not code: no line
    # numbers and no comment affordance.
    l.kind === :note && return DOM.div(
        DOM.span(""; class = "bt-rv-num"), DOM.span(""; class = "bt-rv-num"),
        DOM.span(l.text; class = "bt-rv-code"); class = cls)
    # Comments anchor to the NEW side where there is one (that's the code that
    # will exist after the change, which is what feedback is about); a deleted
    # line anchors to its old number.
    side = l.new_no > 0 ? "new" : "old"
    lineno = l.new_no > 0 ? l.new_no : l.old_no
    return DOM.div(
        DOM.span(l.old_no > 0 ? string(l.old_no) : ""; class = "bt-rv-num bt-rv-num-old"),
        DOM.span(l.new_no > 0 ? string(l.new_no) : ""; class = "bt-rv-num bt-rv-num-new"),
        DOM.span(l.text; class = "bt-rv-code"),
        DOM.button("+"; class = "bt-rv-plus", type = "button",
                   title = "Comment on this line");
        class = cls, dataFile = String(file), dataLine = string(lineno), dataSide = side)
end

# Paths in a patch are relative to the git ROOT; everything downstream of this
# tab wants them relative to the PROJECT. The agent's working directory is the
# project folder, so a root-relative `pkg/member.jl` sent as a comment location
# points at `pkg/pkg/member.jl` from where it is standing; `open_project_file!`
# resolves a relative path against the project too. And on screen the shared
# prefix is pure noise — the folder the whole tab is about, pushing the filename
# right, which is what the left-truncation exists to prevent.
#
# So strip it once, here, and use the result for display, `data-file` and the ⤢
# target alike. The file header's `title` keeps the root-relative path, so
# hovering still tells you where the file sits in the repository.
# `chopprefix`, not an index slice: `length` counts CHARACTERS while string
# indices are BYTES, so slicing at `length(prefix)` mangles any path whose folder
# name isn't ASCII — `bücher/a.jl` came out as `/a.jl`. These paths are what the
# agent is told and what ⤢ opens, so a mangled one is a broken feature, not a
# cosmetic slip.
display_path(path::AbstractString, prefix::AbstractString) =
    isempty(prefix) ? path : chopprefix(path, prefix)

function review_file_section(f::DiffFile, prefix::AbstractString = "")
    nlines = sum(h -> length(h.lines), f.hunks; init = 0)
    shown_path = display_path(f.path, prefix)
    head = DOM.summary(
        DOM.span(diff_status_label(f); class = "bt-rv-file-status", dataStatus = string(f.status)),
        # `title` keeps the root-relative path, so hovering still tells you where
        # the file really is inside the repository.
        path_span(f.status === :renamed ?
                      "$(display_path(f.old_path, prefix)) → $(shown_path)" : shown_path;
                  class = "bt-rv-file-path", title = f.path),
        DOM.span("+$(f.additions)"; class = "bt-rv-plus-count"),
        DOM.span("−$(f.deletions)"; class = "bt-rv-minus-count"),
        # Open the WHOLE file in its own tab. A separate button rather than a
        # clickable path, so it doesn't fight the <details> disclosure toggle.
        DOM.button("⤢"; class = "bt-rv-open", type = "button",
                   title = "Open this file", dataOpen = shown_path))
    body = if f.binary
        DOM.div("binary file — no textual diff"; class = "bt-rv-binary")
    elseif isempty(f.hunks)
        DOM.div("no textual changes"; class = "bt-rv-binary")
    else
        DOM.div((DOM.div(
                    DOM.div(h.header; class = "bt-rv-hunk-head"),
                    (review_line_row(shown_path, l) for l in h.lines)...;
                    class = "bt-rv-hunk") for h in f.hunks)...;
                class = "bt-rv-hunks")
    end
    return DOM.details(head, body;
        class = "bt-rv-file",
        (nlines <= REVIEW_AUTO_OPEN_LINES ? (; open = true) : (;))...)
end

# The pending-comment tray (feedback mode). Each chip is removable, and clicking
# one scrolls the diff to the line it belongs to — a 20-comment review is
# unusable if you can't get back to what you wrote.
function review_pending_tray(comments::Vector{ReviewComment})
    isempty(comments) && return DOM.div(; class = "bt-rv-tray", dataEmpty = "1")
    chips = [DOM.div(
        DOM.span("$(i).", class = "bt-rv-chip-n"),
        DOM.span(basename(comment_location(c)); class = "bt-rv-chip-loc", title = c.file),
        DOM.span(first(split(c.text, '\n')); class = "bt-rv-chip-text", title = c.text),
        DOM.button("✕"; class = "bt-rv-chip-drop", type = "button",
                   title = "Remove this comment", dataIndex = string(i));
        class = "bt-rv-chip", dataFile = c.file, dataLine = string(c.line))
        for (i, c) in enumerate(comments)]
    return DOM.div(chips...; class = "bt-rv-tray")
end

function Bonito.jsrender(session::Session, rp::ReviewPanel)
    model = rp.model
    repo_txt   = Observable("")
    branch_txt = Observable("")
    stat_txt   = Observable("loading…")

    # The diff arrives ASYNCHRONOUSLY. `git_diff_on_worker` is a worker
    # round-trip that can take seconds on a big repo (and has a 60s timeout), so
    # computing it inside a `map` would park the session's task for that long —
    # freezing every other Observable in the tab. Instead the tab opens
    # immediately on a placeholder and swaps in the diff when it lands.
    diff_dom = Observable{Any}(DOM.div("reading the diff from the worker…";
                                       class = "bt-rv-empty"))

    build_diff() = begin
        base = rp.base[]
        wid = review_worker_id(model)
        isempty(wid) && (safe_set!(stat_txt, "");
                         return DOM.div("This chat has no project on a worker to diff.";
                                        class = "bt-rv-empty"))
        res = try
            git_diff_on_worker(model.state, wid, review_worker_path(model); base = base)
        catch e
            @warn "review: git diff failed" project = model.project_id exception = e
            safe_set!(stat_txt, "")
            return DOM.div(
                DOM.div("Could not read the diff"; class = "bt-fv-error-title"),
                DOM.div(first(split(sprint(showerror, e), '\n')); class = "bt-fv-error-detail");
                class = "bt-tool-error bt-rv-error")
        end
        # Name what is actually on screen. The diff is scoped to the project's
        # folder, so showing a bare repo root next to it would claim more than the
        # tab is showing whenever the project sits inside a bigger checkout.
        safe_set!(repo_txt, isempty(res.scope) ? res.repo :
                            rstrip(res.repo, '/') * "/" * res.scope)
        safe_set!(branch_txt, isempty(res.branch) ? res.head : res.branch)
        files = parse_unified_diff(res.patch)
        if isempty(files)
            safe_set!(stat_txt, "no changes")
            return DOM.div(
                isempty(base) ? "Nothing has changed since the last commit." :
                                "Nothing differs from `$(base)`.";
                class = "bt-rv-empty")
        end
        adds = sum(f -> f.additions, files; init = 0)
        dels = sum(f -> f.deletions, files; init = 0)
        # Cap the rendered set, and say exactly what was left out — a review pane
        # that quietly shows 60% of the diff is worse than one that admits it.
        shown = DiffFile[]
        used = 0
        for f in files
            n = sum(h -> length(h.lines), f.hunks; init = 0)
            (used + n > REVIEW_MAX_LINES && !isempty(shown)) && break
            push!(shown, f); used += n
        end
        dropped = length(files) - length(shown)
        safe_set!(stat_txt,
            "$(length(files)) file$(length(files) == 1 ? "" : "s") · +$(adds) −$(dels)" *
            (dropped > 0 ? " · $(dropped) more file$(dropped == 1 ? "" : "s") not shown " *
                           "(diff past $(REVIEW_MAX_LINES) lines)" : ""))
        # Rows drop the scope prefix they all share; the header carries it instead.
        prefix = isempty(res.scope) ? "" : rstrip(res.scope, '/') * "/"
        return DOM.div((review_file_section(f, prefix) for f in shown)...; class = "bt-rv-files")
    end

    refresh_diff!() = Base.errormonitor(@async begin
        safe_set!(stat_txt, "reading…")
        safe_set!(diff_dom, build_diff())
    end)
    # ⟳ and a base change both mean "go ask again".
    on(session, rp.reload) do _; refresh_diff!(); end
    on(session, rp.base)   do _; refresh_diff!(); end
    refresh_diff!()
    body = diff_dom

    base_input = DOM.input(; type = "text", class = "bt-rv-base",
        placeholder = "vs HEAD", value = rp.base,
        title = "Compare against a branch, tag or commit. Empty = the working tree vs HEAD.",
        onchange = js"event => $(rp.base).notify(event.target.value.trim())")

    # Session-scoped `map`s: their parent→child callbacks are registered on this
    # render's session and torn down with it, so closing the tab doesn't leave
    # listeners on the panel's observables.
    # Send is the primary action only when it HAS something to deliver: before the
    # first comment (and throughout Ask mode) a full-strength primary button is an
    # invitation to press something that can only answer "no comments to send".
    #
    # The whole button is rebuilt rather than given a reactive `dataEmpty`:
    # Bonito's attribute updates assign a JS PROPERTY (`node[attr] = value`), so a
    # `data-*` attribute — which has no reflecting property — takes the update on
    # an expando and leaves the real attribute frozen at its initial value. The
    # count in the label would track the tray while the styling it keys on stayed
    # stuck at empty. Nothing is lost by rebuilding: the click is delegated from
    # the panel root, so no per-node listener dies with the swap.
    send_btn = map(session, rp.comments) do cs
        n = length(cs)
        DOM.button(n == 0 ? "Send" : "Send $(n) comment$(n == 1 ? "" : "s")";
            class = "bt-btn bt-btn-sm bt-rv-send", type = "button",
            dataEmpty = n == 0 ? "1" : "0",
            title = "Deliver every collected comment to the agent as one instruction")
    end

    mode_hint = map(session, rp.mode) do m
        (m == "ask" ? "Ask — your question goes to the chat immediately." :
                      "Feedback — comments collect here; Send delivers them as one instruction.") *
        "  ·  + comments on a line; shift-click a second + to cover a block."
    end

    header = DOM.div(
        DOM.span("⑂"; class = "bt-fv-icon"),
        path_span(repo_txt; class = "bt-file-editor-path bt-rv-repo"),
        DOM.span(branch_txt; class = "bt-fv-badge"),
        DOM.span(stat_txt; class = "bt-rv-stat"),
        DOM.span(rp.status; class = "bt-file-editor-status"),
        DOM.div(
            base_input,
            DOM.div(
                DOM.button("Ask"; class = "bt-fv-seg", type = "button", dataRvMode = "ask"),
                DOM.button("Feedback"; class = "bt-fv-seg", type = "button", dataRvMode = "feedback");
                class = "bt-fv-segmented"),
            DOM.button("⟳"; class = "bt-fv-act", type = "button",
                       title = "Re-read the diff from the worker", dataRvAction = "reload"),
            send_btn;
            class = "bt-fv-actions");
        class = "bt-file-editor-header bt-rv-header")

    node = DOM.div(
        header,
        DOM.div(mode_hint; class = "bt-rv-hint"),
        DOM.div(map(review_pending_tray, session, rp.comments); class = "bt-rv-tray-wrap"),
        DOM.div(body; class = "bt-rv-body");
        class = "bt-review", dataMode = rp.mode[])

    # ── Julia-side handlers ─────────────────────────────────────────────────
    on(session, rp.submit) do payload
        payload isa AbstractDict || return
        text = strip(String(get(payload, "text", "")))
        isempty(text) && return
        line = round(Int, get(payload, "line", 0))
        c = ReviewComment(String(get(payload, "file", "")),
                          line,
                          max(line, round(Int, get(payload, "end_line", line))),
                          String(get(payload, "side", "new")),
                          String(get(payload, "snippet", "")),
                          String(text))
        if rp.mode[] == "ask"
            if !model.session_alive[]
                safe_set!(rp.status, "no live session — start the chat first")
                return
            end
            try
                send_message!(model, UserMsg(review_ask_message(c, repo_txt[])))
                safe_set!(rp.status, "asked in the chat")
            catch e
                @warn "review: ask failed" exception = (e, catch_backtrace())
                safe_set!(rp.status, "could not ask: $(first(split(sprint(showerror, e), '\n')))")
            end
        else
            safe_set!(rp.comments, push!(copy(rp.comments[]), c))
            safe_set!(rp.status, "")
        end
    end

    # Open a file from the diff, through the same guarded path everything else
    # uses — so a file that has been deleted in the working tree toasts instead
    # of opening an empty tab.
    on(session, rp.open_path) do rel
        isempty(rel) && return
        pane = model.plotpane
        pane === nothing && (safe_set!(rp.status, "no workspace to open into"); return)
        # `rel` is relative to the PROJECT (the rows strip the scope prefix — see
        # `display_path`), and `open_project_file!` resolves a relative path
        # against the project's worker path. So it goes straight through. It used
        # to be joined with the repo root instead, which broke the moment the
        # header started naming the scope: `<repo>/pkg` + `pkg/member.jl`.
        open_project_file!(pane, model.state, model.project_id, model.cwd, String(rel))
    end

    on(session, rp.drop) do i
        cs = rp.comments[]
        (1 <= i <= length(cs)) || return
        safe_set!(rp.comments, deleteat!(copy(cs), i))
    end

    on(session, rp.send) do _
        cs = rp.comments[]
        isempty(cs) && (safe_set!(rp.status, "no comments to send"); return)
        if !model.session_alive[]
            safe_set!(rp.status, "no live session — start the chat first")
            return
        end
        try
            send_message!(model, UserMsg(review_feedback_message(cs, repo_txt[], rp.base[])))
            # Clear only AFTER the send succeeded: a failure that also ate the
            # comments would lose a whole review pass.
            safe_set!(rp.comments, ReviewComment[])
            safe_set!(rp.status, "sent $(length(cs)) comment$(length(cs) == 1 ? "" : "s")")
        catch e
            @warn "review: send failed" exception = (e, catch_backtrace())
            safe_set!(rp.status, "could not send: $(first(split(sprint(showerror, e), '\n')))")
        end
    end

    # ── browser side ────────────────────────────────────────────────────────
    # All of the interaction (open a box, type, submit, cancel) is local: the
    # server only hears about a finished comment. That keeps typing responsive
    # and means a flaky link can't eat half-written feedback.
    Bonito.onload(session, node, js"""(root) => {
        const submit = $(rp.submit);
        const drop   = $(rp.drop);
        const send   = $(rp.send);
        const reload = $(rp.reload);
        const openPath = $(rp.open_path);
        const modeObs = $(rp.mode);
        const CONTEXT = 3;   // lines of code quoted on each side of the target

        const setMode = (m) => {
            root.dataset.mode = m;
            root.querySelectorAll('[data-rv-mode]').forEach(
                b => b.dataset.active = (b.dataset.rvMode === m) ? '1' : '0');
            modeObs.notify(m);
        };
        setMode(root.dataset.mode || 'ask');

        // The code the user is pointing at, as they SEE it: the selected rows plus
        // a few either side, each prefixed with its line number and marked so the
        // agent can tell exactly which ones the comment is about.
        const rowsOf = (row) => [...row.closest('.bt-rv-hunk').querySelectorAll('.bt-rv-line')];
        const snippetFor = (fromRow, toRow) => {
            const rows = rowsOf(fromRow);
            const i = rows.indexOf(fromRow), j = rows.indexOf(toRow);
            const from = Math.max(0, i - CONTEXT), to = Math.min(rows.length - 1, j + CONTEXT);
            const out = [];
            for (let k = from; k <= to; k++) {
                const r = rows[k];
                const n = r.querySelector('.bt-rv-num-new')?.textContent
                       || r.querySelector('.bt-rv-num-old')?.textContent || '';
                const sign = r.classList.contains('bt-rv-add') ? '+'
                           : r.classList.contains('bt-rv-del') ? '-' : ' ';
                const mark = (k >= i && k <= j) ? '>' : ' ';
                out.push(mark + ' ' + String(n).padStart(5) + ' ' + sign +
                         (r.querySelector('.bt-rv-code')?.textContent ?? ''));
            }
            return out.join('\\n');
        };
        const lineOf = (row) => parseInt(row.dataset.line, 10) || 0;

        // Closing also drops the range highlight — including a previous form's,
        // which `openForm` replaces without getting a chance to clean up.
        const closeForm = () => {
            root.querySelector('.bt-rv-form')?.remove();
            root.querySelectorAll('.bt-rv-line[data-selected]')
                .forEach(r => { delete r.dataset.selected; });
        };
        // The last `+` you clicked — shift-clicking another extends from it.
        let anchor = null;

        const openForm = (fromRow, toRow) => {
            closeForm();
            const form = document.createElement('div');
            form.className = 'bt-rv-form';
            const ta = document.createElement('textarea');
            ta.className = 'bt-rv-input';
            ta.placeholder = root.dataset.mode === 'ask'
                ? 'Ask about this line — sent to the chat right away (Ctrl+Enter)'
                : 'What should change here? (Ctrl+Enter to add)';
            const actions = document.createElement('div');
            actions.className = 'bt-rv-form-actions';
            const ok = document.createElement('button');
            ok.type = 'button';
            ok.className = 'bt-btn bt-btn-sm';
            ok.textContent = root.dataset.mode === 'ask' ? 'Ask' : 'Add';
            const cancel = document.createElement('button');
            cancel.type = 'button';
            cancel.className = 'bt-rv-form-cancel';
            cancel.textContent = 'Cancel';
            actions.append(ok, cancel);
            form.append(ta, actions);
            toRow.after(form);
            ta.focus();

            const rows = rowsOf(fromRow);
            const span = rows.slice(rows.indexOf(fromRow), rows.indexOf(toRow) + 1);
            // Show what the comment will cover while you type it.
            span.forEach(r => r.dataset.selected = '1');

            const fire = () => {
                const text = ta.value.trim();
                if (!text) { closeForm(); return; }
                // The line numbers are a POINTER (they can mix sides when a range
                // spans a -/+ pair); the snippet is the authoritative content, and
                // it marks every selected row.
                submit.notify({
                    file: fromRow.dataset.file,
                    line: lineOf(fromRow),
                    end_line: lineOf(toRow),
                    side: fromRow.dataset.side || 'new',
                    snippet: snippetFor(fromRow, toRow),
                    text: text,
                });
                closeForm();
                // Mark the lines so a long review shows where you've been.
                span.forEach(r => r.dataset.commented = '1');
            };
            ok.addEventListener('click', fire);
            cancel.addEventListener('click', closeForm);
            ta.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') { e.stopPropagation(); closeForm(); }
                else if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); fire(); }
            });
        };

        root.addEventListener('click', (e) => {
            const mode = e.target.closest('[data-rv-mode]');
            if (mode) { setMode(mode.dataset.rvMode); return; }
            const open = e.target.closest('.bt-rv-open');
            if (open) {
                // Inside a <summary>: don't let the click also toggle the section.
                e.preventDefault(); e.stopPropagation();
                openPath.notify(open.dataset.open);
                return;
            }
            const act = e.target.closest('[data-rv-action]');
            if (act && act.dataset.rvAction === 'reload') { reload.notify(Date.now()); return; }
            if (e.target.closest('.bt-rv-send')) { send.notify(Date.now()); return; }
            const chipDrop = e.target.closest('.bt-rv-chip-drop');
            if (chipDrop) { drop.notify(parseInt(chipDrop.dataset.index, 10)); return; }
            const chip = e.target.closest('.bt-rv-chip');
            if (chip) {
                // Jump back to the line a pending comment belongs to.
                const sel = '.bt-rv-line[data-line="' + chip.dataset.line + '"]';
                for (const r of root.querySelectorAll(sel)) {
                    if (r.dataset.file !== chip.dataset.file) continue;
                    r.closest('details')?.setAttribute('open', '');
                    r.scrollIntoView({ block: 'center' });
                    r.classList.add('bt-rv-flash');
                    setTimeout(() => r.classList.remove('bt-rv-flash'), 1200);
                    break;
                }
                return;
            }
            const plus = e.target.closest('.bt-rv-plus');
            if (plus) {
                const row = plus.closest('.bt-rv-line');
                // Shift-click extends from the last + you clicked, so a comment
                // can cover a BLOCK — which is what most review notes are about.
                // Only within one hunk: a range that spans a `@@` gap isn't a
                // contiguous piece of code and its line numbers wouldn't be one
                // either.
                let from = row, to = row;
                if (e.shiftKey && anchor && anchor.isConnected &&
                    anchor.closest('.bt-rv-hunk') === row.closest('.bt-rv-hunk')) {
                    const rows = rowsOf(row);
                    const i = rows.indexOf(anchor), j = rows.indexOf(row);
                    from = rows[Math.min(i, j)]; to = rows[Math.max(i, j)];
                }
                anchor = row;
                openForm(from, to);
                return;
            }
        });
    }""")
    return Bonito.jsrender(session, node)
end

"""
    open_review!(pane, model; base = "")

Open (or focus + refresh) the change-review tab for `model`'s project in the
window's workspace. One tab per chat: re-opening reuses it so a half-written
batch of feedback survives clicking around.
"""
function open_review!(pane::PlotPane, model::ChatModel; base::AbstractString = "")
    ws = pane.workspace[]
    ws === nothing && return nothing
    id = review_tab_id(model.project_id)
    existing = findfirst(p -> p.id == id, ws.panels[])
    if existing !== nothing
        BonitoWidgets.activate_panel!(ws, id)
        panel = ws.panels[][existing].content
        # Re-reading on focus is the behaviour you want: you come back to this
        # tab after the agent did something, and it should show what it did.
        panel isa ReviewPanel && safe_set!(panel.reload, panel.reload[] + 1)
        return nothing
    end
    BonitoWidgets.add_panel!(ws, BonitoWidgets.Panel(id, ReviewPanel(model; base);
        label = "Changes", closable = true))
    return nothing
end
