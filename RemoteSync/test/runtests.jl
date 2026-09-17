using RemoteSync
using Test
using Random
using SHA

# ── Bidirectional in-process IO for tests ──────────────────────────────────
# Two BufferStreams glued together: side A's reads come from side B's writes
# and vice versa. Lets us run send_directory/receive_directory in two tasks
# without spinning up sockets or subprocesses.
mutable struct BidirIO <: IO
    in_io  :: IO
    out_io :: IO
end

function pipe_pair()
    a_to_b = Base.BufferStream()
    b_to_a = Base.BufferStream()
    return BidirIO(b_to_a, a_to_b), BidirIO(a_to_b, b_to_a)
end

Base.read(io::BidirIO, ::Type{UInt8}) = read(io.in_io, UInt8)
Base.read(io::BidirIO, n::Integer) = read(io.in_io, n)
Base.readbytes!(io::BidirIO, dst, n = length(dst)) = readbytes!(io.in_io, dst, n)
Base.eof(io::BidirIO) = eof(io.in_io)
Base.bytesavailable(io::BidirIO) = bytesavailable(io.in_io)
Base.write(io::BidirIO, b::UInt8) = write(io.out_io, b)
Base.unsafe_write(io::BidirIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.out_io, p, n)
Base.flush(io::BidirIO) = flush(io.out_io)
Base.close(io::BidirIO) = (close(io.in_io); close(io.out_io))
Base.isopen(io::BidirIO) = isopen(io.in_io) || isopen(io.out_io)

# Helper: build a deterministic pseudo-binary file of `n` bytes seeded by
# `seed`. Same input → same output, so we can compare sha256 between runs.
function make_blob(n::Int; seed::UInt64 = UInt64(0xCAFEBABEDEADBEEF))
    rng = Random.Xoshiro(seed)
    return rand(rng, UInt8, n)
end

# ── Layer 1: librsync primitives ───────────────────────────────────────────
@testset "primitives" begin
    @testset "signature is reproducible" begin
        basis = make_blob(50_000)
        s1 = IOBuffer(); s2 = IOBuffer()
        compute_signature(IOBuffer(basis), s1)
        compute_signature(IOBuffer(basis), s2)
        b1 = take!(s1); b2 = take!(s2)
        @test b1 == b2
        @test !isempty(b1)
    end

    @testset "patch reconstructs original (identity case)" begin
        # When new == basis, the delta should rebuild basis byte-for-byte.
        basis = make_blob(20_000)
        sig = IOBuffer(); compute_signature(IOBuffer(basis), sig)
        seekstart(sig)
        delta = IOBuffer()
        compute_delta(sig, IOBuffer(basis), delta)
        seekstart(delta)
        out = IOBuffer()
        apply_patch(IOBuffer(basis), delta, out)
        @test take!(out) == basis
    end

    @testset "patch reconstructs new (with edits)" begin
        basis = make_blob(40_000; seed = UInt64(1))
        new   = copy(basis)
        # Insert + change a chunk in the middle so delta has both copy + literal cmds.
        splice!(new, 10_000:11_000, make_blob(2_000; seed = UInt64(2)))

        sig = IOBuffer(); compute_signature(IOBuffer(basis), sig); seekstart(sig)
        delta = IOBuffer(); compute_delta(sig, IOBuffer(new), delta); seekstart(delta)
        out = IOBuffer(); apply_patch(IOBuffer(basis), delta, out)
        @test take!(out) == new
    end

    @testset "patch reconstructs new (no basis)" begin
        new = make_blob(5_000; seed = UInt64(3))
        # Empty basis → "all literal" delta — the path send_directory uses
        # for files the receiver doesn't have.
        sig = IOBuffer(); compute_signature(IOBuffer(UInt8[]), sig); seekstart(sig)
        delta = IOBuffer(); compute_delta(sig, IOBuffer(new), delta); seekstart(delta)
        out = IOBuffer(); apply_patch(IOBuffer(UInt8[]), delta, out)
        @test take!(out) == new
    end

    @testset "delta is much smaller than full file when basis is close" begin
        basis = make_blob(100_000; seed = UInt64(4))
        new   = copy(basis); new[50_001] ⊻= 0xFF   # one-byte edit
        sig = IOBuffer(); compute_signature(IOBuffer(basis), sig); seekstart(sig)
        delta = IOBuffer(); compute_delta(sig, IOBuffer(new), delta)
        @test position(delta) < length(new) ÷ 4  # generous bound
    end
end

# ── Layer 2: wire format round-trips ───────────────────────────────────────
@testset "wire format" begin
    using RemoteSync: ManifestEntry, PlanEntry,
                      encode_manifest, decode_manifest,
                      encode_plan,     decode_plan,
                      encode_delta_frame, decode_delta_frame,
                      ACTION_FULL, ACTION_PATCH, ACTION_SKIP, ACTION_DELETE,
                      write_frame, read_frame, TAG_MANIFEST
    # Tests reach into the internals; that's fine — they're qualified above.

    @testset "manifest round-trip" begin
        entries = [ManifestEntry("a.txt", UInt64(10), 1.5),
                   ManifestEntry("nested/dir/b.bin", UInt64(99999), 1234567.89)]
        decoded = decode_manifest(encode_manifest(entries))
        @test length(decoded) == 2
        @test decoded[1].rel == "a.txt" && decoded[1].size == 10 && decoded[1].mtime == 1.5
        @test decoded[2].rel == "nested/dir/b.bin"
    end

    @testset "plan round-trip" begin
        plan = [PlanEntry("a", ACTION_FULL,   UInt8[]),
                PlanEntry("b", ACTION_PATCH,  UInt8[1, 2, 3, 4, 5]),
                PlanEntry("c", ACTION_SKIP,   UInt8[]),
                PlanEntry("d", ACTION_DELETE, UInt8[])]
        decoded = decode_plan(encode_plan(plan))
        @test length(decoded) == 4
        @test decoded[2].action == ACTION_PATCH && decoded[2].sig == UInt8[1, 2, 3, 4, 5]
    end

    @testset "delta frame round-trip" begin
        rel = "deeply/nested/file.bin"; bytes = make_blob(1_500)
        rel2, b2 = decode_delta_frame(encode_delta_frame(rel, bytes))
        @test rel == rel2 && b2 == bytes
    end

    @testset "framed write/read survives mixed payloads" begin
        a, b = pipe_pair()
        @async begin
            write_frame(a, TAG_MANIFEST, UInt8[1, 2, 3])
            write_frame(a, UInt8(0x77), UInt8[])
            write_frame(a, UInt8(0x99), make_blob(10_000))
            close(a)
        end
        t1, p1 = read_frame(b); @test t1 == TAG_MANIFEST && p1 == UInt8[1, 2, 3]
        t2, p2 = read_frame(b); @test t2 == 0x77         && isempty(p2)
        t3, p3 = read_frame(b); @test t3 == 0x99         && length(p3) == 10_000
    end
end

# ── Layer 3: directory sync end-to-end ─────────────────────────────────────
function dir_hash(root)
    h = SHA.SHA256_CTX()
    files = String[]
    for (dir, _, fs) in walkdir(root)
        for f in fs
            push!(files, relpath(joinpath(dir, f), root))
        end
    end
    sort!(files)
    for rel in files
        SHA.update!(h, codeunits(rel * "\0"))
        SHA.update!(h, read(joinpath(root, rel)))
        SHA.update!(h, UInt8[0])
    end
    return SHA.digest!(h)
end

# Run sender + receiver in two tasks bridged by a pipe pair. Returns the
# (written, deleted, skipped) Stats from the receiver. Keyword arguments go to
# `receive_directory` (`delete_extraneous`, `quick_check`).
function run_sync(src, dst; kw...)
    a, b = pipe_pair()
    sender_done = Channel{Any}(1)
    receiver_done = Channel{Any}(1)
    @async try
        send_directory(src, a)
        put!(sender_done, :ok)
    catch e
        put!(sender_done, e)
    finally
        close(a)
    end
    @async try
        result = receive_directory(dst, b; kw...)
        put!(receiver_done, result)
    catch e
        put!(receiver_done, e)
    finally
        close(b)
    end
    s = take!(sender_done); r = take!(receiver_done)
    r isa Exception && throw(r)      # a receiver refusal EOFs the sender: report the cause
    s isa Symbol || throw(s)
    return r
end

# ── Layer 4: WebSocketIO over a real loopback HTTP.WebSocket ──────────────
# Exercises the WS adapter's framed write/flush + buffered read across a real
# socket — guards against IOBuffer-vs-bytesavailable footguns and similar
# adapter regressions.
@testset "WebSocketIO over loopback HTTP.WebSocket" begin
    using HTTP, HTTP.WebSockets
    # No registration call needed — the HTTP.WebSockets adapter for
    # WebSocketIO lives directly in src/websocketio.jl (used to be a
    # package extension; was inlined in b1bf51b).

    server_done = Channel{Any}(1)
    # Pick a likely-free high port; HTTP.WebSockets.listen! returns a Server
    # whose `listener` we can poke for the actual bound port if needed.
    port = rand(40000:60000)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        try
            wsio = WebSocketIO(ws)
            stats = receive_directory(mktempdir(), wsio)
            put!(server_done, stats)
        catch e
            put!(server_done, e)
        end
    end
    sleep(0.2)

    # Sender side: do a fresh sync of a tiny dir.
    src = mktempdir()
    write(joinpath(src, "alpha.txt"), "ws-io smoke test")
    write(joinpath(src, "blob.bin"), make_blob(10_000; seed = UInt64(99)))
    try
        client_done = Channel{Any}(1)
        @async try
            HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
                wsio = WebSocketIO(ws)
                send_directory(src, wsio)
            end
            put!(client_done, :ok)
        catch e
            put!(client_done, e)
        end

        # Both sides should finish well within a few seconds.
        s = nothing
        for _ in 1:30
            isready(server_done) && (s = take!(server_done); break)
            sleep(0.1)
        end
        c = isready(client_done) ? take!(client_done) : :TIMEOUT

        @test s isa NamedTuple
        @test s.written == 2
        @test c === :ok
    finally
        rm(src; recursive=true, force=true)
        close(server)
    end
end

# ── Regression: single-file transfer must not lose its tail on sender close ──
# A sender that closes the WS the instant `send_file` returns races HTTP.jl's
# close against the frames the receiver hasn't drained yet — the receiver EOFs
# mid-file (observed ~90% under load; surfaced as "the file won't open" in the
# editor). `wait_peer_close` makes the sender wait for the receiver to finish +
# close FIRST. This drives many back-to-back transfers through one server and
# asserts every one arrives intact.
@testset "single-file WS transfer survives immediate sender close" begin
    using HTTP, HTTP.WebSockets
    src = tempname()
    write(src, "the quick brown fox\n" ^ 64)   # small file = worst case for the race
    want = read(src, String)
    port = rand(45000:59000)
    results = Channel{Any}(64)
    got     = Channel{String}(64)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        try
            dst = tempname()
            receive_file(dst, WebSocketIO(ws))   # receiver returns → handler closes FIRST
            put!(got, read(dst, String))
            put!(results, :ok)
        catch e
            put!(results, e)
        end
    end
    try
        sleep(0.3)
        n = 40
        for _ in 1:n
            HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
                wsio = WebSocketIO(ws)
                send_file(src, wsio)
                wait_peer_close(wsio)            # ← the fix: don't close before the receiver drained
            end
        end
        oks = 0; contents = String[]
        for _ in 1:n
            r = nothing
            for _ in 1:300; isready(results) && (r = take!(results); break); sleep(0.01); end
            r === :ok && (oks += 1)
            isready(got) && push!(contents, take!(got))
        end
        @test oks == n                                   # every transfer completed
        @test all(==(want), contents)                    # …and arrived byte-for-byte intact
    finally
        rm(src; force = true)
        close(server)
    end
end

# ── Stress: directory sync must survive immediate sender close, repeatedly ───
# Companion to the single-file regression above. A directory sender also writes
# its final frame (TAG_DONE) and then closes — the same close-vs-tail shape that
# truncates single-file transfers. It DOESN'T truncate here because the protocol
# is lockstep (the sender blocks on each per-file TAG_OK, so it never runs ahead
# of the receiver and the receiver is already parked in `read_frame` when DONE
# arrives). This test pins that property: many back-to-back transfers through one
# server, sender closing the instant `send_directory` returns, every one intact.
# If a future change breaks the lockstep pacing, this goes red instead of the bug
# surfacing as a flaky "sync truncated" in production.
# HTTP 2's websocket closes the connection (1009) on any single incoming message
# over 16 MiB, and a file's delta used to be sent as ONE message: a 20 MiB file
# crossed as a 20 MiB message and the receiver dropped the socket, so the sender
# saw "Broken pipe" and the receiver EOF (a 57 MB sync between two workers,
# 2026-09-15). Logical frames are now split into messages of at most
# `MAX_WS_MESSAGE_BYTES`; the receiver reads a byte stream and never notices.
@testset "a file larger than the websocket message limit crosses in pieces" begin
    using HTTP, HTTP.WebSockets
    isdefined(HTTP.WebSockets, :DEFAULT_MAX_FRAME_SIZE) &&
        @test RemoteSync.MAX_WS_MESSAGE_BYTES < HTTP.WebSockets.DEFAULT_MAX_FRAME_SIZE
    src = mktempdir(); dst = mktempdir()
    big = make_blob(20 * 1024 * 1024 + 12345; seed = UInt64(21))
    write(joinpath(src, "big.bin"), big)
    port = rand(40000:60000)
    server_done = Channel{Any}(1)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        try
            put!(server_done, receive_directory(dst, WebSocketIO(ws)))
        catch e
            put!(server_done, e)
        end
    end
    try
        sleep(0.2)
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
            send_directory(src, WebSocketIO(ws))
        end
        s = take!(server_done)
        @test !(s isa Exception)
        @test read(joinpath(dst, "big.bin")) == big
    finally
        close(server)
    end
end

@testset "directory sync survives immediate sender close (stress)" begin
    using HTTP, HTTP.WebSockets
    src = mktempdir()
    for k in 1:8; write(joinpath(src, "f$k.txt"), "file $k payload " ^ 16); end
    write(joinpath(src, "blob.bin"), make_blob(80_000; seed = UInt64(7)))
    mkpath(joinpath(src, "sub")); write(joinpath(src, "sub", "n.bin"),
                                        make_blob(20_000; seed = UInt64(8)))
    port = rand(45000:59000)
    results = Channel{Any}(64)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        try
            stats = receive_directory(mktempdir(), WebSocketIO(ws))
            put!(results, stats)
        catch e
            put!(results, e)
        end
    end
    try
        sleep(0.3)
        n = 30
        for _ in 1:n
            HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
                send_directory(src, WebSocketIO(ws))   # close fires the instant this returns
            end
        end
        oks = 0
        for _ in 1:n
            r = nothing
            for _ in 1:400; isready(results) && (r = take!(results); break); sleep(0.01); end
            r isa NamedTuple && r.written == 10 && (oks += 1)
        end
        @test oks == n
    finally
        rm(src; recursive = true, force = true)
        close(server)
    end
end

@testset "directory sync" begin
    @testset "fresh sync (empty dst)" begin
        src = mktempdir(); dst = mktempdir()
        try
            mkpath(joinpath(src, "sub"))
            write(joinpath(src, "a.txt"), "hello world")
            write(joinpath(src, "sub", "b.bin"), make_blob(40_000))
            stats = run_sync(src, dst)
            @test stats.written == 2 && stats.deleted == 0 && stats.skipped == 0
            @test dir_hash(src) == dir_hash(dst)
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end

    @testset "incremental sync (some files match, one edited, one deleted)" begin
        src = mktempdir(); dst = mktempdir()
        try
            # Both sides start with identical contents.
            mkpath(joinpath(src, "x"))
            write(joinpath(src, "match.txt"), "stable")
            write(joinpath(src, "x", "edit.bin"), make_blob(20_000; seed = UInt64(10)))
            write(joinpath(src, "gone.txt"), "to-be-deleted")
            cp(src, dst; force = true)
            # Sleep past mtime resolution so the rewrite below is detectable
            # by the size+mtime shortcut. Without this, on fast machines + low-
            # resolution FSs the rewrite can land in the same mtime tick as cp,
            # causing the receiver to skip the file (correct per rsync's quick-
            # check heuristic, but defeats this test's intent).
            sleep(1.1)
            # Now diverge: edit one file, remove "gone".
            write(joinpath(src, "x", "edit.bin"), make_blob(20_000; seed = UInt64(11)))
            rm(joinpath(src, "gone.txt"))
            # And add a new file post-clone.
            write(joinpath(src, "fresh.dat"), make_blob(1_000; seed = UInt64(12)))

            stats = run_sync(src, dst; delete_extraneous = true)   # a mirror, by request
            @test dir_hash(src) == dir_hash(dst)
            @test stats.deleted == 1
            # The matched file should have skipped; the new + edited counted.
            @test stats.written >= 1
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end

    @testset "syncs .git/ (project history must round-trip)" begin
        src = mktempdir(); dst = mktempdir()
        try
            # Representative .git layout: a ref, an object, an info file.
            mkpath(joinpath(src, ".git", "refs", "heads"))
            mkpath(joinpath(src, ".git", "objects", "ab"))
            write(joinpath(src, ".git", "HEAD"), "ref: refs/heads/main")
            write(joinpath(src, ".git", "refs", "heads", "main"), "deadbeef\n")
            write(joinpath(src, ".git", "objects", "ab", "cdef1234"), "\x78\x01" * "blob")
            write(joinpath(src, "real.txt"), "kept")
            run_sync(src, dst)
            @test isfile(joinpath(dst, "real.txt"))
            @test isdir(joinpath(dst, ".git"))
            @test read(joinpath(dst, ".git", "HEAD"), String) == "ref: refs/heads/main"
            @test read(joinpath(dst, ".git", "refs", "heads", "main"), String) == "deadbeef\n"
            @test read(joinpath(dst, ".git", "objects", "ab", "cdef1234")) ==
                  Vector{UInt8}("\x78\x01" * "blob")
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end

    @testset "no directories excluded (mirrors the project tree verbatim)" begin
        # `.bonitoAgents/` used to be skipped to protect the server's chat
        # history from being wiped during a worker→server pull. Chat
        # storage now lives under `<state_dir>/chats/<project_id>/`,
        # outside any project tree, so the sync is plain mirror.
        src = mktempdir(); dst = mktempdir()
        try
            mkpath(joinpath(src, ".bonitoAgents"))
            write(joinpath(src, ".bonitoAgents", "chat.md"), "if present, sync it")
            mkpath(joinpath(src, ".cache"))
            write(joinpath(src, ".cache", "x"), "anything goes")
            write(joinpath(src, "real.txt"), "kept")
            run_sync(src, dst)
            @test read(joinpath(dst, ".bonitoAgents", "chat.md"), String) == "if present, sync it"
            @test read(joinpath(dst, ".cache", "x"), String) == "anything goes"
            @test read(joinpath(dst, "real.txt"), String) == "kept"
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end

    @testset "progress callback fires expected stages" begin
        src = mktempdir(); dst = mktempdir()
        try
            write(joinpath(src, "a.bin"), make_blob(5_000))
            write(joinpath(src, "b.bin"), make_blob(7_000))
            stages_sender = Symbol[]
            stages_receiver = Symbol[]

            a, b = pipe_pair()
            @async (try
                send_directory(src, a; on_progress = (s, _) -> push!(stages_sender, s))
            finally
                close(a)
            end)
            receive_directory(dst, b; on_progress = (s, _) -> push!(stages_receiver, s))
            close(b)

            @test :walk_done       in stages_sender
            @test :transfer_done   in stages_sender
            @test :manifest_received in stages_receiver
            @test :transfer_done    in stages_receiver
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end

    # Deleting what the sender lacks is a mirror's job and is asked for
    # explicitly; a plain transfer adds and updates, nothing more. And no
    # transfer, mirror or not, empties a populated folder for an EMPTY source:
    # a project move once pushed a never-synced (empty) server mirror with
    # mirror semantics and deleted every file of a live project (2026-09-15).
    @testset "deletions are opt-in and never driven by an empty source" begin
        src = mktempdir(); dst = mktempdir()
        try
            write(joinpath(src, "shared.txt"), "from the sender")
            write(joinpath(dst, "mine.txt"), "only the receiver has this")
            stats = run_sync(src, dst)                      # default: additive
            @test stats.deleted == 0
            @test read(joinpath(dst, "mine.txt"), String) == "only the receiver has this"
            @test read(joinpath(dst, "shared.txt"), String) == "from the sender"

            empty_src = mktempdir()
            err = try run_sync(empty_src, dst; delete_extraneous = true); nothing catch e; e end
            @test err isa ErrorException
            @test occursin("refusing to delete 2 local file(s)", sprint(showerror, err))
            @test read(joinpath(dst, "mine.txt"), String) == "only the receiver has this"
            @test isfile(joinpath(dst, "shared.txt"))

            stats = run_sync(empty_src, dst)                # additive from empty: a no-op
            @test stats.deleted == 0 && stats.written == 0
            @test isfile(joinpath(dst, "mine.txt")) && isfile(joinpath(dst, "shared.txt"))
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end

    @testset "large file (multi-MB) round-trips correctly" begin
        src = mktempdir(); dst = mktempdir()
        try
            write(joinpath(src, "big.bin"), make_blob(2_000_000; seed = UInt64(99)))
            run_sync(src, dst)
            @test dir_hash(src) == dir_hash(dst)
        finally
            rm(src; recursive=true, force=true)
            rm(dst; recursive=true, force=true)
        end
    end
end

# ── Stability / security regressions (R1, R3, R4, R5, R7) ───────────────────
const RS = RemoteSync

# Fake frame transports for WebSocketIO tests. Must be top-level (struct defs
# can't live in a @testset's local scope).
mutable struct FakeWS
    sent   :: Vector{Vector{UInt8}}
    closed :: Bool
end
RS.send_frame!(ws::FakeWS, bytes::AbstractVector{UInt8}) = (push!(ws.sent, Vector{UInt8}(bytes)); nothing)
RS.recv_frame(::FakeWS) = nothing
RS.is_closed(ws::FakeWS) = ws.closed
RS.close_ws!(ws::FakeWS) = (ws.closed = true; nothing)

mutable struct BlockingWS
    gate :: Channel{Nothing}
end
RS.recv_frame(ws::BlockingWS) = (take!(ws.gate); UInt8[0x41])   # blocks until released
RS.send_frame!(::BlockingWS, ::AbstractVector{UInt8}) = nothing
RS.is_closed(::BlockingWS) = false
RS.close_ws!(::BlockingWS) = nothing

@testset "stability regressions" begin

    # ── R1: path-traversal guard rejects escaping rels on both sides ─────────
    @testset "R1 safe_rel rejects escaping/absolute paths" begin
        root = mktempdir()
        try
            # Legitimate rels normalize and pass.
            @test RS.safe_rel(root, "a/b.txt") == "a/b.txt"
            @test RS.safe_rel(root, "a/../b.txt") == "b.txt"     # collapses, stays inside
            @test RS.safe_rel(root, "./c.txt") == "c.txt"

            # Escaping / absolute / empty are rejected (return nothing).
            @test RS.safe_rel(root, "../escape") === nothing
            @test RS.safe_rel(root, "../../etc/passwd") === nothing
            @test RS.safe_rel(root, "a/../../escape") === nothing
            @test RS.safe_rel(root, "/abs/path") === nothing
            @test RS.safe_rel(root, "/etc/passwd") === nothing
            @test RS.safe_rel(root, "") === nothing
            @test RS.safe_rel(root, "..") === nothing
        finally
            rm(root; recursive = true, force = true)
        end
    end

    # ── R1 (receiver): an unsafe manifest entry never lands outside root ─────
    @testset "R1 build_plan drops unsafe manifest entries" begin
        root = mktempdir()
        try
            manifest = RS.ManifestEntry[
                RS.ManifestEntry("ok.txt", UInt64(3), 0.0),
                RS.ManifestEntry("../evil.txt", UInt64(3), 0.0),
                RS.ManifestEntry("/etc/evil", UInt64(3), 0.0),
            ]
            plan = RS.build_plan(root, manifest)
            rels = Set(p.rel for p in plan)
            @test "ok.txt" in rels
            @test !("../evil.txt" in rels)
            @test !("/etc/evil" in rels)
            @test !any(p -> occursin("evil", p.rel), plan)
        finally
            rm(root; recursive = true, force = true)
        end
    end

    # ── quick_check=false bypasses the size+mtime skip heuristic ─────────────
    # The heuristic has a real false-negative: two same-length variants
    # written within the same clock tick ("FROM A\n" vs "FROM B\n") match
    # size+mtime and would silently keep the stale side. Directional
    # overwrites (cross-worker sync) pass quick_check=false to force the
    # signature/delta exchange for every shared file.
    @testset "build_plan quick_check toggles the skip heuristic" begin
        root = mktempdir()
        try
            local_path = joinpath(root, "README.md")
            write(local_path, "FROM B\n")
            st = stat(local_path)
            # Manifest entry with IDENTICAL size + mtime but different content.
            manifest = RS.ManifestEntry[
                RS.ManifestEntry("README.md", UInt64(st.size), Float64(st.mtime)),
            ]

            plan_quick = RS.build_plan(root, manifest)               # default true
            @test length(plan_quick) == 1
            @test plan_quick[1].action == RS.ACTION_SKIP             # the false-negative

            plan_full = RS.build_plan(root, manifest; quick_check = false)
            @test length(plan_full) == 1
            @test plan_full[1].action == RS.ACTION_PATCH             # delta-checked
            @test !isempty(plan_full[1].sig)                         # carries a signature
        finally
            rm(root; recursive = true, force = true)
        end
    end

    # ── R3: oversized / malformed frame lengths are refused, not allocated ────
    @testset "R3 frame size caps" begin
        @test RS.MAX_FRAME_BYTES < typemax(UInt32)   # cap leaves room to exceed

        # read_frame refuses a length prefix above the cap (a 4 GiB claim) and
        # never tries to allocate it.
        buf = IOBuffer()
        write(buf, UInt8(RS.TAG_DELTA))
        write(buf, htol(typemax(UInt32)))            # ~4 GiB announced length
        seekstart(buf)
        @test_throws ErrorException RS.read_frame(buf)

        # A crafted manifest whose inner rel_len exceeds the frame is rejected
        # rather than driving a giant allocation.
        bad = IOBuffer()
        write(bad, htol(UInt32(1)))             # 1 entry
        write(bad, htol(UInt32(1_000_000)))     # rel_len far beyond remaining bytes
        @test_throws Exception RS.decode_manifest(take!(bad))

        # A crafted entry count larger than the frame is rejected up front.
        bad2 = IOBuffer()
        write(bad2, htol(UInt32(1_000_000)))    # claims a million entries, 4 bytes total
        @test_throws Exception RS.decode_manifest(take!(bad2))
    end

    # ── R3: a valid round-trip still works (cap doesn't break normal frames) ──
    @testset "R3 normal manifest round-trips" begin
        m = RS.ManifestEntry[RS.ManifestEntry("a/b.txt", UInt64(10), 1.5)]
        decoded = RS.decode_manifest(RS.encode_manifest(m))
        @test length(decoded) == 1
        @test decoded[1].rel == "a/b.txt"
        @test decoded[1].size == UInt64(10)
    end

    # ── R4: WebSocketIO close flushes, closes the ws, and warns on failure ────
    # A tiny fake frame transport lets us assert close behaviour without HTTP.
    @testset "R4 WebSocketIO.close closes the underlying transport" begin
        ws = FakeWS(Vector{UInt8}[], false)
        io = RS.WebSocketIO(ws)
        write(io, UInt8[1, 2, 3])
        close(io)
        @test ws.closed                       # underlying ws actually closed (R4)
        @test !isempty(ws.sent)               # buffered bytes were flushed first
        @test ws.sent[end] == UInt8[1, 2, 3]
    end

    # ── R5: a second concurrent reader is detected and refused ───────────────
    @testset "R5 concurrent read is rejected" begin
        ws = BlockingWS(Channel{Nothing}(0))
        io = RS.WebSocketIO(ws)
        # First reader parks inside recv_frame holding the read guard.
        r1 = @async read(io, UInt8)
        sleep(0.1)
        # Second reader must hit the single-consumer guard immediately.
        @test_throws ErrorException read(io, UInt8)
        put!(ws.gate, nothing)                # release the first reader
        @test fetch(r1) == 0x41
    end
end
