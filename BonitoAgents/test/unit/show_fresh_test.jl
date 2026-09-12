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
using HTTP
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

        @testset "disk URLs outlive displays and serve fresh byte ranges" begin
            # There is no eval bridge in this rig. These requests go through the
            # real worker connection, with different server/worker directories.
            payload = repeat(UInt8[0, 1, 2, 3, 255], 120_000)
            special = joinpath(worker_dir, "a #? ü.png")
            write(special, payload)
            url = BT.worker_file_url(st, wid, special)
            base = "http://127.0.0.1:$(st.srv.port)"
            getfile(headers = Pair{String,String}[]) = HTTP.get(base * url, headers; status_exception=false)
            @test getfile().body == payload  # crosses several control frames
            r = getfile(["Range" => "bytes=262140-262160"])
            @test r.status == 206
            @test r.body == payload[262141:262161]
            @test HTTP.header(r, "Content-Range") == "bytes 262140-262160/600000"
            @test HTTP.header(r, "Cache-Control") == "no-cache"
            @test getfile(["Range" => "bytes=-5"]).body == payload[end-4:end]
            @test getfile(["Range" => "bytes=599995-"]).body == payload[end-4:end]
            @test getfile(["Range" => "bytes=600000-"]).status == 416

            # Older workers use the established transfer protocol. Seeking
            # should reuse that mirror; rewriting the source must replace it.
            copy_request = HTTP.Request("GET", url, ["Range" => "bytes=0-4"])
            copy_response() = BT.worker_file_copy_response(st, copy_request, wid, special,
                                                           BT.stat_worker_path(st, wid, special))
            @test copy_response().body == payload[1:5]
            key = BT.worker_file_token(st, wid, special)
            cached = joinpath(st.state_dir, "worker-files", key, basename(special))
            write(cached, "CACHE")
            @test String(copy_response().body) == "CACHE"
            write(special, "REGENERATED")
            @test String(copy_response().body) == "REGEN"

            # The same URL still works with no chat record, and changing bytes
            # under the same path cannot leave a cached proxy asset behind.
            saved = pop!(st.projects[], pid)
            try
                write(special, "new bytes")
                @test String(getfile().body) == "new bytes"
                restored = BT.ServerState(state_dir=mktempdir(), working_dir=mktempdir(),
                                          worker_secret=st.worker_secret)
                @test BT.worker_file_url(restored, wid, special) == url
            finally
                st.projects[][pid] = saved
            end
            @test HTTP.get(base * url * "x"; status_exception=false).status == 403
            other = replace(url, "path=" => "path=x")
            @test HTTP.get(base * other; status_exception=false).status == 403
            rm(special)
            @test getfile().status == 404
        end
    finally
        close(h)
    end
end

end
