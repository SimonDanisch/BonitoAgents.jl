# Server-level regression for "download a worker file to the client".
#
# The file tree's ⤓ button navigates to `/download/<pid>?path=<worker-abs-path>`,
# which `download_response` serves by fetching the file from the worker and
# streaming it back as an attachment. This drives the handler directly (no
# browser): a real worker file is fetched + streamed, the Content-Disposition
# names it, and the path-traversal / bad-input guards reject everything outside
# the project tree. (The dev_server worker is local, so a path we write here is
# readable by the worker — same machine.)

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

    @testset "worker file download route" begin
        @testset "streams the file as an attachment" begin
            r = BA.download_response(state, p.id, file)
            @test r.status == 200
            hdrs = Dict(lowercase(k) => v for (k, v) in r.headers)
            @test occursin("attachment", get(hdrs, "content-disposition", ""))
            @test occursin("report.txt", get(hdrs, "content-disposition", ""))
            @test occursin("downloadable line", String(r.body))
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
