# Thin ccall wrapper around librsync's streaming API (rs_job_iter +
# rs_buffers_t). All three primitives — signature, delta, patch — share the
# same drive loop: feed bytes from an input IO into librsync, drain output
# bytes into an output IO, until librsync returns RS_DONE.
#
# This file talks ONLY to librsync. The public sync API lives in sync.jl and
# composes these primitives; the WS transport lives in websocketio.jl.

using librsync_jll: librsync

# ── librsync constants ─────────────────────────────────────────────────────
# Result codes (rs_result enum). We only branch on these three.
const RS_DONE          = Cint(0)
const RS_BLOCKED       = Cint(1)
# Anything ≥ 100 is an error. We surface the message via rs_strerror().

# Signature magic numbers (rs_magic_number enum). RK_BLAKE2 is the modern
# recommended default — fast rollsum + safe hash.
const RS_RK_BLAKE2_SIG_MAGIC = Cuint(0x72730147)

# Default IO buffer for streaming. Larger buffers reduce librsync state-machine
# overhead; 64 KiB is a good middle ground (small enough to bound RAM usage
# during big-file transfers, big enough to amortise ccall cost).
const DEFAULT_BUFSIZE = 64 * 1024

# ── rs_buffers_t mirror ────────────────────────────────────────────────────
# Layout matches librsync.h's rs_buffers_s exactly:
#   char *next_in;  size_t avail_in;  int eof_in;
#   char *next_out; size_t avail_out;
mutable struct RsBuffers
    next_in   :: Ptr{UInt8}
    avail_in  :: Csize_t
    eof_in    :: Cint
    next_out  :: Ptr{UInt8}
    avail_out :: Csize_t
end
RsBuffers() = RsBuffers(C_NULL, 0, 0, C_NULL, 0)

# ── Errors ─────────────────────────────────────────────────────────────────
struct LibrsyncError <: Exception
    code :: Cint
    op   :: Symbol
end

function Base.showerror(io::IO, e::LibrsyncError)
    msg = unsafe_string(@ccall librsync.rs_strerror(e.code::Cint)::Cstring)
    print(io, "RemoteSync.LibrsyncError(", e.op, "): ", msg, " (code=", e.code, ")")
end

check_result(r::Cint, op::Symbol) =
    r >= Cint(100) ? throw(LibrsyncError(r, op)) : r

# ── Job lifecycle helpers ──────────────────────────────────────────────────
# Start a signature job. block_len/strong_len of 0 mean "library default".
function sig_begin(; block_len::Integer = 0, strong_len::Integer = 0,
                     magic::Cuint = RS_RK_BLAKE2_SIG_MAGIC)
    job = @ccall librsync.rs_sig_begin(
        Csize_t(block_len)::Csize_t,
        Csize_t(strong_len)::Csize_t,
        magic::Cuint,
    )::Ptr{Cvoid}
    job == C_NULL && error("rs_sig_begin returned NULL")
    return job
end

# Start loading a signature into memory. Output is a heap-allocated
# rs_signature_t pointer; caller stores it in `sig_ref[]` after job completes.
function loadsig_begin(sig_ref::Base.RefValue{Ptr{Cvoid}})
    sig_ref[] = C_NULL
    job = @ccall librsync.rs_loadsig_begin(sig_ref::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
    job == C_NULL && error("rs_loadsig_begin returned NULL")
    return job
end

# After loading, signature must be hashed before delta_begin can use it.
function build_hash_table(sig::Ptr{Cvoid})
    r = @ccall librsync.rs_build_hash_table(sig::Ptr{Cvoid})::Cint
    return check_result(r, :build_hash_table)
end

free_sumset(sig::Ptr{Cvoid}) =
    sig == C_NULL ? nothing :
        (@ccall librsync.rs_free_sumset(sig::Ptr{Cvoid})::Cvoid)

# Start a delta job. Takes a loaded+hashed signature.
function delta_begin(sig::Ptr{Cvoid})
    job = @ccall librsync.rs_delta_begin(sig::Ptr{Cvoid})::Ptr{Cvoid}
    job == C_NULL && error("rs_delta_begin returned NULL")
    return job
end

# Start a patch job. The copy_cb fetches bytes from the basis at arbitrary
# positions — see basis_copy_cb below.
function patch_begin(copy_cb::Ptr{Cvoid}, copy_arg::Ptr{Cvoid})
    job = @ccall librsync.rs_patch_begin(
        copy_cb::Ptr{Cvoid},
        copy_arg::Ptr{Cvoid},
    )::Ptr{Cvoid}
    job == C_NULL && error("rs_patch_begin returned NULL")
    return job
end

job_free(job::Ptr{Cvoid}) =
    job == C_NULL ? nothing :
        (@ccall librsync.rs_job_free(job::Ptr{Cvoid})::Cint)

# Single rs_job_iter step. Mutates `bufs` in place.
function job_iter(job::Ptr{Cvoid}, bufs::RsBuffers)
    r = @ccall librsync.rs_job_iter(job::Ptr{Cvoid}, bufs::Ref{RsBuffers})::Cint
    return r
end

# ── Drive loop ─────────────────────────────────────────────────────────────
# Pump bytes from `in_io` through `job` to `out_io`. Returns when the job
# reports RS_DONE. Throws LibrsyncError on any code ≥ 100.
#
# The loop maintains two GC-rooted Vector{UInt8} buffers and two integers
# tracking how much of each is "live" (already-read input not yet consumed,
# already-written output not yet drained). On each iteration:
#   - if librsync wants more input and we have none, refill from `in_io`
#   - call rs_job_iter, which may consume some/all input + produce output
#   - drain produced output to `out_io`
function drive!(job::Ptr{Cvoid}, in_io::Union{IO,Nothing}, out_io::IO;
                bufsize::Integer = DEFAULT_BUFSIZE)
    in_buf  = Vector{UInt8}(undef, bufsize)
    out_buf = Vector{UInt8}(undef, bufsize)
    bufs    = RsBuffers()

    in_off    = 0          # next byte of in_buf to feed
    in_have   = 0          # bytes available in in_buf starting at in_off+1
    eof_seen  = in_io === nothing

    GC.@preserve in_buf out_buf begin
        while true
            # Refill input when empty and we haven't hit EOF.
            if in_have == 0 && !eof_seen
                in_off = 0
                if in_io !== nothing && !eof(in_io)
                    in_have = readbytes!(in_io, in_buf, bufsize)
                end
                eof_seen = in_io === nothing || eof(in_io)
            end

            bufs.next_in   = pointer(in_buf, in_off + 1)
            bufs.avail_in  = Csize_t(in_have)
            bufs.eof_in    = eof_seen ? Cint(1) : Cint(0)
            bufs.next_out  = pointer(out_buf)
            bufs.avail_out = Csize_t(bufsize)

            r = job_iter(job, bufs)
            check_result(r, :iter)

            # Bytes consumed: original in_have minus what's left in bufs.avail_in.
            consumed = in_have - Int(bufs.avail_in)
            in_have -= consumed
            in_off  += consumed

            # Bytes produced: bufsize minus remaining avail_out.
            produced = bufsize - Int(bufs.avail_out)
            produced > 0 && unsafe_write(out_io, pointer(out_buf), produced)

            r == RS_DONE && break
            # If we made no forward progress at all, librsync wants more
            # input we can't supply (truncation) — bail out cleanly.
            r == RS_BLOCKED && consumed == 0 && produced == 0 && eof_seen &&
                error("RemoteSync: librsync stalled with eof_in set")
        end
    end
    return nothing
end

# ── Patch basis callback ───────────────────────────────────────────────────
# librsync requires random access to the basis when applying a patch. We back
# this with a Julia object that supports `seek` + `read` (typically IOStream
# or IOBuffer); the C callback marshals through a per-job heap structure that
# carries the IO and a reusable buffer.
mutable struct PatchBasisCtx
    io  :: IO
    buf :: Vector{UInt8}
end

# C signature: rs_result rs_copy_cb(void *opaque, rs_long_t pos, size_t *len, void **buf)
function _basis_copy_cb_impl(opaque::Ptr{Cvoid}, pos::Clonglong,
                              len_ptr::Ptr{Csize_t}, buf_ptr::Ptr{Ptr{UInt8}})
    ctx = unsafe_pointer_to_objref(opaque)::PatchBasisCtx
    requested = Int(unsafe_load(len_ptr))
    try
        seek(ctx.io, pos)
        # librsync permits a short callback result and asks again for the rest.
        # A COPY instruction may span the whole basis; keep its buffer bounded.
        n = readbytes!(ctx.io, ctx.buf, min(requested, length(ctx.buf)))
        unsafe_store!(len_ptr, Csize_t(n))
        unsafe_store!(buf_ptr, pointer(ctx.buf))
        return RS_DONE
    catch
        # Surface any error as RS_IO_ERROR; details lost on the C side.
        unsafe_store!(len_ptr, Csize_t(0))
        return Cint(100)
    end
end

const BASIS_COPY_CB_PTR = Ref{Ptr{Cvoid}}(C_NULL)

# Register the cfunction once at module init — librsync only needs one
# per-process function pointer, parameterised by the opaque context.
function _init_basis_copy_cb()
    BASIS_COPY_CB_PTR[] = @cfunction(
        _basis_copy_cb_impl,
        Cint,
        (Ptr{Cvoid}, Clonglong, Ptr{Csize_t}, Ptr{Ptr{UInt8}}),
    )
    return nothing
end
