# Server-level regression for "download a worker file to the client".
#
# The file tree's ⤓ button navigates to `/download/<pid>?path=<worker-abs-path>`,
# which `download_response` serves by reading the file from the worker and
# streaming it back as an attachment. This drives the route over HTTP (no
# browser): a real worker file is streamed, the Content-Disposition names it, a
# big one starts arriving at once (and so does a video's range from
# /worker-file), and the path-traversal / bad-input guards reject everything
# outside the project tree. (The dev_server worker is local, so a path we write
# here is readable by the worker — same machine.)

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
const BA = TestKit.BT

poll_until(cond; timeout = 30.0, interval = 0.25) = begin
    t0 = time()
    while time() - t0 < timeout
        cond() && return true
        sleep(interval)
    end
    false
end

function run_suite(server)
    state = server.h.state
    @test poll_until(() -> !isempty(state.workers[]); timeout = 30)
    wid = first(keys(state.workers[]))

    cwd = mktempdir()
    write(joinpath(cwd, "report.txt"), "downloadable line\n" ^ 10)
    file = joinpath(cwd, "report.txt")
    p = BA.create_project_from_worker!(state, wid, cwd; name = "dlchat",
                                       start_session = false)

    download_url(path) = server.h.url * "/download/$(p.id)?path=" * BA.HTTP.escapeuri(path)

    # GET `url` the way a browser takes it: as it arrives. When the headers came,
    # when the first bytes of the body did, when all of it had, and the body.
    function timed_get(url, headers = Pair{String,String}[])
        t0 = time()
        heads = first_bytes = NaN
        body = IOBuffer()
        response = BA.HTTP.open(:GET, url, headers) do stream
            BA.HTTP.startread(stream)
            heads = time() - t0
            while !eof(stream)
                chunk = readavailable(stream)
                isempty(chunk) && continue
                isnan(first_bytes) && (first_bytes = time() - t0)
                write(body, chunk)
            end
        end
        return (; response, heads, first_bytes, all = time() - t0, body = take!(body))
    end

    @testset "worker file download route" begin
        @testset "streams the file as an attachment" begin
            r = BA.HTTP.get(download_url(file))
            @test r.status == 200
            hdrs = Dict(lowercase(k) => v for (k, v) in r.headers)
            @test occursin("attachment", get(hdrs, "content-disposition", ""))
            @test occursin("report.txt", get(hdrs, "content-disposition", ""))
            @test occursin("downloadable line", String(r.body))
        end

        # The bytes go out as they come from the worker. Read whole first, a
        # big download (or a video) showed nothing for seconds to minutes behind
        # the tunnel, and a download clicked again meanwhile ran twice.
        big = joinpath(cwd, "big.bin")
        data = rand(UInt8, 64 * 1024 * 1024)
        write(big, data)
        @testset "a big download starts at once" begin
            g = timed_get(download_url(big))
            @test g.response.status == 200
            @test g.body == data
            @test g.first_bytes < 0.25 * g.all
        end

        # A video asks for `bytes=0-` (all of it) and then for what it needs. It
        # gets a part at a time, with its length (HTTP.jl would hold back a
        # whole file sent with one), and a seek gets the part it asked for.
        @testset "a video gets its range a part at a time" begin
            url = server.h.url * BA.worker_file_url(state, wid, big)
            part = 2 * 1024 * 1024
            g = timed_get(url, ["Range" => "bytes=0-"])
            @test g.response.status == 206
            @test BA.HTTP.header(g.response, "Content-Range") == "bytes 0-$(part - 1)/$(length(data))"
            @test BA.HTTP.header(g.response, "Content-Length") == string(part)
            @test g.body == data[1:part]
            g = timed_get(url, ["Range" => "bytes=$(part)-"])
            @test g.body == data[(part + 1):(2 * part)]
            g = timed_get(url, ["Range" => "bytes=1000000-1999999"])
            @test g.response.status == 206
            @test g.body == data[1000001:2000000]
        end

        @testset "the whole file, asked for without a range, streams" begin
            g = timed_get(server.h.url * BA.worker_file_url(state, wid, big))
            @test g.response.status == 200
            @test g.body == data
            @test g.first_bytes < 0.25 * g.all
        end

        @testset "rejects bad / unsafe input" begin
            # Path traversal / arbitrary worker read outside the project tree.
            @test BA.download_response(state, p.id, "/etc/passwd").status == 403
            @test BA.download_response(state, p.id, joinpath(dirname(cwd), "elsewhere")).status == 403
            # Unknown project, missing path, invalid id.
            @test BA.download_response(state, "nosuchproject", file).status == 404
            @test BA.download_response(state, p.id, "").status == 400
            @test BA.download_response(state, "bad/id", file).status == 404
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server()
    try
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
