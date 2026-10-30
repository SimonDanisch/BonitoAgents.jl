const RS = RemoteSync

mutable struct CountIO{T<:IO} <: IO
    io::T
    flushes::Int
end
CountIO(io) = CountIO(io, 0)
Base.read(io::CountIO, ::Type{UInt8}) = read(io.io, UInt8)
Base.read(io::CountIO, n::Integer) = read(io.io, n)
Base.readbytes!(io::CountIO, data::AbstractArray{UInt8}, n = length(data)) = readbytes!(io.io, data, n)
Base.eof(io::CountIO) = eof(io.io)
Base.write(io::CountIO, b::UInt8) = write(io.io, b)
Base.unsafe_write(io::CountIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.io, p, n)
Base.flush(io::CountIO) = (io.flushes += 1; flush(io.io))
Base.close(io::CountIO) = close(io.io)

function protocol_copy(src, dst; sender_streaming = true, receiver_streaming = true,
                       relay = false, quick_check = true, paths = nothing, on_progress = nothing)
    sender, middle_src = pipe_pair()
    middle_dst, receiver = relay ? pipe_pair() : (nothing, middle_src)
    counted = CountIO(receiver)
    t_send = @async try
        RS.send_directory(src, sender; paths, streaming = sender_streaming)
    finally
        close(sender)
    end
    t_receive = @async try
        RS.receive_directory(dst, counted; streaming = receiver_streaming, quick_check)
    finally
        close(counted)
    end
    t_relay = relay ? (@async try
        RS.relay_directory(middle_src, middle_dst; on_progress)
    finally
        close(middle_src); close(middle_dst)
    end) : nothing
    forwarded = t_relay === nothing ? nothing : fetch(t_relay)
    result = fetch(t_receive)
    wait(t_send)
    return (; result, replies = counted.flushes, forwarded)
end

@testset "selected file and folder batches" begin
    mktempdir() do root
        src = mkpath(joinpath(root, "src"))
        mkpath(joinpath(src, "nested", "deeper"))
        write(joinpath(src, "one.txt"), "one")
        write(joinpath(src, "nested", "two.txt"), "two")
        write(joinpath(src, "nested", "deeper", "three.txt"), "three")
        write(joinpath(src, "excluded.txt"), "excluded")
        selection = ["one.txt", "nested", "nested/two.txt"]
        @test getproperty.(RS.walk_directory(src; paths = selection), :rel) ==
            ["nested/deeper/three.txt", "nested/two.txt", "one.txt"]
        @test length(RS.walk_directory(src; paths = [".", "one.txt", "nested"])) == 4
        for streaming in (false, true)
            dst = mkpath(joinpath(root, "dst-$streaming"))
            write(joinpath(dst, "keep.txt"), "destination only")
            events = Tuple{Symbol,Any}[]
            r = protocol_copy(src, dst; paths = selection, relay = true,
                sender_streaming = streaming, on_progress = (s, i) -> push!(events, (s, i)))
            @test r.result.written == 3
            @test read(joinpath(dst, "nested", "deeper", "three.txt"), String) == "three"
            @test read(joinpath(dst, "keep.txt"), String) == "destination only"
            @test !isfile(joinpath(dst, "excluded.txt"))
            @test [i.idx for (s,i) in events if s == :file_done] == [1,2,3]
            @test count(e -> first(e) == :file_start, events) == 3
            @test sum(i.bytes for (s,i) in events if s == :file_chunk) > 0
            @test last(events)[1] == :transfer_done
            r = protocol_copy(src, dst; paths = selection, relay = true, sender_streaming = streaming)
            @test r.result.skipped == (Sys.iswindows() ? 0 : 3)
        end
        for paths in (String[], "one.txt", [1], ["../escape"], ["/absolute"], ["missing"], [""])
            @test_throws ArgumentError RS.walk_directory(src; paths)
        end
    end
end

@testset "streaming negotiation, relaying and incremental sync" begin
    for relay in (false, true), sender_streaming in (false, true), receiver_streaming in (false, true)
        @testset "relay=$relay sender=$sender_streaming receiver=$receiver_streaming" begin
            mktempdir() do dir
                src = mkpath(joinpath(dir, "src")); dst = mkpath(joinpath(dir, "dst"))
                write(joinpath(dst, "private.txt"), "keep destination-only file")
                payload = make_blob(2 * RS.DIRECTORY_CHUNK_BYTES + 317)
                write(joinpath(src, "large.bin"), payload)
                write(joinpath(src, "empty"), "")
                for i in 1:80
                    write(joinpath(src, "small-$i"), "payload-$i")
                end
                r = protocol_copy(src, dst; relay, sender_streaming, receiver_streaming)
                @test r.result == (written = 82, deleted = 0, skipped = 0)
                @test r.replies == (sender_streaming && receiver_streaming ? 2 : 83)
                @test read(joinpath(dst, "large.bin")) == payload
                @test isfile(joinpath(dst, "empty")) && filesize(joinpath(dst, "empty")) == 0
                @test read(joinpath(dst, "small-42"), String) == "payload-42"
                @test read(joinpath(dst, "private.txt"), String) == "keep destination-only file"
                relay && @test r.forwarded.written == 82 && r.forwarded.deleted == 0

                # Force the signature/delta path even when size and mtime match.
                payload[1000:1031] .= 0x81
                write(joinpath(src, "large.bin"), payload)
                r = protocol_copy(src, dst; relay, sender_streaming, receiver_streaming, quick_check = false)
                @test r.result.written == 82
                @test read(joinpath(dst, "large.bin")) == payload

                r = protocol_copy(src, dst; relay, sender_streaming, receiver_streaming)
                @test r.result.skipped == (Sys.iswindows() ? 0 : 82)
                @test r.result.deleted == 0
                relay && @test r.forwarded.skipped == r.result.skipped
            end
        end
    end
end

@testset "streamed failures preserve the destination" begin
    mktempdir() do root
        old = joinpath(root, "old.bin"); write(old, "original")
        entry = RS.ManifestEntry("old.bin", UInt64(10), time())
        plan = RS.PlanEntry("old.bin", RS.ACTION_FULL, UInt8[])
        for case in (:truncated, :short, :excess, :oversized, :wrong_path)
            io = IOBuffer()
            RS.write_frame(io, RS.TAG_STREAM, Vector{UInt8}(case == :wrong_path ? "../escape" : "old.bin"))
            if case == :oversized
                write(io, RS.TAG_DATA); write(io, htol(UInt32(RS.DIRECTORY_CHUNK_BYTES + 1)))
            else
                RS.write_frame(io, RS.TAG_DATA, fill(UInt8(1), case == :excess ? 11 : 5))
                case == :truncated || RS.write_frame(io, RS.TAG_END)
            end
            seekstart(io)
            @test_throws Union{EOFError,ErrorException} RS.receive_streamed_entry(root, io, plan, entry)
            @test read(old, String) == "original"
            @test !isfile(old * ".partial")
        end
    end
end

@testset "large basis copies use a bounded callback buffer" begin
    ctx = RS.PatchBasisCtx(IOBuffer(fill(UInt8(0x42), 1024 * 1024)), zeros(UInt8, 4096))
    requested = Ref{Csize_t}(1024 * 1024)
    ptr = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve ctx requested ptr begin
        @test RS._basis_copy_cb_impl(pointer_from_objref(ctx), Clonglong(0),
            Base.unsafe_convert(Ptr{Csize_t}, requested),
            Base.unsafe_convert(Ptr{Ptr{UInt8}}, ptr)) == RS.RS_DONE
        @test requested[] == 4096
        @test length(ctx.buf) == 4096
        @test all(==(0x42), ctx.buf)
    end
end

@testset "streaming sender requires final acknowledgement" begin
    mktempdir() do src
        write(joinpath(src, "file"), "contents")
        sender, receiver = pipe_pair()
        peer = @async try
            _, payload = RS.read_frame(receiver)
            manifest = RS.decode_manifest(payload)
            plan = [RS.PlanEntry(e.rel, RS.ACTION_FULL, UInt8[]) for e in manifest]
            RS.write_frame(receiver, RS.TAG_PLAN, RS.encode_plan(plan; streaming = true))
            while first(RS.read_frame(receiver)) != RS.TAG_DONE end
            # Simulate an aborted receiver instead of confirming the write.
        finally
            close(receiver)
        end
        @test_throws EOFError RS.send_directory(src, sender)
        wait(peer)
        close(sender)
    end
end

@testset "streaming can cross the legacy whole-file frame limit" begin
    # A sparse source avoids retaining a giant test array. Its bytes still go
    # through the real streaming protocol and are compared with SHA afterwards.
    mktempdir() do dir
        src = mkpath(joinpath(dir, "src")); dst = mkpath(joinpath(dir, "dst"))
        file = joinpath(src, "large.bin")
        open(file, "w") do io
            seek(io, RS.MAX_FRAME_BYTES + 7)
            write(io, UInt8(0xa5))
        end
        r = protocol_copy(src, dst; relay = true)
        @test r.result.written == 1
        @test filesize(joinpath(dst, "large.bin")) == RS.MAX_FRAME_BYTES + 8
        @test open(sha256, file) == open(sha256, joinpath(dst, "large.bin"))
    end
end
