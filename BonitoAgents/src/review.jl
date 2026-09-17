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

"""
    ReviewState

Everything the change-review tab remembers about a project, held on `ServerState`
rather than on the panel.

The panel does NOT survive a page reload: the workspace is rebuilt and
`open_review!` constructs a fresh `ReviewPanel`. Anything owned by the old panel
went with it — which repository was being reviewed, what it was being diffed
against, whether you were in Ask or Feedback mode, and every comment collected
but not yet sent. The last one is the reason this type exists: losing a
half-written review to an accidental F5 is not a cost worth paying for a
simpler struct.

The JS→Julia channels (`submit`, `drop`, `send`, `open_path`, `reload`) live here
too. They are re-interpolated on each render and only the current session has
listeners on them, so sharing them across renders costs nothing and keeps
"the tab's state" in ONE place rather than split by lifetime.
"""
struct ReviewState
    base      :: Observable{String}          # "" ⇒ working tree vs HEAD
    mode      :: Observable{String}          # "ask" | "feedback"
    comments  :: Observable{Vector{ReviewComment}}
    reload    :: Observable{Int}
    status    :: Observable{String}
    # WHICH folder is being reviewed, as an absolute worker path. "" until the
    # repository scan has decided (see `pick_review_folder`) — a project folder
    # that is not itself a checkout has nothing to show until the user picks one.
    folder    :: Observable{String}
    # The checkouts found at or under the project, absolute worker paths, filled
    # in by the scan — which lands AFTER the first render, so the picker has to
    # rebuild on it.
    repos     :: Observable{Vector{String}}
    # JS → Julia: a submitted comment box,
    # `{file, line, end_line, side, snippet, text}`.
    submit    :: Observable{Any}
    # JS → Julia: drop the comment at this 1-based index (the ✕ on a pending chip).
    drop      :: Observable{Int}
    # JS → Julia: pulse to send the batch.
    send      :: Observable{Int}
    # JS → Julia: open this PROJECT-relative path as a file tab. Reading a diff
    # and wanting the whole file is the most common next move there is.
    open_path :: Observable{String}
end

ReviewState(; base::AbstractString = "", folder::AbstractString = "") =
    ReviewState(Observable(String(base)), Observable("ask"),
                Observable(ReviewComment[]), Observable(0), Observable(""),
                Observable(String(folder)), Observable(String[]),
                Observable{Any}(nothing), Observable(0), Observable(0), Observable(""))

"""
    review_state!(state, project_id; base = "") -> ReviewState

The project's review state, created on first use. One per project for the life of
the server, which is what makes a reload a re-render rather than a reset.

Under the lock: a reload can race the old session's teardown, and two of these
would silently split the tab's state in half — the picker reading one, the
comment tray the other.
"""
function review_state!(state::ServerState, project_id::AbstractString;
                       base::AbstractString = "")
    id = String(project_id)
    return lock(state.lock) do
        existing = get(state.review_states, id, nothing)
        existing isa ReviewState && return existing
        st = ReviewState(; base)
        state.review_states[id] = st
        return st
    end
end

# Drop a project's review state — it is keyed by project id, so leaving it behind
# would hand a NEW project that reuses the id someone else's pending comments.
forget_review_state!(state::ServerState, project_id::AbstractString) =
    lock(state.lock) do
        delete!(state.review_states, String(project_id))
        return nothing
    end

struct ReviewPanel
    model :: ChatModel
    st    :: ReviewState
end

ReviewPanel(model::ChatModel; base::AbstractString = "") =
    ReviewPanel(model, review_state!(model.state, model.project_id; base))

review_tab_id(project_id::AbstractString) = "review:" * String(project_id)

# The project's own directory on the worker — where the repository scan starts
# and the frame every path the tab hands out is relative to.
function review_worker_path(model::ChatModel)
    proj = get(model.state.projects[], model.project_id, nothing)
    proj === nothing && return model.cwd
    return proj.worker_path
end

function review_worker_id(model::ChatModel)
    proj = get(model.state.projects[], model.project_id, nothing)
    return proj === nothing ? "" : proj.worker_id
end

"""
    folder_rel_to_project(folder, project) -> String

`folder`'s position under `project`, as a prefix to prepend to a path relative to
`folder` (so `""` when they are the same folder, `"dev/Foo/"` otherwise).

String surgery, not `relpath`: these are WORKER paths and the worker may run a
different OS, so the server's own separator has no business deciding what
"relative" means here. The picker only ever offers folders the scan found *under*
the project, so a prefix match is the whole of the question.

A folder that is NOT under the project (nothing in the UI produces one, but a
saved panel could outlive a project being moved) returns `""` — the paths then
stay relative to the reviewed folder, which is wrong-but-inert, rather than
carrying a `../..` prefix that `open_project_file!` would resolve into a
different tree.
"""
function folder_rel_to_project(folder::AbstractString, project::AbstractString)
    f = rstrip(normalize_worker_path(folder), '/')
    p = rstrip(normalize_worker_path(project), '/')
    (isempty(f) || isempty(p) || f == p) && return ""
    startswith(f, p * "/") || return ""
    return chopprefix(f, p * "/") * "/"
end

"""
    review_folder_label(folder, project) -> String

How a folder is named in the picker: its path under the project, or `"."` for the
project folder itself. Relative, because the absolute path is the same twelve
characters of prefix on every entry and the difference is the point.
"""
function review_folder_label(folder::AbstractString, project::AbstractString)
    rel = folder_rel_to_project(folder, project)
    return isempty(rel) ? "." : rstrip(rel, '/')
end

"""
    pick_review_folder(repos, project) -> String

Which folder the tab opens on, given what the scan found. `""` means "ask the
user" and the tab says so.

  * The project folder itself, when it is a checkout. This is the case the tab
    already handled and it must stay untouched.
  * The single checkout under it, when there is exactly one. Making someone pick
    from a list of one is a click that can only have one outcome.
  * The project folder when the scan found NOTHING under it. The scan only looks
    at or below the project, so an empty result does not mean "no repository" —
    it most often means the project sits INSIDE a bigger checkout, which is the
    monorepo case the tab handled long before it could pick at all: the worker
    resolves the enclosing repo and scopes the diff to this folder. And when
    there really is no repository anywhere, the worker says so in one clear
    sentence, which beats an empty state claiming there is nothing to review.

  * Otherwise nothing. With several checkouts under a folder that isn't one
    itself, there is no answer here that isn't a guess, and a guess costs more
    than the question: you get a real diff of the wrong repository, which reads
    exactly like a real diff of the right one.
"""
function pick_review_folder(repos::AbstractVector{<:AbstractString},
                            project::AbstractString)
    p = rstrip(normalize_worker_path(project), '/')
    for r in repos
        rstrip(normalize_worker_path(r), '/') == p && return String(project)
    end
    length(repos) == 1 && return String(first(repos))
    isempty(repos) && return String(project)
    return ""
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

"""
    project_path(git_path, strip, add) -> String

Turn a path as git printed it — relative to the REPOSITORY root — into one
relative to the PROJECT, which is the only frame the rest of the app speaks.

Two hops, because the reviewed folder and the project are no longer the same
thing once you can point the tab at a checkout inside the project:

  * `strip` removes the repository→folder part, giving a path relative to the
    REVIEWED FOLDER (this is what the diff was scoped to);
  * `add` prepends the project→folder part, giving a path relative to the
    PROJECT.

Both are empty in the common case (the project IS the reviewed folder and IS the
repository root), so this is the identity there.

It has to land on the project because that is where everything downstream is
standing: the agent's working directory is the project folder, and
`open_project_file!` resolves a relative path against it. A path relative to the
reviewed folder sent to either of those points at a file that isn't there.
"""
project_path(git_path::AbstractString, strip::AbstractString, add::AbstractString) =
    add * display_path(git_path, strip)

function review_file_section(f::DiffFile, prefix::AbstractString = "",
                             add::AbstractString = "")
    nlines = sum(h -> length(h.lines), f.hunks; init = 0)
    # What the row SHOWS is relative to the reviewed folder — the folder is named
    # in the header, so repeating it on every row is the noise the prefix
    # stripping exists to remove. What the row CARRIES is relative to the project,
    # because that is what the ⤢ handler and the agent are given.
    shown_path  = display_path(f.path, prefix)
    target_path = project_path(f.path, prefix, add)
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
                   title = "Open this file", dataOpen = target_path))
    body = if f.binary
        DOM.div("binary file — no textual diff"; class = "bt-rv-binary")
    elseif isempty(f.hunks)
        DOM.div("no textual changes"; class = "bt-rv-binary")
    else
        DOM.div((DOM.div(
                    DOM.div(h.header; class = "bt-rv-hunk-head"),
                    (review_line_row(target_path, l) for l in h.lines)...;
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
    # The state OUTLIVES this render — it is the project's, not the panel's, so a
    # reload re-renders the tab instead of resetting it. Everything below reads
    # and writes `st`; nothing here owns anything worth keeping.
    st = rp.st
    repo_txt   = Observable("")
    branch_txt = Observable("")
    stat_txt   = Observable("loading…")

    # The diff arrives ASYNCHRONOUSLY. `git_diff_on_worker` is a worker
    # round-trip that can take seconds on a big repo (and has a 60s timeout), so
    # computing it inside a `map` would park the session's task for that long —
    # freezing every other Observable in the tab. Instead the tab opens
    # immediately on a placeholder and swaps in the diff when it lands.
    # Two different waits, and saying which one you are in is the difference
    # between "it's working" and "it's stuck": with no folder decided yet the tab
    # is scanning the project for checkouts, not reading a diff of one.
    diff_dom = Observable{Any}(DOM.div(
        isempty(st.folder[]) ? "looking for git repositories in this project…" :
                               "reading the diff from the worker…";
        class = "bt-rv-empty"))

    build_diff() = begin
        base = st.base[]
        wid = review_worker_id(model)
        isempty(wid) && (safe_set!(stat_txt, "");
                         return DOM.div("This chat has no project on a worker to diff.";
                                        class = "bt-rv-empty"))
        # No folder decided yet, which `pick_review_folder` only leaves open for
        # ONE reason: the project isn't a checkout and holds SEVERAL, so any pick
        # would be a guess. Say how many, rather than showing git's "not a git
        # repository" about a folder that was never going to be one.
        #
        # An empty scan does NOT land here — that resolves to the project folder,
        # because the scan only looks at or below it and a project inside a bigger
        # checkout has nothing underneath. `n` is therefore always ≥ 2; it is
        # interpolated rather than hard-coded so a future rule change can't leave
        # a sentence here that quietly lies about the count.
        folder = st.folder[]
        if isempty(folder)
            safe_set!(stat_txt, "")
            n = length(st.repos[])
            return DOM.div(
                "This folder isn't a git repository, but it holds $(n) of them. " *
                "Pick one above to review it.";
                class = "bt-rv-empty")
        end
        res = try
            git_diff_on_worker(model.state, wid, folder; base = base)
        catch e
            @warn "review: git diff failed" project = model.project_id exception = e
            safe_set!(stat_txt, "")
            return DOM.div(
                DOM.div("Could not read the diff"; class = "bt-fv-error-title"),
                DOM.div(first(split(sprint(showerror, e), '\n')); class = "bt-fv-error-detail");
                class = "bt-tool-error bt-rv-error")
        end
        # Name what is actually on screen. The diff is scoped to the reviewed
        # folder, so showing a bare repo root next to it would claim more than the
        # tab is showing whenever that folder sits inside a bigger checkout.
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
        # …and gain the reviewed folder's own position under the project, so what
        # they CARRY stays in the project's frame even when what they SHOW is
        # relative to a checkout several levels down. Empty when the tab is
        # reviewing the project folder itself, which is the case that already
        # worked and must keep behaving identically.
        add = folder_rel_to_project(folder, review_worker_path(model))
        return DOM.div((review_file_section(f, prefix, add) for f in shown)...;
                       class = "bt-rv-files")
    end

    refresh_diff!() = Base.errormonitor(@async begin
        safe_set!(stat_txt, "reading…")
        # Swap the body to a loading state NOW. The worker round-trip behind
        # `build_diff` can take tens of seconds on a big repo; leaving the old
        # body up meanwhile reads as broken — with the folder picker freshly
        # set it still says "pick one above" while a diff is already loading.
        safe_set!(diff_dom, DOM.div("reading the diff from the worker…";
                                    class = "bt-rv-empty"))
        safe_set!(diff_dom, build_diff())
    end)

    # Find the checkouts under the project, so the picker has something to offer.
    #
    # Async and non-fatal, like the diff: the tab has to open now, and a scan that
    # is slow or a worker that is busy must not hold it there. A failed scan
    # leaves the picker with just the project folder, which is exactly what the
    # tab had before this existed — degraded, not broken.
    #
    # It runs BEFORE the first diff when the folder is still undecided, because
    # the scan is what decides it. When a folder was already passed in (a reopened
    # tab), the diff starts immediately and the scan only fills the picker.
    scan_repos!() = Base.errormonitor(@async begin
        wid = review_worker_id(model)
        isempty(wid) && return
        root = review_worker_path(model)
        found = try
            find_repos_on_worker(model.state, wid, root)
        catch e
            @warn "review: repository scan failed" project = model.project_id exception = e
            safe_set!(st.status, "could not scan for repositories")
            # Fall back to "the project folder is the only candidate". If it is a
            # checkout the tab works exactly as before; if it isn't, the empty
            # state says so instead of silently showing nothing.
            isempty(st.folder[]) && safe_set!(st.folder, String(root))
            return
        end
        safe_set!(st.repos, found.repos)
        # The worker decides its own budget and is the only one who knows whether
        # it ran out, so say THAT rather than quoting a number from this side that
        # a differently-versioned worker need not share.
        found.truncated && safe_set!(st.status,
            "scan hit its limit — some checkouts may be missing from the list")
        # Only DECIDE if nothing has been decided. A user who switched folders
        # while the scan was in flight owns the choice.
        isempty(st.folder[]) || return
        picked = pick_review_folder(found.repos, root)
        isempty(picked) || safe_set!(st.folder, picked)
        # `folder` staying "" is a real outcome (several checkouts, none of them
        # the project) — nudge the empty state to redraw now that it can say how
        # many there are.
        isempty(picked) && refresh_diff!()
    end)

    # ⟳ and a base change both mean "go ask again"; so does pointing the tab at a
    # different folder.
    on(session, st.reload) do _; refresh_diff!(); end
    on(session, st.base)   do _; refresh_diff!(); end
    on(session, st.folder) do _; refresh_diff!(); end
    scan_repos!()
    isempty(st.folder[]) || refresh_diff!()
    body = diff_dom

    # The folder picker. A `<select>` and not a browse tree: the answer is one of
    # a handful of known checkouts, and picking from a list is the whole
    # interaction. The project folder is always offered even when it isn't a
    # checkout — it is the default the tab used to hard-code, and a project that
    # gets `git init`-ed mid-session should not need a reopen to become reviewable.
    folder_select = map(session, st.repos, st.folder) do repos, folder
        root = review_worker_path(model)
        # Ordered shallowest-first (the scan is breadth-first) with the project
        # folder pinned to the top, and de-duplicated: the scan returns the
        # project itself when it is a checkout.
        opts = String[root]
        for r in repos
            rstrip(normalize_worker_path(r), '/') ==
                rstrip(normalize_worker_path(root), '/') || push!(opts, String(r))
        end
        nodes = Any[]
        # A placeholder only while nothing is chosen — an empty `<select>` value
        # otherwise reads as "no folder" and the first real option would be
        # selected on screen while `folder` says something else.
        isempty(folder) && push!(nodes,
            DOM.option("choose a folder…"; value = "", selected = true, disabled = true))
        for o in opts
            label = review_folder_label(o, root)
            push!(nodes, DOM.option(label; value = o, title = o,
                                    (o == folder ? (; selected = true) : (;))...))
        end
        # NO inline `onchange` here, and that is the whole point of this comment.
        #
        # This node is produced INSIDE a `map`, so it is rebuilt on every change of
        # `repos`/`folder` and re-serialised when the panel re-renders for a new
        # session. An Observable interpolated into a `js"…"` on such a node does
        # not survive that: after a page reload the handler runs against a `null`
        # (`Uncaught TypeError: Cannot read properties of null (reading 'notify')`)
        # and the picker is silently inert — every later pick does nothing, and ⟳
        # does not bring it back either.
        #
        # `base_input` gets away with an inline handler because it is built ONCE,
        # outside any `map`. This one goes through the delegated `change` listener
        # in the `onload` block instead, which is wired once with the observables
        # resolved once — the same reason the mode buttons and ⟳ are delegated.
        DOM.select(nodes...; class = "bt-rv-folder",
            title = "Which folder's repository to review. " *
                    "Found by scanning the project for checkouts.")
    end

    base_input = DOM.input(; type = "text", class = "bt-rv-base",
        placeholder = "vs HEAD", value = st.base,
        title = "Compare against a branch, tag or commit. Empty = the working tree vs HEAD.",
        onchange = js"event => $(st.base).notify(event.target.value.trim())")

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
    send_btn = map(session, st.comments) do cs
        n = length(cs)
        DOM.button(n == 0 ? "Send" : "Send $(n) comment$(n == 1 ? "" : "s")";
            class = "bt-btn bt-btn-sm bt-rv-send", type = "button",
            dataEmpty = n == 0 ? "1" : "0",
            title = "Deliver every collected comment to the agent as one instruction")
    end

    mode_hint = map(session, st.mode) do m
        (m == "ask" ? "Ask — your question goes to the chat immediately." :
                      "Feedback — comments collect here; Send delivers them as one instruction.") *
        "  ·  + comments on a line; shift-click a second + to cover a block."
    end

    header = DOM.div(
        DOM.span("⑂"; class = "bt-fv-icon"),
        path_span(repo_txt; class = "bt-file-editor-path bt-rv-repo"),
        # The badge carries its own padding and background, so an EMPTY one is
        # still a visible 15×3px stub — a stray dash next to the icon. Harmless
        # while it only flickered during a load; the "pick a folder" state holds
        # it indefinitely, so hide it when there is no branch to name. (The other
        # header spans collapse to 0×0 on their own; this one doesn't.)
        DOM.span(branch_txt; class = "bt-fv-badge",
                 style = map(b -> isempty(b) ? "display:none" : "", session, branch_txt)),
        DOM.span(stat_txt; class = "bt-rv-stat"),
        DOM.span(st.status; class = "bt-file-editor-status"),
        DOM.div(
            folder_select,
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
        DOM.div(map(review_pending_tray, session, st.comments); class = "bt-rv-tray-wrap"),
        DOM.div(body; class = "bt-rv-body");
        class = "bt-review", dataMode = st.mode[])

    # ── Julia-side handlers ─────────────────────────────────────────────────
    on(session, st.submit) do payload
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
        if st.mode[] == "ask"
            if !model.session_alive[]
                safe_set!(st.status, "no live session — start the chat first")
                return
            end
            try
                send_message!(model, UserMsg(review_ask_message(c, repo_txt[])))
                safe_set!(st.status, "asked in the chat")
            catch e
                @warn "review: ask failed" exception = (e, catch_backtrace())
                safe_set!(st.status, "could not ask: $(first(split(sprint(showerror, e), '\n')))")
            end
        else
            safe_set!(st.comments, push!(copy(st.comments[]), c))
            safe_set!(st.status, "")
        end
    end

    # Open a file from the diff, through the same guarded path everything else
    # uses — so a file that has been deleted in the working tree toasts instead
    # of opening an empty tab.
    on(session, st.open_path) do rel
        isempty(rel) && return
        pane = model.plotpane
        pane === nothing && (safe_set!(st.status, "no workspace to open into"); return)
        # `rel` is relative to the PROJECT — `project_path` puts it in that frame,
        # stripping the repository→folder part and prepending the project→folder
        # one — and `open_project_file!` resolves a relative path against the
        # project's worker path. So it goes straight through. It used to be joined
        # with the repo root instead, which broke the moment the header started
        # naming the scope: `<repo>/pkg` + `pkg/member.jl`.
        open_project_file!(pane, model.state, model.project_id, model.cwd, String(rel))
    end

    on(session, st.drop) do i
        cs = st.comments[]
        (1 <= i <= length(cs)) || return
        safe_set!(st.comments, deleteat!(copy(cs), i))
    end

    on(session, st.send) do _
        cs = st.comments[]
        isempty(cs) && (safe_set!(st.status, "no comments to send"); return)
        if !model.session_alive[]
            safe_set!(st.status, "no live session — start the chat first")
            return
        end
        try
            send_message!(model, UserMsg(review_feedback_message(cs, repo_txt[], st.base[])))
            # Clear only AFTER the send succeeded: a failure that also ate the
            # comments would lose a whole review pass.
            safe_set!(st.comments, ReviewComment[])
            safe_set!(st.status, "sent $(length(cs)) comment$(length(cs) == 1 ? "" : "s")")
        catch e
            @warn "review: send failed" exception = (e, catch_backtrace())
            safe_set!(st.status, "could not send: $(first(split(sprint(showerror, e), '\n')))")
        end
    end

    # ── browser side ────────────────────────────────────────────────────────
    # All of the interaction (open a box, type, submit, cancel) is local: the
    # server only hears about a finished comment. That keeps typing responsive
    # and means a flaky link can't eat half-written feedback.
    Bonito.onload(session, node, js"""(root) => {
        const submit = $(st.submit);
        const drop   = $(st.drop);
        const send   = $(st.send);
        const reload = $(st.reload);
        const openPath = $(st.open_path);
        const modeObs = $(st.mode);
        const folderObs = $(st.folder);
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
            // NB: js-strings keep backslashes verbatim (no Julia unescaping), so
            // this must be '\n' — '\\n' reaches the browser as a LITERAL
            // backslash-n and every snippet row would be glued together by
            // visible "\n"s in the message the agent receives.
            return out.join('\n');
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

        // The folder picker. Delegated, because the <select> is rebuilt by a
        // `map` and an observable interpolated onto it goes null across a
        // re-render — see the note where the element is built. `change` bubbles,
        // so one listener on the root covers every rebuild of the node.
        root.addEventListener('change', (e) => {
            const folder = e.target.closest('.bt-rv-folder');
            if (folder) folderObs.notify(folder.value);
        });

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
        panel isa ReviewPanel && safe_set!(panel.st.reload, panel.st.reload[] + 1)
        return nothing
    end
    # A FRESH panel around the project's EXISTING state — which is the whole
    # point. This is the path a reload takes (the workspace is rebuilt, so no
    # panel is found), and it now re-renders the folder, the base, the mode and
    # the pending comments instead of starting over.
    BonitoWidgets.add_panel!(ws, BonitoWidgets.Panel(id, ReviewPanel(model; base);
        label = "Changes", closable = true))
    return nothing
end
