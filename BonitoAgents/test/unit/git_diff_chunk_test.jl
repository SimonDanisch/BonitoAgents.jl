# Headless: the git_diff patch travels the control WS as MULTIPLE frames, not
# one giant send. A multi-MB single frame stalled heartbeats on both ends — the
# worker's send held the socket send lock while its inline pong queued behind
# it, and the server's inline decode of the whole frame fell behind ITS pong
# deadline. Chunking bounds every send and every decompress.
#
# Two halves, exercised with no browser/server:
#   • the worker-side splitter (`chunk_string`) must cut ONLY at codepoint
#     boundaries, so every fragment is itself a valid UTF-8 string the MsgPack
#     wire can carry; and
#   • the server-side reassembler (`deliver_chunk!`) must rebuild the exact
#     bytes the worker sent, in order, and resolve the RPC exactly once the
#     announced `total` has arrived — and fail/evict in the edge cases.
@testitem "unit:git_diff_chunk_reassembly" tags = [:unit] begin
    using Test
    using BonitoAgents
    const BT = BonitoAgents
    import BonitoWorker

    mktempdir() do dir
        st = BT.ServerState(; state_dir = dir,
                              working_dir = joinpath(dir, "work"),
                              worker_secret = "s")

        # A multi-MB patch full of multi-byte codepoints: cuts that land inside a
        # UTF-8 sequence would corrupt the reassembled patch, so the splitter and
        # the assembler both have to be boundary-safe or this byte-compares dirty.
        PATCH = join(("+ línea $i — ünïcødé 日本語 ✓\n" for i in 1:8_000), "")

        @testset "chunk_string splits boundary-safe" begin
            ch = BonitoWorker.chunk_string(PATCH, 1024)
            @test length(ch) > 1
            @test all(isvalid, ch)                          # never a cut mid-codepoint
            @test join(ch) == PATCH                         # byte-exact reassembly
            @test all(c -> ncodeunits(c) <= 1024, ch)

            # Empty input → ONE empty chunk so a caller always has ≥ 1 frame and
            # an empty patch can never be mistaken for a missing reply.
            @test BonitoWorker.chunk_string("") == [""]
            @test BonitoWorker.chunk_string("x", 1024) == ["x"]
        end

        @testset "deliver_chunk! reassembles a multi-frame reply" begin
            chunks = BonitoWorker.chunk_string(PATCH, 64)   # tiny cap → many frames
            rid, ch = BT.register_chunked_rpc!(st)
            for (i, c) in enumerate(chunks)
                f = Dict{String,Any}("type" => "git_diff_chunk", "request_id" => rid,
                                     "index" => Int64(i), "total" => Int64(length(chunks)),
                                     "chunk" => c)
                if i == 1                                   # metadata rides frame 1
                    merge!(f, Dict("repo" => "/r", "branch" => "main",
                                   "head" => "abc123", "base" => "HEAD",
                                   "scope" => "pkg"))
                end
                BT.deliver_chunk!(st, f)
            end
            resp = BT.take_pending!(st, ch, rid, 5.0, "git_diff")
            @test resp["patch"] == PATCH                    # byte-exact, order-preserved
            @test resp["repo"]   == "/r"
            @test resp["branch"] == "main"
            @test resp["head"]   == "abc123"
            @test resp["base"]   == "HEAD"
            @test resp["scope"]  == "pkg"
            @test !haskey(st.pending_chunks, rid)           # RPC fully resolved
        end

        @testset "single-frame shape still resolves (total == 1)" begin
            rid, ch = BT.register_chunked_rpc!(st)
            BT.deliver_chunk!(st, Dict{String,Any}(
                "type" => "git_diff_chunk", "request_id" => rid,
                "index" => Int64(1), "total" => Int64(1), "chunk" => "tiny",
                "repo" => "/r", "branch" => "main", "head" => "abc",
                "base" => "HEAD", "scope" => ""))
            resp = BT.take_pending!(st, ch, rid, 5.0, "git_diff")
            @test resp["patch"] == "tiny"
        end

        @testset "legacy one-frame error reply resolves a chunked registration" begin
            # The worker's ERROR shape is unchanged (`git_diff_response` with an
            # `error` key); the server routes it through deliver_rpc_response!,
            # which serves chunked registrations too. `git_diff_on_worker` then
            # sees haskey(resp, "error") and fails the caller.
            rid, ch = BT.register_chunked_rpc!(st)
            BT.deliver_rpc_response!(st, rid, Dict{String,Any}(
                "type" => "git_diff_response", "request_id" => rid,
                "error" => "not a git repository: /nope"))
            resp = BT.take_pending!(st, ch, rid, 5.0, "git_diff")
            @test haskey(resp, "error")
            @test !haskey(st.pending_chunks, rid)
        end

        @testset "malformed frames surface an error, not a hang" begin
            # `total < 1` announced on frame 1.
            rid, ch = BT.register_chunked_rpc!(st)
            BT.deliver_chunk!(st, Dict{String,Any}(
                "type" => "git_diff_chunk", "request_id" => rid,
                "index" => Int64(1), "total" => Int64(0), "chunk" => ""))
            @test_throws Exception BT.take_pending!(st, ch, rid, 5.0, "git_diff")

            # `index > total` after the metadata frame → deliver_chunk! faults.
            rid, ch = BT.register_chunked_rpc!(st)
            BT.deliver_chunk!(st, Dict{String,Any}(
                "type" => "git_diff_chunk", "request_id" => rid,
                "index" => Int64(1), "total" => Int64(100), "chunk" => ""))
            BT.deliver_chunk!(st, Dict{String,Any}(
                "type" => "git_diff_chunk", "request_id" => rid,
                "index" => Int64(200), "total" => Int64(100), "chunk" => "x"))
            @test_throws Exception BT.take_pending!(st, ch, rid, 5.0, "git_diff")
            @test !haskey(st.pending_chunks, rid)
        end

        @testset "unknown / timed-out ids are silent no-ops" begin
            # A frame for an id that never registered (caller gave up, or the id
            # raced a re-registration) — same contract as deliver_rpc_response!.
            BT.deliver_chunk!(st, Dict{String,Any}(
                "type" => "git_diff_chunk", "request_id" => "ghost",
                "index" => Int64(1), "total" => Int64(1), "chunk" => "x"))
            @test isempty(st.pending_chunks)

            # Not completing within the timeout evicts the accumulator (late
            # chunks then land in the "ghost" branch above).
            rid, ch = BT.register_chunked_rpc!(st)
            BT.deliver_chunk!(st, Dict{String,Any}(
                "type" => "git_diff_chunk", "request_id" => rid,
                "index" => Int64(1), "total" => Int64(5), "chunk" => "a"))
            @test_throws Exception BT.take_pending!(st, ch, rid, 0.2, "git_diff")
            @test !haskey(st.pending_chunks, rid)
        end

        @testset "unregister_rpc! also evicts a chunked registration" begin
            # The `send_command` gap between register and take is the leak the
            # `finally` closes; it must cover the chunked registry too.
            rid, _ = BT.register_chunked_rpc!(st)
            BT.unregister_rpc!(st, rid)
            @test !haskey(st.pending_chunks, rid)
        end
    end
end