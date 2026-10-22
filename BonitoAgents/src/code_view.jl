# ── Static code views ────────────────────────────────────────────────────────
# Read-only code in the transcript (eval code, edit diffs, file reads, shell
# output) is plain DOM: one row per line, built in the browser from the text
# (`mountCode`, bonitoagents.js) and highlighted there with Monaco's tokenizer
# (`colorize`) once it comes near the screen. No editor instance: a Monaco
# editor per card cost a font measurement, forced layouts on every render,
# composited layers and a diff worker, and the transcript built each one anew
# whenever its card scrolled back in (30 per scroll through 30 edits, ~70% of
# the main thread, profiled 2026-10-20). Native scrolling, selection, copy and
# the browser's find work on it as on any text.

"""
    CodeView(text; language = "", path = "")

Read-only code, highlighted as `language` (a Monaco language id), or as the
language Monaco registers for `path` when `language` is empty.
"""
struct CodeView
    text::String
    language::String
    path::String
end
CodeView(text::AbstractString; language::AbstractString = "", path::AbstractString = "") =
    CodeView(String(text), String(language), String(path))

"""
    DiffView(old, new; language = "", path = "")

The line diff of `old` and `new`, inline: removed and added lines with both
line numbers, changed characters marked. Highlighted like [`CodeView`](@ref).
"""
struct DiffView
    old::String
    new::String
    language::String
    path::String
    ops::String             # the line diff, `diff_ops(old, new)`
end
DiffView(old::AbstractString, new::AbstractString; language::AbstractString = "",
         path::AbstractString = "") =
    DiffView(String(old), String(new), String(language), String(path), diff_ops(old, new))
DiffView(d::DiffContent) = DiffView(something(d.old_text, ""), d.new_text; path = d.path)

# Lines as the browser splits them (`codeLines` in bonitoagents.js), which
# `diff_ops` counts in: a trailing newline leaves an empty last line, an empty
# text has none (a new file is all additions).
code_lines(text::AbstractString) = isempty(text) ? SubString{String}[] : split(text, '\n')

"""
    diff_ops(old, new) -> String

The line diff of two texts as runs of kept (`=`), removed (`-`) and added (`+`)
lines, e.g. `"=3 -2 +4 =10"`: the shortest edit script (Myers 1986), each change
written as its removals, then its additions. Past `max_d` differences the
changed middle is written as all removed, then all added.
"""
diff_ops(old::AbstractString, new::AbstractString; max_d::Int = 500) =
    join(("$(k)$(n)" for (k, n) in line_diff(code_lines(old), code_lines(new); max_d)), ' ')

function line_diff(a::AbstractVector, b::AbstractVector; max_d::Int = 500)
    n, m = length(a), length(b)
    p = 0
    while p < min(n, m) && a[p + 1] == b[p + 1]
        p += 1
    end
    s = 0
    while s < min(n, m) - p && a[n - s] == b[m - s]
        s += 1
    end
    steps = Char[]
    append!(steps, fill('=', p))
    append!(steps, middle_steps(view(a, (p + 1):(n - s)), view(b, (p + 1):(m - s)), max_d))
    append!(steps, fill('=', s))
    return runs(steps)
end

# One step per line of the edit script for two sequences with nothing in
# common at either end: `=` keeps a line, `-` removes one of `a`, `+` adds one
# of `b`. Myers' greedy forward search; the walk back needs the frontier each
# round started from, of which round `d` can only read diagonals -(d+1):(d+1).
function middle_steps(a::AbstractVector, b::AbstractVector, max_d::Int)
    n, m = length(a), length(b)
    n == 0 && return fill('+', m)
    m == 0 && return fill('-', n)
    limit = min(n + m, max_d)
    offset = limit + 2
    v = zeros(Int, 2 * limit + 3)            # only diagonals within the search budget
    trace = Vector{Vector{Int}}()            # trace[d + 1][k + d + 2]: v as round d began
    for d in 0:limit
        push!(trace, v[(offset - d - 1):(offset + d + 1)])
        for k in (-d):2:d
            x = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) ?
                v[k + 1 + offset] : v[k - 1 + offset] + 1
            y = x - k
            while x < n && y < m && a[x + 1] == b[y + 1]
                x += 1; y += 1
            end
            v[k + offset] = x
            x >= n && y >= m && return backtrack(trace, n, m)
        end
    end
    return vcat(fill('-', n), fill('+', m))
end

function backtrack(trace::Vector{Vector{Int}}, n::Int, m::Int)
    steps = Char[]
    x, y = n, m
    for d in (length(trace) - 1):-1:1
        v = trace[d + 1]
        at(k) = v[k + d + 2]
        k = x - y
        down = k == -d || (k != d && at(k - 1) < at(k + 1))
        pk = down ? k + 1 : k - 1
        px = at(pk)
        py = px - pk
        while x > (down ? px : px + 1) && y > (down ? py + 1 : py)
            push!(steps, '='); x -= 1; y -= 1
        end
        push!(steps, down ? '+' : '-')
        x, y = px, py
    end
    while x > 0 && y > 0
        push!(steps, '='); x -= 1; y -= 1
    end
    return reverse!(steps)
end

# Steps as runs, the removals of each change ahead of its additions.
function runs(steps::Vector{Char})
    out = Tuple{Char,Int}[]
    i = 1
    while i <= length(steps)
        if steps[i] == '='
            j = i
            while j <= length(steps) && steps[j] == '='
                j += 1
            end
            push!(out, ('=', j - i))
        else
            j = i
            while j <= length(steps) && steps[j] != '='
                j += 1
            end
            removed = count(==('-'), view(steps, i:(j - 1)))
            added = (j - i) - removed
            removed > 0 && push!(out, ('-', removed))
            added > 0 && push!(out, ('+', added))
        end
        i = j
    end
    return out
end

"How many lines `ops` (from [`diff_ops`](@ref)) removes and adds."
diff_counts(v::DiffView) = diff_counts(v.ops)
function diff_counts(ops::AbstractString)
    removed = added = 0
    for op in split(ops)
        n = parse(Int, op[2:end])
        op[1] == '-' && (removed += n)
        op[1] == '+' && (added += n)
    end
    return removed, added
end

function Bonito.jsrender(session::Session, v::CodeView)
    # Source payload, consumed by mountCode, never a second visible code view.
    # Otherwise Chrome lays out every source line before the module arrives.
    src = DOM.pre(v.text; class = "bt-code-src", hidden = true)
    return Bonito.jsrender(session, DOM.div(src, mount_code_js(src, v);
        class = "bt-code", dataLang = v.language, dataPath = v.path))
end

function Bonito.jsrender(session::Session, v::DiffView)
    old = DOM.pre(v.old; class = "bt-code-src", hidden = true)
    new = DOM.pre(v.new; class = "bt-code-src", hidden = true)
    return Bonito.jsrender(session, DOM.div(old, new, mount_code_js(old, v);
        class = "bt-code bt-code-diff", dataLang = v.language, dataPath = v.path,
        dataOps = v.ops))
end

# Runs right after its surrounding DOM is parsed (inline JSCode child).
function mount_code_js(src, v::Union{CodeView,DiffView})
    # Plain shell/text output needs no tokenizer download or initialization.
    plain = v.language == "plaintext" || (isempty(v.language) && isempty(v.path))
    highlighter = plain ? nothing : BonitoBook.CodeTokenizer
    return js"""$(ChatLib).then(lib => lib.mountCode($(src).parentElement, $(highlighter)))"""
end
