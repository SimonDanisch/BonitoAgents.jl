# Every worker reply type has an arm in the server's control-WS dispatch.
#
# `handle_worker_control` is an ALLOW-LIST: a reply type with no arm is dropped,
# the `deliver_rpc_response!` never happens, and the caller sits out its full
# timeout before falling into whatever its error path is. Which means a new RPC
# looks like a slow or unreachable worker rather than like a missing line, and
# the two are diagnosed very differently.
#
# It is a footgun the dispatch's own comment already warns about ("a NEW worker
# RPC whose reply type isn't added above lands here"), and it has now been walked
# into: `find_repos` shipped without its arm, and the review tab's folder picker
# silently fell back to the project folder 15 seconds later. The runtime `@warn`
# is a good backstop, but it only fires if someone is watching a log at the
# moment it happens.
#
# Static and cheap, so it holds for RPCs nothing exercises yet. It compares the
# two sides at their source: what BonitoWorker can SEND against what the server
# will ROUTE.
@testitem "unit:worker_rpc_dispatch" tags = [:unit] begin
    using Test
    import BonitoAgents, BonitoWorker

    worker_src = read(pathof(BonitoWorker), String)
    dispatch   = read(joinpath(dirname(pathof(BonitoAgents)), "worker_client.jl"), String)

    # Reply types the worker constructs: `"type" => "<something>_response"`.
    sent = Set{String}()
    for m in eachmatch(r"\"type\"\s*=>\s*\"([a-z0-9_]+_response)\"", worker_src)
        push!(sent, m.captures[1])
    end
    # The premise of the test. If this ever comes back empty the scan has stopped
    # matching (a refactor of how responses are built) and every assertion below
    # would pass vacuously.
    @test length(sent) >= 8

    # Types the dispatch has an arm for: `t == "<type>"`.
    routed = Set{String}()
    for m in eachmatch(r"t\s*==\s*\"([a-z0-9_]+)\"", dispatch)
        push!(routed, m.captures[1])
    end

    missing_arms = sort(collect(setdiff(sent, routed)))
    @test isempty(missing_arms)
    isempty(missing_arms) || @info "add an arm in handle_worker_control" missing_arms

    # And the one that started this, by name — so the regexes above drifting
    # can't quietly retire the case that was actually broken.
    @test "find_repos_response" in sent
    @test "find_repos_response" in routed
    @test "git_diff_response" in routed

    # The chunked variant of git_diff was added later, when the patch started
    # crossing the link as multiple frames: the worker emits `git_diff_chunk`
    # frames (no `_response` suffix!) and the server must ROUTE them to the
    # reassembler. The regexes above can't see either of these.
    @test occursin(r"git_diff_chunk", worker_src)
    @test "git_diff_chunk" in routed
    @test occursin(r"deliver_chunk!\(state, cmd\)", dispatch)
end
