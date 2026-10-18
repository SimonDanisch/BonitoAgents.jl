# IO-based wrappers around the librsync drive loop. Each primitive takes one
# or two input IOs and one output IO; nothing is buffered to disk by default
# (callers can pass IOBuffer/IOStream/Pipe/WebSocketIO/etc).

"""
    compute_signature(basis::IO, sig_out::IO; block_len=0, strong_len=0,
                      magic=RS_RK_BLAKE2_SIG_MAGIC, bufsize=DEFAULT_BUFSIZE)

Stream a signature of `basis` to `sig_out`. Defaults match librsync's
recommended modern settings (RabinKarp rollsum + BLAKE2 strongsum).

`basis` only needs to be read sequentially (no seek required). `sig_out`
receives the on-wire signature format documented by librsync.
"""
function compute_signature(basis::IO, sig_out::IO;
                           block_len::Integer    = 0,
                           strong_len::Integer   = 0,
                           magic::Cuint          = RS_RK_BLAKE2_SIG_MAGIC,
                           bufsize::Integer      = DEFAULT_BUFSIZE)
    job = sig_begin(; block_len, strong_len, magic)
    try
        drive!(job, basis, sig_out; bufsize)
    finally
        job_free(job)
    end
    return nothing
end

"""
    compute_delta(sig_in::IO, new_io::IO, delta_out::IO; bufsize=DEFAULT_BUFSIZE)

Two-stage operation: first load the entire signature from `sig_in` into a
heap-resident `rs_signature_t`, then stream `new_io` through `rs_delta_begin`
to produce a delta on `delta_out`.

Signatures are typically small (a few % of the basis size), so loading them
fully is fine. The new file is streamed without buffering the whole thing.
"""
function compute_delta(sig_in::IO, new_io::IO, delta_out::IO;
                       bufsize::Integer = DEFAULT_BUFSIZE)
    sig_ref = Ref{Ptr{Cvoid}}(C_NULL)
    load_job = loadsig_begin(sig_ref)
    try
        # /dev/null sink: signature loading produces no output.
        drive!(load_job, sig_in, devnull; bufsize)
    finally
        job_free(load_job)
    end
    sig_ref[] == C_NULL && error("RemoteSync: loadsig left signature NULL")
    try
        build_hash_table(sig_ref[])
        delta_job = delta_begin(sig_ref[])
        try
            drive!(delta_job, new_io, delta_out; bufsize)
        finally
            job_free(delta_job)
        end
    finally
        free_sumset(sig_ref[])
    end
    return nothing
end

"""
    apply_patch(basis::IO, delta_in::IO, new_out::IO; bufsize=DEFAULT_BUFSIZE)

Apply `delta_in` against `basis` and stream the rebuilt file to `new_out`.

`basis` MUST support `seek` (e.g. IOStream, IOBuffer). `delta_in` is read
sequentially; `new_out` receives the patched output.
"""
function apply_patch(basis::IO, delta_in::IO, new_out::IO;
                     bufsize::Integer = DEFAULT_BUFSIZE)
    BASIS_COPY_CB_PTR[] == C_NULL && _init_basis_copy_cb()
    ctx = PatchBasisCtx(basis, Vector{UInt8}(undef, bufsize))
    GC.@preserve ctx begin
        opaque = pointer_from_objref(ctx)
        job = patch_begin(BASIS_COPY_CB_PTR[], opaque)
        try
            drive!(job, delta_in, new_out; bufsize)
        catch
            # librsync reports a failed basis read as an IO error; the read's
            # own exception says what went wrong.
            ctx.failure === nothing ? rethrow() : throw(ctx.failure)
        finally
            job_free(job)
        end
    end
    return nothing
end

"""
    full_signature_bytes(path::AbstractString) → Vector{UInt8}

Convenience: compute and return the signature of an on-disk file in one call.
For files that don't exist, returns an empty vector (caller treats as "no
basis available, send the whole file as a literal delta").
"""
function full_signature_bytes(path::AbstractString)
    isfile(path) || return UInt8[]
    sig_out = IOBuffer()
    open(path, "r") do io
        compute_signature(io, sig_out)
    end
    return take!(sig_out)
end
