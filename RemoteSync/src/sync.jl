# Directory-level sync orchestrating the wire protocol from wire.jl with the
# librsync primitives from primitives.jl. One side calls `send_directory`,
# the other calls `receive_directory`. Both sides share the same `transport`
# (a single bidirectional IO; can be a Pipe, a WebSocketIO, an IOBuffer pair
# bridged with a background task, anything).

# No directory is excluded any more. `.bonitoAgents/` used to live inside
# each project tree (chat.md + tools/) and had to be skipped because
# workers don't write one — mirror-sync would otherwise wipe the server's
# chat history when pulling. The chat storage now lives under
# `<state_dir>/chats/<project_id>/` (outside any project tree), so the
# special case is no longer needed. `.git/` is included for the same
# reason as everything else: dev on a synced project needs full history.
const SNAPSHOT_IGNORE_DIRS = Set{String}()

# ── Path-traversal guard (R1/R7) ────────────────────────────────────────────
# A `rel` path arrives over the wire from the PEER's manifest/plan and is then
# fed to `joinpath(root, rel)` on BOTH sides (receiver writes, sender reads). A
# hostile or buggy peer can send an absolute path (`joinpath(root, "/etc/x")`
# == "/etc/x") or a `..`-escaping relative path and walk straight out of the
# sync root — arbitrary file write on the receiver, arbitrary file read /
# exfiltration on the sender. Every wire-supplied `rel` MUST pass through here
# before it touches the filesystem.
#
# `safe_rel(root, rel)` returns the normalized rel string when it stays inside
# `root`, or `nothing` when it would escape (absolute, `..`-escaping, or empty).
# Callers reject the entry on `nothing`. Comparison is done on normalized
# absolute paths so `a/../b`, trailing slashes, and `.` segments all collapse
# the same way (this also canonicalizes for the delete/membership pass, R7).
function safe_rel(root::AbstractString, rel::AbstractString)
    isempty(rel) && return nothing
    # Reject absolute paths outright (covers POSIX "/x" and Windows "C:\x" /
    # "\x"); `joinpath` would discard `root` entirely for these.
    (startswith(rel, '/') || startswith(rel, '\\')) && return nothing
    occursin(r"^[A-Za-z]:", rel) && return nothing
    # Normalize and require the result to live under root.
    rootabs = normpath(abspath(root))
    target  = normpath(joinpath(rootabs, rel))
    prefix  = endswith(rootabs, Base.Filesystem.path_separator) ?
              rootabs : rootabs * Base.Filesystem.path_separator
    (target == rootabs || startswith(target, prefix)) || return nothing
    # The normalized rel, in forward-slash wire form, relative to root.
    norm = relpath(target, rootabs)
    Sys.iswindows() && (norm = replace(norm, '\\' => '/'))
    return norm
end

"""
    walk_directory(root) → Vector{ManifestEntry}

Walk `root` and produce a stable, sorted manifest. No directories are
excluded; the project tree mirrors verbatim. Paths in the manifest use
forward slashes regardless of the host OS so the wire protocol is portable.
"""
function walk_directory(root::AbstractString)
    out = ManifestEntry[]
    isdir(root) || return out
    for (dir, dirs, files) in walkdir(root; topdown = true)
        filter!(d -> !(d in SNAPSHOT_IGNORE_DIRS), dirs)
        for f in files
            full = joinpath(dir, f)
            isfile(full) || continue
            rel = relpath(full, root)
            Sys.iswindows() && (rel = replace(rel, '\\' => '/'))
            st  = stat(full)
            push!(out, ManifestEntry(String(rel), UInt64(st.size), Float64(st.mtime)))
        end
    end
    sort!(out; by = e -> e.rel)
    return out
end

# ── Receiver helpers ───────────────────────────────────────────────────────
# Decide what to do with each entry the sender announced + which local files
# should be deleted. The plan is what we ask the sender to send back to us.
function build_plan(local_root::AbstractString,
                    remote_manifest::Vector{ManifestEntry};
                    quick_check::Bool = true)
    plan = PlanEntry[]
    # Canonicalize every remote rel up front and drop anything that escapes the
    # root (R1/R7). The membership set used by the delete pass is built from the
    # SAME canonical forms so a normalization mismatch can't delete a valid
    # local file.
    safe_remote = Tuple{ManifestEntry,String}[]
    for e in remote_manifest
        sr = safe_rel(local_root, e.rel)
        if sr === nothing
            @warn "RemoteSync: rejecting unsafe manifest path" rel=e.rel
            continue
        end
        push!(safe_remote, (e, sr))
    end
    remote_set = Set(sr for (_, sr) in safe_remote)

    for (e, rel) in safe_remote
        local_path = joinpath(local_root, rel)
        if !isfile(local_path)
            push!(plan, PlanEntry(rel, ACTION_FULL, UInt8[]))
            continue
        end
        st = stat(local_path)
        # Same heuristic as rsync's --size-only-with-1s-modify-window: matching
        # size + mtime (within ~1ms) is treated as identical. The 1ms tolerance
        # absorbs Float64 precision loss in the stat→wire→utimes→stat round-trip
        # (ns precision can't survive Float64 at modern Unix epoch values).
        #
        # `quick_check = false` disables the skip entirely: like rsync's
        # --checksum, every shared file goes through the signature/delta
        # exchange (cheap for identical content — the delta degenerates to
        # copy ops). Callers doing a user-confirmed DIRECTIONAL OVERWRITE
        # use this, because the heuristic has a real false-negative: two
        # same-length variants written within the same clock tick (e.g.
        # "FROM A\n" vs "FROM B\n") match size+mtime and would silently
        # keep the stale side.
        if quick_check &&
           UInt64(st.size) == e.size && abs(Float64(st.mtime) - e.mtime) < 0.001
            push!(plan, PlanEntry(rel, ACTION_SKIP, UInt8[]))
            continue
        end
        sig = full_signature_bytes(local_path)
        push!(plan, PlanEntry(rel, ACTION_PATCH, sig))
    end

    # Anything local but not in remote → delete.
    for (dir, dirs, files) in walkdir(local_root; topdown = true)
        filter!(d -> !(d in SNAPSHOT_IGNORE_DIRS), dirs)
        for f in files
            full = joinpath(dir, f)
            rel = relpath(full, local_root)
            Sys.iswindows() && (rel = replace(rel, '\\' => '/'))
            in(String(rel), remote_set) || push!(plan,
                PlanEntry(String(rel), ACTION_DELETE, UInt8[]))
        end
    end
    return plan
end

# ── Public: sender side ────────────────────────────────────────────────────
"""
    send_directory(root, transport::IO; on_progress = nothing)

Send `root` over `transport`. The receiver on the other end of `transport`
must be running `receive_directory`. Returns when the transfer completes.

`on_progress` is an optional callback `(stage::Symbol, info::NamedTuple) -> Any`
invoked at: `:walk_done`, `:plan_received`, `:file_start`, `:file_done`,
`:transfer_done`. Useful for driving a UI progress bar without polling.
"""
function send_directory(root::AbstractString, transport::IO;
                        on_progress = nothing)
    notify_progress(on_progress, :walk_start, (root = root,))
    manifest = walk_directory(root)
    notify_progress(on_progress, :walk_done, (count = length(manifest),))

    write_frame(transport, TAG_MANIFEST, encode_manifest(manifest))

    tag, payload = read_frame(transport)
    tag == TAG_PLAN || error("RemoteSync sender: expected PLAN, got tag $(tag)")
    plan = decode_plan(payload)
    work = filter(p -> p.action == ACTION_FULL || p.action == ACTION_PATCH, plan)
    notify_progress(on_progress, :plan_received,
                    (planned = length(plan), work = length(work)))

    for (i, p) in pairs(work)
        # The plan came from the REMOTE receiver; validate its rel before we
        # open any local file (R1) — otherwise a malicious plan could make us
        # read `/etc/shadow` and stream it back.
        sr = safe_rel(root, p.rel)
        sr === nothing &&
            error("RemoteSync sender: refusing unsafe plan path: $(repr(p.rel))")
        local_path = joinpath(root, sr)
        notify_progress(on_progress, :file_start,
                        (rel = p.rel, idx = i, total = length(work),
                         action = p.action == ACTION_FULL ? :full : :patch))

        delta_buf = IOBuffer()
        if p.action == ACTION_FULL
            # No basis on receiver — emit a delta against an empty signature
            # so the receiver can use the same apply_patch path uniformly.
            empty_sig = IOBuffer()
            empty_basis = IOBuffer(UInt8[])
            compute_signature(empty_basis, empty_sig)
            seekstart(empty_sig)
            open(local_path, "r") do io
                compute_delta(empty_sig, io, delta_buf)
            end
        else
            sig_in = IOBuffer(p.sig)
            open(local_path, "r") do io
                compute_delta(sig_in, io, delta_buf)
            end
        end

        write_frame(transport, TAG_DELTA, encode_delta_frame(p.rel, take!(delta_buf)))

        # Wait for the receiver's OK so we keep things synchronous + bound the
        # in-flight queue (otherwise a slow receiver would balloon memory).
        ack_tag, _ = read_frame(transport)
        ack_tag == TAG_OK || error("RemoteSync sender: expected OK after $(p.rel), got $(ack_tag)")
        notify_progress(on_progress, :file_done, (rel = p.rel, idx = i, total = length(work)))
    end

    write_frame(transport, TAG_DONE)
    notify_progress(on_progress, :transfer_done, (files = length(manifest),))
    return nothing
end

# ── Public: receiver side ──────────────────────────────────────────────────
"""
    receive_directory(root, transport::IO; on_progress = nothing,
                      quick_check = true) → Stats

Receive into `root` over `transport`. Atomic per-file writes (`<rel>.partial`
then `mv`) so a transport crash mid-file leaves the prior version intact.

`quick_check = false` disables the size+mtime skip heuristic (rsync
`--checksum` semantics) — every shared file is verified through the
signature/delta exchange. Use for user-confirmed directional overwrites
where correctness beats the round-trips saved by skipping.

`delete_extraneous = true` turns the transfer into a mirror: files under `root`
that the sender's manifest does not name are deleted once the transfer is
complete. OFF by default, and meant for a receiver that owns `root` (the
BonitoAgents server pulling a project into its own mirror). A destination on a
user's machine is never ours to empty: a project move once pushed a never-synced
(empty) server mirror to a worker with mirror semantics and deleted every file of
the live project there (2026-09-15). Even when on, an EMPTY manifest never
drives deletions: mirroring nothing onto a populated folder is refused before a
single file goes.

Returns a NamedTuple `(written, deleted, skipped)` with file counts.
"""
function receive_directory(root::AbstractString, transport::IO;
                           on_progress = nothing,
                           quick_check::Bool = true,
                           delete_extraneous::Bool = false)
    mkpath(root)
    notify_progress(on_progress, :wait_manifest, NamedTuple())

    tag, payload = read_frame(transport)
    tag == TAG_MANIFEST ||
        error("RemoteSync receiver: expected MANIFEST, got tag $(tag)")
    manifest = decode_manifest(payload)
    notify_progress(on_progress, :manifest_received, (count = length(manifest),))

    plan = build_plan(root, manifest; quick_check)
    if delete_extraneous && isempty(manifest)
        doomed = count(p -> p.action == ACTION_DELETE, plan)
        doomed == 0 || error("RemoteSync receiver: refusing to delete $(doomed) local file(s) " *
                             "to mirror an EMPTY source into $(root)")
    end
    write_frame(transport, TAG_PLAN, encode_plan(plan))

    skipped = count(p -> p.action == ACTION_SKIP, plan)
    written = 0
    deleted = 0

    expected = filter(p -> p.action == ACTION_FULL || p.action == ACTION_PATCH, plan)
    # Key by the canonical rel (the form `build_plan` puts into the plan, and
    # thus the form the DELTA frames echo back) so the mtime-touch lookup below
    # actually hits (R7).
    by_rel = Dict{String,ManifestEntry}()
    for e in manifest
        sr = safe_rel(root, e.rel)
        sr === nothing || (by_rel[sr] = e)
    end
    for (i, p) in pairs(expected)
        tag2, pl = read_frame(transport)
        tag2 == TAG_DELTA ||
            error("RemoteSync receiver: expected DELTA, got tag $(tag2)")
        rel, delta = decode_delta_frame(pl)
        rel == p.rel || error("RemoteSync receiver: delta order mismatch ($(rel) vs $(p.rel))")
        # `p.rel` was produced by our own `build_plan` (already canonical+safe),
        # and `rel` just matched it — but re-validate defensively before any
        # write so a future plan-builder change can't silently reopen R1.
        srel = safe_rel(root, rel)
        srel === nothing &&
            error("RemoteSync receiver: refusing unsafe delta path: $(repr(rel))")

        notify_progress(on_progress, :apply_start,
                        (rel = rel, idx = i, total = length(expected)))

        dst = joinpath(root, srel)
        mkpath(dirname(dst))
        partial = dst * ".partial"
        try
            open(partial, "w") do out_io
                if p.action == ACTION_FULL
                    # Need a seekable basis even though it's empty.
                    apply_patch(IOBuffer(UInt8[]), IOBuffer(delta), out_io)
                else
                    open(dst, "r") do basis_io
                        apply_patch(basis_io, IOBuffer(delta), out_io)
                    end
                end
            end
            mv(partial, dst; force = true)
        catch
            isfile(partial) && rm(partial; force = true)
            rethrow()
        end

        # Set mtime to the source's so the next-run shortcut (size+mtime ⇒ skip)
        # actually fires.
        if haskey(by_rel, srel)
            try
                touch_mtime(dst, by_rel[srel].mtime)
            catch
                # touch_mtime is a best-effort optimisation; failing it
                # only costs us an extra rsync round-trip next time.
            end
        end

        written += 1
        write_frame(transport, TAG_OK)
        notify_progress(on_progress, :apply_done,
                        (rel = rel, idx = i, total = length(expected)))
    end

    # Wait for sender's DONE before applying deletes so a sender crash mid-stream
    # doesn't leave us with a destructive delete pass executed against a partial
    # transfer.
    tag3, _ = read_frame(transport)
    tag3 == TAG_DONE ||
        error("RemoteSync receiver: expected DONE, got tag $(tag3)")

    for p in plan
        p.action == ACTION_DELETE || continue
        delete_extraneous || continue
        # DELETE entries are produced by our own `build_plan` from a local
        # walkdir, so they're already canonical — but re-validate before `rm`
        # so an unsafe path can NEVER drive a delete outside root (R1/R7).
        srel = safe_rel(root, p.rel)
        srel === nothing && (@warn "RemoteSync: skipping unsafe delete path" rel=p.rel; continue)
        full = joinpath(root, srel)
        try
            isfile(full) && (rm(full); deleted += 1)
        catch e
            @warn "RemoteSync receiver: failed to delete" path=full exception=e
        end
    end

    notify_progress(on_progress, :transfer_done,
                    (written = written, deleted = deleted, skipped = skipped))
    return (written = written, deleted = deleted, skipped = skipped)
end

# ── Single-file streaming ──────────────────────────────────────────────────
# Independent of the manifest-based directory protocol: useful when the caller
# already knows the exact file it wants. Memory-bounded by FILE_CHUNK_BYTES
# regardless of file size, so the only ceiling is disk space.
const FILE_CHUNK_BYTES = 1 * 1024 * 1024      # 1 MiB per WS frame

"""
    send_file(path, transport::IO; on_progress = nothing) → bytes_sent

Stream the contents of `path` over `transport` in `FILE_CHUNK_BYTES` chunks.
The receiver on the other end must be running `receive_file`.

`on_progress` callback stages: `:file_header` `(size, mtime)`,
`:file_chunk` `(sent, total)`, `:file_done` `(size,)`.
"""
function send_file(path::AbstractString, transport::IO;
                    on_progress = nothing)
    isfile(path) || error("send_file: not a file: $path")
    st   = stat(path)
    size = UInt64(st.size)
    hdr  = IOBuffer()
    write(hdr, htol(size))
    write(hdr, htol(reinterpret(UInt64, Float64(st.mtime))))
    write_frame(transport, TAG_FILE_HEADER, take!(hdr))
    notify_progress(on_progress, :file_header, (size = size, mtime = Float64(st.mtime)))

    sent = UInt64(0)
    buf  = Vector{UInt8}(undef, FILE_CHUNK_BYTES)
    open(path, "r") do io
        while !eof(io)
            n = readbytes!(io, buf, FILE_CHUNK_BYTES)
            n > 0 && write_frame(transport, TAG_FILE_CHUNK, view(buf, 1:n))
            sent += UInt64(n)
            notify_progress(on_progress, :file_chunk, (sent = sent, total = size))
        end
    end
    write_frame(transport, TAG_FILE_END)
    notify_progress(on_progress, :file_done, (size = sent,))
    return sent
end

"""
    receive_file(dst, transport::IO; on_progress = nothing)
        → (size::UInt64, mtime::Float64)

Receive a streamed file into `dst`. Atomic write: streamed into `<dst>.partial`
then renamed, so a transport crash mid-file leaves any prior version intact.
"""
function receive_file(dst::AbstractString, transport::IO;
                       on_progress = nothing)
    tag, payload = read_frame(transport)
    tag == TAG_FILE_HEADER ||
        error("receive_file: expected FILE_HEADER, got tag $(tag)")
    io_hdr = IOBuffer(payload)
    total  = ltoh(read(io_hdr, UInt64))
    mtime  = reinterpret(Float64, ltoh(read(io_hdr, UInt64)))
    notify_progress(on_progress, :file_header, (size = total, mtime = mtime))

    mkpath(dirname(dst))
    partial  = dst * ".partial"
    received = UInt64(0)
    try
        open(partial, "w") do out
            while true
                tag2, pl = read_frame(transport)
                if tag2 == TAG_FILE_END
                    break
                elseif tag2 == TAG_FILE_CHUNK
                    write(out, pl)
                    received += UInt64(length(pl))
                    notify_progress(on_progress, :file_chunk,
                                    (received = received, total = total))
                else
                    error("receive_file: unexpected tag $(tag2)")
                end
            end
        end
        mv(partial, dst; force = true)
    catch
        isfile(partial) && rm(partial; force = true)
        rethrow()
    end

    try
        touch_mtime(dst, mtime)
    catch
        # best-effort; mtime mismatch only costs a directory-resync round-trip.
    end
    notify_progress(on_progress, :file_done, (size = received,))
    return (size = received, mtime = mtime)
end

# Set the mtime of `path` to `mtime_secs` (Unix epoch seconds, fractional OK).
# Direct utimes(2) ccall — sets both atime + mtime to the same value. Linux/
# macOS only; on Windows the next-run shortcut (size+mtime ⇒ skip) just won't
# fire and we'll re-compute deltas (correct, slightly slower).
function touch_mtime(path::AbstractString, mtime_secs::Float64)
    Sys.iswindows() && return nothing
    sec  = floor(Int64, mtime_secs)
    usec = floor(Int64, (mtime_secs - sec) * 1e6)
    times = Int64[sec, usec, sec, usec]
    GC.@preserve times begin
        r = ccall(:utimes, Cint, (Cstring, Ptr{Int64}), path, pointer(times))
    end
    r == 0 || Base.systemerror("utimes")
    return nothing
end

# ── Progress callback dispatch ─────────────────────────────────────────────
# `nothing` is used as the no-op callback; anything else is invoked. Argument
# types are fully constrained so dispatch is unambiguous regardless of the
# concrete NamedTuple type passed for `info`.
notify_progress(::Nothing, ::Symbol, ::Any) = nothing
function notify_progress(cb, stage::Symbol, info)
    try
        cb(stage, info)
    catch e
        @warn "RemoteSync: progress callback threw" stage exception=e
    end
    return nothing
end
