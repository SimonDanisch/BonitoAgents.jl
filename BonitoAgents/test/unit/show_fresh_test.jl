@testitem "unit:show_fresh" tags = [:unit] begin

# "bt_show and friends show old files when they have the same path" (#34).
#
# The server keeps a MIRROR of every worker file it has been asked to display.
# Paths get reused constantly — a re-rendered plot, a re-recorded video, an
# edited source file all keep their name — so "we already have a file at this
# destination" is not a cache hit, and treating it as one is how the chat ends up
# showing yesterday's plot with today's caption.
#
# The fix is a freshness key: the worker's `(size, mtime)` at the moment a
# transfer landed. Only a stamp that still matches skips the re-fetch. These
# tests run against a REAL worker over the real transfer path, because the whole
# bug lived in the interaction between the two sides.

using Test
import BonitoAgents
const BT = BonitoAgents

@testset "mirror freshness against a live worker" begin
    h = BT.dev_server(; port = 0)
    try
        registered = false
        for _ in 1:60
            isempty(h.state.workers[]) || (registered = true; break)
            sleep(0.5)
        end
        @test registered
        st = h.state
        wid = first(keys(st.workers[]))

        # A project whose worker tree and server mirror are DIFFERENT directories,
        # so every read has to go through a real worker transfer (the shared-FS
        # short-circuit would hide the bug entirely).
        worker_dir = mktempdir()
        server_dir = mktempdir()
        pid = "fresh-test"
        st.projects[][pid] = BT.ProjectInfo(pid, "Fresh", wid, server_dir, worker_dir,
                                            BT.now(BT.UTC))
        probe = joinpath(worker_dir, "plot.png")
        show_tool = BT.ShowTool(st, pid, server_dir, "plot.png")
        mirror = BT.show_server_path(show_tool)
        @test mirror == joinpath(server_dir, "plot.png")

        @testset "first read fetches" begin
            write(probe, "VERSION-ONE")
            @test BT.fetch_show_file(show_tool) == mirror
            @test read(mirror, String) == "VERSION-ONE"
        end

        @testset "an unchanged file is NOT re-fetched" begin
            # The stamp matches, so the mirror is served as-is. Proven by writing
            # to the MIRROR behind the fetcher's back: a re-fetch would overwrite
            # this, a cache hit keeps it.
            write(mirror, "SERVED-FROM-CACHE")
            @test BT.fetch_show_file(show_tool) == mirror
            @test read(mirror, String) == "SERVED-FROM-CACHE"
            write(mirror, "VERSION-ONE")   # put it back
        end

        @testset "the same path with NEW content re-fetches" begin
            sleep(0.02)
            write(probe, "VERSION-TWO")
            @test BT.fetch_show_file(show_tool) == mirror
            @test read(mirror, String) == "VERSION-TWO"
        end

        @testset "a same-SIZE rewrite re-fetches too" begin
            # The case a size-only check misses, and the common one: an image
            # re-rendered at the same dimensions, a file edited in place.
            sleep(0.02)
            write(probe, "VERSION-TRE")     # same length as VERSION-TWO
            @test filesize(probe) == 11
            @test BT.fetch_show_file(show_tool) == mirror
            @test read(mirror, String) == "VERSION-TRE"
        end

        @testset "a deleted-then-recreated file is picked up" begin
            sleep(0.02)
            rm(probe)
            write(probe, "VERSION-FOUR")
            @test read(BT.fetch_show_file(show_tool), String) == "VERSION-FOUR"
        end

        @testset "with no worker, a stale mirror beats an error" begin
            # Offline (or an unknown project): showing the last known version is
            # the right call — but only because there is no way to get a fresher
            # one, never as a shortcut.
            orphan = BT.ShowTool(st, "no-such-project", server_dir, "plot.png")
            @test BT.fetch_show_file(orphan) == mirror
            @test read(mirror, String) == "VERSION-FOUR"
            # …and a file we have never had, with no worker, is an error rather
            # than a silent blank.
            @test_throws Exception BT.fetch_show_file(
                BT.ShowTool(st, "no-such-project", server_dir, "never-seen.png"))
        end

        @testset "the stamp table is keyed per destination" begin
            write(joinpath(worker_dir, "other.png"), "OTHER-ONE")
            other = BT.ShowTool(st, pid, server_dir, "other.png")
            @test read(BT.fetch_show_file(other), String) == "OTHER-ONE"
            # Two entries, one per mirrored file — and updating one must not
            # invalidate the other.
            @test length(st.show_mirror_stamps) >= 2
            write(mirror, "STILL-CACHED")
            @test read(BT.fetch_show_file(show_tool), String) == "STILL-CACHED"
        end

        @testset "stat_worker_path carries the mtime the stamp needs" begin
            info = BT.stat_worker_path(st, wid, probe)
            @test info.isfile && info.size > 0 && info.mtime > 0
        end
    finally
        close(h)
    end
end

end
