@testitem "unit:review" tags = [:unit] begin

# The change-review tab's two headless halves:
#
#   • `parse_unified_diff` — turns `git diff` output into per-file hunks with
#     BOTH sides' line numbers. The line numbers are the load-bearing part: a
#     comment anchors to one, so an off-by-one sends the agent to the wrong line.
#   • the message composers — what the agent actually receives for an Ask and
#     for a batched Feedback send.
#
# Also covers the worker side's untracked-file synthesis, since "the agent
# created three files and the review showed none of them" is the failure mode
# that makes a review tab useless.

using Test
using BonitoAgents
using BonitoWorker
const BT = BonitoAgents

@testset "parse_unified_diff" begin
    patch = """
    diff --git a/src/foo.jl b/src/foo.jl
    index 1111111..2222222 100644
    --- a/src/foo.jl
    +++ b/src/foo.jl
    @@ -10,4 +10,5 @@ function foo()
     ctx1
    -old line
    +new line
    +extra line
     ctx2
    """
    files = BT.parse_unified_diff(patch)
    @test length(files) == 1
    f = files[1]
    @test f.path == "src/foo.jl"
    @test f.status === :modified
    @test !f.binary
    @test (f.additions, f.deletions) == (2, 1)
    @test length(f.hunks) == 1

    kinds = [l.kind for l in f.hunks[1].lines]
    @test kinds == [:context, :del, :add, :add, :context]
    # Both sides advance independently — this is what a comment anchors to.
    nums = [(l.old_no, l.new_no) for l in f.hunks[1].lines]
    @test nums == [(10, 10), (11, 0), (0, 11), (0, 12), (12, 13)]
    # The +/-/space marker is stripped; the code itself is verbatim.
    @test [l.text for l in f.hunks[1].lines] ==
          ["ctx1", "old line", "new line", "extra line", "ctx2"]
end

@testset "file statuses" begin
    patch = """
    diff --git a/added.txt b/added.txt
    new file mode 100644
    --- /dev/null
    +++ b/added.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    diff --git a/gone.jl b/gone.jl
    deleted file mode 100644
    --- a/gone.jl
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -a
    -b
    diff --git a/old.jl b/new.jl
    similarity index 95%
    rename from old.jl
    rename to new.jl
    diff --git a/img.png b/img.png
    index 3333333..4444444 100644
    Binary files a/img.png and b/img.png differ
    """
    files = BT.parse_unified_diff(patch)
    @test [f.path for f in files] == ["added.txt", "gone.jl", "new.jl", "img.png"]
    @test [f.status for f in files] == [:added, :deleted, :renamed, :modified]
    @test files[3].old_path == "old.jl"
    @test files[4].binary
    @test isempty(files[4].hunks)
    # An added file's lines all belong to the NEW side, starting at 1.
    @test [(l.old_no, l.new_no) for l in files[1].hunks[1].lines] == [(0, 1), (0, 2)]
    # A deleted file's, to the old side.
    @test [(l.old_no, l.new_no) for l in files[2].hunks[1].lines] == [(1, 0), (2, 0)]
end

@testset "awkward paths and headers" begin
    # Paths with spaces: `diff --git a/x y b/x y` can't be split on whitespace,
    # which is exactly the case people hit and no one tests.
    files = BT.parse_unified_diff("""
    diff --git a/my notes.md b/my notes.md
    --- a/my notes.md
    +++ b/my notes.md
    @@ -1 +1 @@
    -a
    +b
    """)
    @test length(files) == 1 && files[1].path == "my notes.md"
    @test (files[1].additions, files[1].deletions) == (1, 1)

    # The `diff --git` line is the ONLY source of the path when a section has no
    # `---`/`+++` pair — a binary file is exactly that. So a spaced path has to
    # come out of that line correctly on its own, with nothing downstream to
    # correct it. (This is what a last-space split gets wrong, silently.)
    bin = BT.parse_unified_diff("""
    diff --git a/my images/logo one.png b/my images/logo one.png
    index 1111111..2222222 100644
    Binary files a/my images/logo one.png and b/my images/logo one.png differ
    """)
    @test length(bin) == 1
    @test bin[1].path == "my images/logo one.png"
    @test bin[1].binary

    # Directly, including the shapes that make naive splitting wrong: a path
    # containing the separator itself, non-ASCII names (byte vs char indexing),
    # and a rename, whose halves legitimately differ.
    pdg = BT.parse_diff_git_line
    @test pdg("a/x b/x") == ("x", "x")
    @test pdg("a/my notes.md b/my notes.md") == ("my notes.md", "my notes.md")
    @test pdg("a/a b/b b/a b/b") == ("a b/b", "a b/b")
    @test pdg("a/naïve/файл.md b/naïve/файл.md") == ("naïve/файл.md", "naïve/файл.md")
    @test pdg("a/old.jl b/new.jl") == ("old.jl", "new.jl")

    # A `--- path\ttimestamp` header (classic unified diff): the tab and
    # everything after it is metadata, not part of the name.
    files2 = BT.parse_unified_diff("""
    diff --git a/t.txt b/t.txt
    --- a/t.txt\t2026-01-01 00:00:00
    +++ b/t.txt\t2026-01-02 00:00:00
    @@ -1 +1 @@
    -x
    +y
    """)
    @test files2[1].path == "t.txt"

    # Single-line hunk ranges omit the count (`@@ -1 +1 @@`) — handled above —
    # and a `\\ No newline` marker is metadata, not a code line.
    files3 = BT.parse_unified_diff("""
    diff --git a/n.txt b/n.txt
    --- a/n.txt
    +++ b/n.txt
    @@ -1 +1 @@
    -x
    \\ No newline at end of file
    +y
    """)
    lines = files3[1].hunks[1].lines
    @test [l.kind for l in lines] == [:del, :note, :add]
    # The note must not consume a line number on either side.
    @test lines[3].new_no == 1

    # Junk in, no crash out: a preamble before the first `diff --git` is skipped.
    @test isempty(BT.parse_unified_diff("some junk\nnot a diff at all\n"))
    @test isempty(BT.parse_unified_diff(""))
end

@testset "message composition" begin
    c1 = BT.ReviewComment("src/a.jl", 42, "new", "  41  ctx\n> 42 +y = x + 1\n", "use muladd")
    c2 = BT.ReviewComment("src/b.jl", 7, "new", ">  7 +open(f)\n", "this leaks the handle")

    # A comment can cover a BLOCK; the location it reports has to say so, or the
    # agent goes and edits one line of a region you asked it to rework.
    block = BT.ReviewComment("src/c.jl", 10, 13, "new", "> 10 + a\n> 13 + b\n", "extract this")
    @test BT.comment_location(c1) == "src/a.jl:42"
    @test BT.comment_location(block) == "src/c.jl:10-13"
    @test occursin("`src/c.jl:10-13`", BT.review_ask_message(block, ""))
    @test occursin("## 1. `src/c.jl:10-13`", BT.review_feedback_message([block], "", ""))
    # The 5-arg form is the single-line case — same line at both ends.
    @test BT.ReviewComment("f", 3, "new", "", "x").end_line == 3

    ask = BT.review_ask_message(c1, "/repo")
    @test occursin("`src/a.jl:42`", ask)
    @test occursin("/repo", ask)
    @test occursin("y = x + 1", ask)     # the code the user was looking at
    @test occursin("use muladd", ask)

    batch = BT.review_feedback_message([c1, c2], "/repo", "main")
    @test occursin("2 comments", batch)
    @test occursin("diff vs `main`", batch)
    # Numbered, so a multi-comment review gets worked through rather than
    # half-addressed.
    @test occursin("## 1. `src/a.jl:42`", batch)
    @test occursin("## 2. `src/b.jl:7`", batch)
    @test occursin("use muladd", batch)
    @test occursin("this leaks the handle", batch)
    # It has to say "don't do anything else" — otherwise a review of three
    # comments comes back as a refactor.
    @test occursin("don't refactor", batch)

    # Singular reads as singular.
    @test occursin("1 comment on", BT.review_feedback_message([c1], "", ""))

    # Reviewing this repo means reviewing its markdown, and a snippet lifted from
    # a `.md` diff carries its own ``` — inside a 3-backtick fence that closes
    # the block early and dumps the rest of the comment out as prose. The fence
    # has to be longer than anything in the snippet.
    @test BT.fence_for("plain code") == "```"
    @test BT.fence_for("a ``` b") == "````"
    @test BT.fence_for("````\nnested\n````") == "`````"
    md = BT.ReviewComment("README.md", 5, 7, "new", "```julia\nf(x) = x\n```\n", "explain this")
    m = BT.review_ask_message(md, "")
    fence = "````"
    @test occursin(fence * "\n```julia", m)          # opened with a LONGER fence
    @test endswith(strip(m), "explain this")         # the comment survived intact
    # The inner fence never terminates the block: the only 4-backtick runs are
    # ours, and there are exactly two of them.
    @test length(collect(eachmatch(Regex("(?<!`)" * fence * "(?!`)"), m))) == 2

    # A snippet with no trailing newline must not glue the closing fence onto the
    # last line of code.
    nonl = BT.ReviewComment("a.jl", 1, 1, "new", "x = 1", "why?")
    @test occursin("x = 1\n```", BT.review_ask_message(nonl, ""))

    # A comment on a DELETED line carries its OLD number. Handing the agent a
    # bare `a.jl:42` would send it to read whatever occupies line 42 now, which
    # is unrelated code — so the side has to be stated.
    del = BT.ReviewComment("a.jl", 42, 42, "old", "old_call()\n", "why was this dropped?")
    ask_del = BT.review_ask_message(del, "")
    @test occursin("REMOVED", ask_del)
    @test occursin("before the change", ask_del)
    @test occursin("`a.jl:42`", ask_del)                 # still the clickable form
    @test occursin("REMOVED", BT.review_feedback_message([del], "", ""))
    # New-side comments — the overwhelming majority — stay clean.
    @test !occursin("REMOVED", BT.review_ask_message(c1, ""))
    @test !occursin("REMOVED", BT.review_feedback_message([c1, c2], "", ""))
end

# The worker half: an untracked file has no git diff at all, so we synthesize
# one. Without this, everything the agent CREATED is invisible in the review.
@testset "untracked file patches (worker side)" begin
    dir = mktempdir()
    write(joinpath(dir, "fresh.txt"), "one\ntwo\n")
    patch = BonitoWorker.untracked_patch(dir, "fresh.txt")
    @test occursin("diff --git a/fresh.txt b/fresh.txt", patch)
    @test occursin("new file mode", patch)
    @test occursin("@@ -0,0 +1,2 @@", patch)

    # And it round-trips through the server's parser as a normal addition.
    f = only(BT.parse_unified_diff(patch))
    @test f.path == "fresh.txt" && f.status === :added
    @test (f.additions, f.deletions) == (2, 0)
    @test [l.text for l in f.hunks[1].lines] == ["one", "two"]

    # No trailing newline ⇒ the marker git itself would emit.
    write(joinpath(dir, "nonl.txt"), "only")
    @test occursin("No newline at end of file", BonitoWorker.untracked_patch(dir, "nonl.txt"))

    # A binary file reports as binary rather than dumping bytes into the DOM.
    write(joinpath(dir, "blob.bin"), UInt8[0x00, 0x01, 0x02])
    bp = BonitoWorker.untracked_patch(dir, "blob.bin")
    @test occursin("Binary files", bp)
    @test BT.parse_unified_diff(bp)[1].binary

    # Oversized files are reported, not inlined.
    write(joinpath(dir, "big.txt"), repeat("x\n", 400_000))
    @test occursin("Binary files", BonitoWorker.untracked_patch(dir, "big.txt"))

    @test BonitoWorker.untracked_patch(dir, "missing.txt") == ""
end

@testset "git_diff_response against a real repo" begin
    dir = mktempdir()
    run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.email t@t`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.name t`; stdout = devnull, stderr = devnull))

    # A repo with NO commits yet: `git diff HEAD` fails there, so the worker
    # falls back to the empty tree instead of reporting an error.
    write(joinpath(dir, "a.txt"), "one\n")
    r0 = BonitoWorker.git_diff_response("r0", dir, "")
    @test !haskey(r0, "error")
    @test occursin("a.txt", r0["patch"])          # picked up as untracked

    run(pipeline(`git -C $dir add -A`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir commit -qm first`; stdout = devnull, stderr = devnull))

    # Committed and unchanged ⇒ an empty patch, not an error.
    r1 = BonitoWorker.git_diff_response("r1", dir, "")
    @test !haskey(r1, "error")
    @test isempty(BT.parse_unified_diff(r1["patch"]))
    @test !isempty(r1["head"])

    # Now the two things a review has to catch: an edit and a NEW file.
    write(joinpath(dir, "a.txt"), "one\ntwo\n")
    write(joinpath(dir, "b.txt"), "brand new\n")
    r2 = BonitoWorker.git_diff_response("r2", dir, "")
    files = BT.parse_unified_diff(r2["patch"])
    byname = Dict(f.path => f for f in files)
    @test haskey(byname, "a.txt") && byname["a.txt"].status === :modified
    @test haskey(byname, "b.txt") && byname["b.txt"].status === :added

    # Errors come back as an `error` field, never as a thrown exception that
    # would leave the server's RPC waiting forever.
    @test haskey(BonitoWorker.git_diff_response("r3", mktempdir(), ""), "error")
    @test haskey(BonitoWorker.git_diff_response("r4", dir, "no-such-ref"), "error")
    @test haskey(BonitoWorker.git_diff_response("r5", "", ""), "error")
end

end
