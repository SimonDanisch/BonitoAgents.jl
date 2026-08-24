# Which folder the review tab diffs, and what frame the paths it hands out are in.
#
# A project folder is routinely NOT a checkout — it's a workspace holding one per
# dependency being developed (`dev/Bonito`, `dev/Makie`, …). The tab used to ask
# git about the project folder and nothing else, so that layout got
# "not a git repository" and had no way to say which repository it meant.
#
# The part worth pinning is the PATH FRAME. Three frames meet in this tab:
#
#   * git prints paths relative to the REPOSITORY root,
#   * the rows show them relative to the REVIEWED FOLDER (the header names it, so
#     repeating it on every row is noise),
#   * everything downstream — the agent's working directory, `open_project_file!`
#     — is relative to the PROJECT.
#
# They coincided while the reviewed folder WAS the project, which is why one
# string used to do all three jobs. It can't any more, and a path in the wrong
# frame is not a cosmetic slip: it opens a different file, or tells the agent to
# edit one that isn't there.
@testitem "unit:review_folder" tags = [:unit] begin
    using Test
    import BonitoAgents
    const BT = BonitoAgents

    PROJ = "/home/sd/work"

    @testset "folder_rel_to_project" begin
        R = BT.folder_rel_to_project
        # The project itself: no prefix, so every path stays exactly as it was
        # before this existed.
        @test R(PROJ, PROJ)        == ""
        @test R(PROJ * "/", PROJ)  == ""
        @test R(PROJ, PROJ * "/")  == ""

        @test R("$PROJ/dev/Bonito", PROJ)     == "dev/Bonito/"
        @test R("$PROJ/dev/Bonito/", PROJ)    == "dev/Bonito/"
        @test R("$PROJ/pkg", PROJ)            == "pkg/"

        # Worker paths, so the WORKER's separator decides. A server-side
        # `relpath` would answer with backslashes here on a Windows server and
        # with nonsense on a Linux one.
        @test R("C:\\work\\dev\\Bonito", "C:\\work") == "dev/Bonito/"
        @test R("C:/work/dev/Bonito", "C:\\work")    == "dev/Bonito/"

        # A folder that is NOT under the project can't be expressed relative to
        # it. "" leaves the paths in the reviewed folder's frame — inert — rather
        # than a `../..` prefix that would resolve into a different tree.
        @test R("/elsewhere/repo", PROJ) == ""
        @test R("/home/sd", PROJ)        == ""   # an ANCESTOR is not "under"
        # A sibling that merely shares a prefix STRING is not under it either.
        @test R("/home/sd/workshop", PROJ) == ""

        @test R("", PROJ) == ""
        @test R(PROJ, "") == ""
    end

    @testset "project_path — the two hops" begin
        P = BT.project_path
        # ── The case that already worked: project == reviewed folder == repo root.
        # Both prefixes empty, so this is the identity. If this ever changes,
        # every existing review breaks.
        @test P("src/a.jl", "", "") == "src/a.jl"

        # ── Project inside a bigger checkout (the tab reviews the project; git
        # answers from the repo root above it). Strip only.
        @test P("pkg/src/a.jl", "pkg/", "") == "src/a.jl"

        # ── A checkout INSIDE the project (this feature). git answers from that
        # checkout's own root, so nothing to strip — but the result has to come
        # back up to the project. Add only.
        @test P("src/a.jl", "", "dev/Bonito/") == "dev/Bonito/src/a.jl"

        # ── Both at once: a sub-folder of a checkout inside the project.
        @test P("pkg/src/a.jl", "pkg/", "dev/Bonito/") == "dev/Bonito/src/a.jl"

        # Non-ASCII folder names. `display_path` uses `chopprefix` and not an
        # index slice for exactly this: `length` counts CHARACTERS while string
        # indices are BYTES, and slicing at `length(prefix)` turned `bücher/a.jl`
        # into `/a.jl` — a broken link, not a cosmetic slip.
        @test P("bücher/a.jl", "bücher/", "dev/Bücher/") == "dev/Bücher/a.jl"
        @test P("a.jl", "", "π/") == "π/a.jl"
    end

    @testset "review_folder_label" begin
        L = BT.review_folder_label
        # The project is "." — it has no path under itself, and an empty label
        # would render as a blank row you can't tell from a separator.
        @test L(PROJ, PROJ) == "."
        @test L("$PROJ/dev/Bonito", PROJ) == "dev/Bonito"
        @test L("$PROJ/dev/Bonito/", PROJ) == "dev/Bonito"
        # Relative, because the absolute path is the same prefix on every entry
        # and the difference is the whole point of the list.
        @test !occursin(PROJ, L("$PROJ/dev/Bonito", PROJ))
        # Un-expressible ones fall back to "." rather than to an empty label.
        @test L("/elsewhere/repo", PROJ) == "."
    end

    @testset "pick_review_folder" begin
        K = BT.pick_review_folder
        # The project IS a checkout ⇒ it, exactly as the tab behaved before.
        # (The scan stops at a hit, so this is the whole list in that case.)
        @test K([PROJ], PROJ) == PROJ
        @test K([PROJ * "/"], PROJ) == PROJ

        # Exactly one below it ⇒ that one. A list of one is a click that can only
        # have one outcome.
        @test K(["$PROJ/dev/Bonito"], PROJ) == "$PROJ/dev/Bonito"

        # Several, none of them the project ⇒ ASK. Any pick here is a guess, and
        # a guess yields a real diff of the wrong repository — which reads exactly
        # like a real diff of the right one.
        @test K(["$PROJ/dev/Bonito", "$PROJ/dev/Makie"], PROJ) == ""

        # Nothing found ⇒ nothing to open on; the empty state says so.
        @test K(String[], PROJ) == ""

        # The project wins even when the scan also returned others — a checkout
        # nested inside a checkout must not displace the one asked about.
        @test K([PROJ, "$PROJ/vendor/dep"], PROJ) == PROJ
    end
end
