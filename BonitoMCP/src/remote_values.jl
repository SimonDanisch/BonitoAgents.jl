# Moving Julia values between this eval session and one on ANOTHER worker.
# Included into `BonitoMCPHelper` (helper_payload.jl), so it runs in every eval
# worker, in the USER's project: only Base and the stdlibs Malt's worker has
# already loaded (Serialization, Sockets) can be used here.
#
#     r = remote_session("Bosgame"; env_path = "/home/me/proj")
#     r[:data] = data            # `data` in the session there
#     model = r[:model]          # its `model` here
#     y = r(f, x; k = 1)         # `f(x; k = 1)` there, the value back
#
# The chat's session is the master: it opens the exchange, the other side only
# answers. The route (see mcp_relay.jl in BonitoWorker and remote_values.jl in
# BonitoAgents): this session connects to its worker's relay over loopback TCP
# with the eval token, the relay opens a channel to the server, and the server
# checks the chat's "remote julia" switch, has the chat's eval host on the other
# worker connect the session asked for (`serve_values`), and pipes the two
# channels together. From then on it is a conversation between two copies of
# this file.
#
# Values travel with `Serialization`, streamed in 1 MiB messages, so a value of
# any size fits (the websocket layers in between refuse messages over 16 MiB)
# and neither side holds a second copy of it. Serialization only works between
# identical Julia versions; the other side names its version first, and a
# mismatch is an error before anything is sent.
#
# Wire, after the server's "ok\n<worker name>": the other side says
# "hello\n<VERSION>", then answers requests one at a time:
#   "set\n<name>"  + value stream   → "ok" | "error\n<why>"
#   "get\n<name>"                   → "ok" + value stream | "error\n<why>"
#   "call"         + value stream   → "ok" + value stream | "error\n<why>"
# A value stream is binary messages, then "end" — or "abort\n<why>" when the
# sender could not serialize the value. Either way the stream is always read to
# its end, so a failed request leaves the connection usable.

const Serialization = Base.require(Base.PkgId(Base.UUID("9e88b42a-f829-5b0c-bbe9-9e923198166b"), "Serialization"))
const Sockets = Base.require(Base.PkgId(Base.UUID("6462fe0b-24de-5631-8697-dd941f90decc"), "Sockets"))

export remote_session

"""
A value exchange with a session on another worker failed, and says why: the
other side's error (with its backtrace), or a value that could not be serialized
or deserialized. The connection stays usable after one of these.
"""
struct RemoteSessionError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RemoteSessionError) = print(io, "RemoteSessionError: ", e.msg)

# ── Messages on the relay's TCP socket: [flags u8][length u32 LE][bytes] ─────

function write_msg(io::IO, msg::AbstractString)
    write_header(io, 0x01, ncodeunits(msg))
    write(io, msg)
    return nothing
end

function write_msg(io::IO, buf::Vector{UInt8}, n::Int)
    write_header(io, 0x00, n)
    GC.@preserve buf unsafe_write(io, pointer(buf), n)
    return nothing
end

function write_header(io::IO, flags::UInt8, n::Int)
    header = Vector{UInt8}(undef, 5)
    header[1] = flags
    header[2:5] .= reinterpret(UInt8, [htol(UInt32(n))])
    write(io, header)
    return nothing
end

function read_msg(io::IO)
    flags = read(io, UInt8)
    n = Int(ltoh(read(io, UInt32)))
    bytes = read(io, n)
    length(bytes) == n || throw(EOFError())
    return flags & 0x01 == 0x01 ? String(bytes) : bytes
end

# "verb\nargument" → ("verb", "argument"); the argument may hold newlines.
function request_parts(msg::String)
    occursin('\n', msg) || return msg, ""
    verb, arg = split(msg, '\n'; limit = 2)
    return String(verb), String(arg)
end

# ── Value streams ────────────────────────────────────────────────────────────

const CHUNK_BYTES = 1024 * 1024

# Serialization writes into this; every full MiB goes out as one message.
mutable struct ChunkWriter <: IO
    io::IO
    buf::Vector{UInt8}
    n::Int
end
ChunkWriter(io::IO) = ChunkWriter(io, Vector{UInt8}(undef, CHUNK_BYTES), 0)

function flush_chunk!(w::ChunkWriter)
    w.n == 0 && return nothing
    write_msg(w.io, w.buf, w.n)
    w.n = 0
    return nothing
end

function Base.unsafe_write(w::ChunkWriter, p::Ptr{UInt8}, n::UInt)
    done = 0
    while done < n
        k = min(Int(n) - done, length(w.buf) - w.n)
        GC.@preserve w unsafe_copyto!(pointer(w.buf, w.n + 1), p + done, k)
        w.n += k
        done += k
        w.n == length(w.buf) && flush_chunk!(w)
    end
    return Int(n)
end

function Base.write(w::ChunkWriter, x::UInt8)
    w.n == length(w.buf) && flush_chunk!(w)
    w.n += 1
    w.buf[w.n] = x
    return 1
end

Base.isopen(w::ChunkWriter) = isopen(w.io)

# Deserialization reads from this; it pulls the next message when a chunk runs
# out. `peer` names the other side in errors.
mutable struct ChunkReader <: IO
    io::IO
    peer::String
    buf::Vector{UInt8}
    pos::Int
    ended::Bool
end
ChunkReader(io::IO, peer::AbstractString) = ChunkReader(io, String(peer), UInt8[], 1, false)

# The next chunk into `r.buf`; false at the stream's end. An "abort" ends the
# stream too, and throws the sender's reason.
function next_chunk!(r::ChunkReader)
    r.ended && return false
    msg = read_msg(r.io)
    if msg isa Vector{UInt8}
        r.buf = msg
        r.pos = 1
        return true
    end
    r.ended = true
    msg == "end" && return false
    verb, why = request_parts(msg)
    verb == "abort" && throw(RemoteSessionError("$(r.peer) could not send the value: $(why)"))
    throw(RemoteSessionError("unexpected $(repr(first(msg, 60))) from $(r.peer) in a value stream"))
end

function Base.eof(r::ChunkReader)
    while r.pos > length(r.buf)
        next_chunk!(r) || return true
    end
    return false
end

Base.bytesavailable(r::ChunkReader) = length(r.buf) - r.pos + 1
Base.isopen(r::ChunkReader) = !r.ended

function Base.read(r::ChunkReader, ::Type{UInt8})
    eof(r) && throw(RemoteSessionError("the value stream from $(r.peer) ended early"))
    b = r.buf[r.pos]
    r.pos += 1
    return b
end

function Base.unsafe_read(r::ChunkReader, p::Ptr{UInt8}, n::UInt)
    done = 0
    while done < n
        eof(r) && throw(RemoteSessionError("the value stream from $(r.peer) ended early"))
        k = min(Int(n) - done, bytesavailable(r))
        GC.@preserve r unsafe_copyto!(p + done, pointer(r.buf, r.pos), k)
        r.pos += k
        done += k
    end
    return nothing
end

# Read the rest of the stream and drop it: the next message must be a reply.
function drain!(r::ChunkReader)
    while !r.ended
        read_msg(r.io) isa String && (r.ended = true)
    end
    return nothing
end

"""
    send_value(io, value) -> Union{Nothing,Exception}

Stream `value`, and return `nothing`, or the error that stopped serializing it
(the receiver was told with an "abort"). A broken connection throws.
"""
function send_value(io::IO, @nospecialize(value))
    w = ChunkWriter(io)
    try
        Serialization.serialize(w, value)
    catch e
        (e isa Base.IOError || e isa InterruptException) && rethrow()
        write_msg(io, "abort\n" * sprint(showerror, e))
        return e
    end
    flush_chunk!(w)
    write_msg(io, "end")
    return nothing
end

"""
    receive_value(io, peer) -> value

Read one value stream. A value that cannot be rebuilt here throws a
`RemoteSessionError` saying why, after the stream was read to its end.
"""
function receive_value(io::IO, peer::AbstractString)
    r = ChunkReader(io, peer)
    value = try
        Serialization.deserialize(r)
    catch e
        (e isa Base.IOError || e isa EOFError || e isa InterruptException) && rethrow()
        drain!(r)
        e isa RemoteSessionError && rethrow()
        throw(RemoteSessionError("the value from $(peer) cannot be rebuilt here: " *
                                 cannot_deserialize(e)))
    end
    if !eof(r)
        drain!(r)
        throw(RemoteSessionError("the value stream from $(peer) held more than one value"))
    end
    return value
end

# What a failed deserialization means for the person reading it.
cannot_deserialize(e::KeyError) = e.key isa Base.PkgId ?
    "it needs the package $(e.key.name), which is not loaded in this session; `using $(e.key.name)` first" :
    sprint(showerror, e)
cannot_deserialize(e::UndefVarError) =
    sprint(showerror, e) * " (a type or function defined in the other session only? Define it here too)"
cannot_deserialize(e) = sprint(showerror, e)

# ── Where this session reaches its worker's relay ───────────────────────────

mutable struct RemoteSession
    const worker::String       # as asked for
    const env_path::String     # "" for the other worker's temp session
    name::String               # the worker's name, as the server resolved it
    sock::Union{Nothing,Sockets.TCPSocket}
    const lock::ReentrantLock
end

# The relay this session connects through, set by the BonitoMCP process that
# started it (`set_value_relay!`), and the connections opened so far, one per
# (worker, env_path): asking again returns the same one.
mutable struct ValueRelay
    addr::String               # "127.0.0.1:<port>", "" when there is none
    token::String
    const sessions::Dict{Tuple{String,String},RemoteSession}
    const lock::ReentrantLock
end

const VALUE_RELAY = ValueRelay("", "", Dict{Tuple{String,String},RemoteSession}(), ReentrantLock())

function set_value_relay!(addr::AbstractString, token::AbstractString)
    VALUE_RELAY.addr = String(addr)
    VALUE_RELAY.token = String(token)
    return nothing
end

# A connection to the relay that the server accepted for `request`.
function relay_connect(v::ValueRelay, request::AbstractString)
    isempty(v.addr) && error(
        "this session has no route to other workers: it does not run under BonitoAgents, " *
        "or its worker is too old to relay values (update it)")
    host, port = rsplit(v.addr, ':'; limit = 2)
    sock = Sockets.connect(String(host), parse(Int, port))
    Sockets.nagle(sock, false)
    write_msg(sock, v.token * " " * request)
    verdict = read_msg(sock)
    verdict == "ok" && return sock
    close(sock)
    why = verdict isa String ? request_parts(verdict)[2] : "(an unexpected binary answer)"
    error("the worker's relay refused the connection: ", why)
end

# ── The chat's side ──────────────────────────────────────────────────────────

"""
    remote_session(worker; env_path = nothing) -> RemoteSession

The Julia session on another `worker` (its display name) that
`bt_julia_eval(worker = worker, env_path = env_path)` runs in, to move values
between it and this one. Omitting `env_path` means that worker's temp session.
It is started if it is not running yet.

    r = remote_session("Bosgame")
    r[:x] = x               # set `x` there
    y = r[:y]               # fetch its `y`
    z = r(f, a, b; k = 1)   # call `f(a, b; k = 1)` there, the value back
    z = r(:g, a)            # call its own `g`

Values travel with Serialization: both sessions need the same Julia version and
the packages that define the value's types loaded. A function passed to `r(…)`
runs there: an anonymous one is sent with its code (it cannot take keyword
arguments), a named one must exist there, and the globals either one uses are
the OTHER session's. Needs the chat's 'remote julia' switch.
"""
function remote_session(worker::AbstractString; env_path::Union{AbstractString,Nothing} = nothing)
    key = (String(worker), env_path === nothing ? "" : String(env_path))
    lock(VALUE_RELAY.lock) do
        get!(() -> RemoteSession(key[1], key[2], key[1], nothing, ReentrantLock()),
             VALUE_RELAY.sessions, key)
    end
end

Base.show(io::IO, r::RemoteSession) =
    print(io, "RemoteSession(", repr(r.name), isempty(r.env_path) ? "" : ", env_path = " * repr(r.env_path),
          r.sock === nothing ? ", not connected" : "", ")")

# `set` and `get` may be repeated on a new connection when the kept one turns out
# to have died meanwhile; a call may not, it could have run already.
Base.setindex!(r::RemoteSession, value, name::Symbol) =
    (exchange(r, "set\n" * String(name), Some(value); returns = false, retry = true); value)
Base.getindex(r::RemoteSession, name::Symbol) =
    exchange(r, "get\n" * String(name), nothing; returns = true, retry = true)
function (r::RemoteSession)(f, args...; kwargs...)
    check_sendable(f)
    return exchange(r, "call", Some((f, args, values(kwargs))); returns = true, retry = false)
end

# An anonymous function travels with its code, but not one that takes keyword
# arguments: those compile to a second, hidden function that Serialization does
# not send, and the other side fails on it (checked between two processes of
# one machine as much as between machines). Which functions travel with their
# code is Serialization's own rule (`should_send_whole_type`): anonymous
# functions and closures defined in Main; a named function or a callable object
# goes as a reference, keywords and all.
function check_sendable(f)
    t = typeof(f)
    (t isa DataType && Serialization.should_send_whole_type(Serialization.Serializer(IOBuffer()), t)) ||
        return nothing
    any(m -> !isempty(Base.kwarg_decl(m)), methods(f)) || return nothing
    throw(RemoteSessionError("an anonymous function with keyword arguments cannot be sent to " *
                             "another session: give it none (pass `r(f, x; k = 1)` to a named " *
                             "function instead), or define it there and call it by name, `r(:name, x)`"))
end

function Base.close(r::RemoteSession)
    lock(r.lock) do
        drop!(r)
    end
    lock(VALUE_RELAY.lock) do
        get(VALUE_RELAY.sessions, (r.worker, r.env_path), nothing) === r &&
            delete!(VALUE_RELAY.sessions, (r.worker, r.env_path))
    end
    return nothing
end

function drop!(r::RemoteSession)
    r.sock === nothing || close(r.sock)
    r.sock = nothing
    return nothing
end

# The connection, opened (and the other side's Julia version checked) on first use
# and again after one was lost.
function connection!(r::RemoteSession)
    r.sock !== nothing && isopen(r.sock) && return r.sock
    sock = relay_connect(VALUE_RELAY, "values")
    try
        write_msg(sock, "open\n" * r.worker * "\n" * r.env_path)
        verb, arg = request_parts(read_msg(sock)::String)
        verb == "ok" || throw(RemoteSessionError(arg))
        r.name = arg
        verb, arg = request_parts(read_msg(sock)::String)
        verb == "hello" || error("the session on $(r.name) did not say hello: $(repr(verb))")
        theirs = VersionNumber(arg)
        theirs == VERSION || throw(RemoteSessionError(
            "Julia $(VERSION) here, $(theirs) on $(r.name): values move with Serialization, " *
            "which only works between identical Julia versions. Start the session there with " *
            "this version (bt_julia_restart, then bt_julia_eval(worker = $(repr(r.name)), " *
            "julia_cmd = \"julia +$(VERSION)\")) or this one with theirs"))
    catch
        close(sock)
        rethrow()
    end
    r.sock = sock
    return sock
end

"""
    exchange(r, head, payload; returns, retry)

One request and its reply, on a connection that is opened if needed. A kept
connection may have died unnoticed (the other session restarted): with `retry`
the request is sent once more on a new one.
"""
function exchange(r::RemoteSession, head::String, payload::Union{Nothing,Some}; returns::Bool, retry::Bool)
    lock(r.lock) do
        attempts = retry && r.sock !== nothing ? 2 : 1
        for attempt in 1:attempts
            try
                return exchange_once(r, head, payload, returns)
            catch e
                (e isa EOFError || e isa Base.IOError) || rethrow()
                attempt == attempts &&
                    throw(RemoteSessionError("lost the connection to the session on $(r.name) " *
                                             "(it restarted, or the server went away): try again"))
            end
        end
    end
end

# A `RemoteSessionError` leaves the connection in step (the other side read and
# answered everything); anything else may have cut a message in half, so the
# connection is dropped and the next request opens a new one.
function exchange_once(r::RemoteSession, head::String, payload::Union{Nothing,Some}, returns::Bool)
    sock = connection!(r)
    try
        write_msg(sock, head)
        unsent = payload === nothing ? nothing : send_value(sock, something(payload))
        verb, why = request_parts(read_msg(sock)::String)
        unsent === nothing ||
            throw(RemoteSessionError("could not send the value: " * sprint(showerror, unsent)))
        verb == "error" && throw(RemoteSessionError("on $(r.name): " * why))
        verb == "ok" || error("unexpected reply $(repr(verb)) from $(r.name)")
        return returns ? receive_value(sock, r.name) : nothing
    catch e
        e isa RemoteSessionError || drop!(r)
        rethrow()
    end
end

# ── The other side ──────────────────────────────────────────────────────────

"""
    serve_values(pair)

Answer a chat session's value requests from this session: connect to the relay
for the exchange `pair` (the server named it to the eval host that calls this),
say which Julia this is, and serve until the chat's side hangs up.
"""
function serve_values(pair::AbstractString)
    sock = relay_connect(VALUE_RELAY, "values " * pair)
    try
        write_msg(sock, "hello\n" * string(VERSION))
    catch
        close(sock)
        rethrow()
    end
    # Off the thread Malt answers on: a long `call` must not stall the session.
    Base.errormonitor(Threads.@spawn serve_value_requests(sock))
    return nothing
end

function serve_value_requests(sock::Sockets.TCPSocket)
    try
        while !eof(sock)
            # The latest world: the session defines functions and types while
            # this loop runs, and a request may use them.
            Base.invokelatest(answer_value_request, sock, read_msg(sock))
        end
    catch e
        # The chat's side hung up mid-request (its eval was interrupted, or
        # it restarted): nothing is waiting for an answer any more.
        (e isa Base.IOError || e isa EOFError) || rethrow()
    finally
        close(sock)
    end
    return nothing
end

function answer_value_request(sock::Sockets.TCPSocket, msg)
    msg isa String || error("value exchange: a request must be text")
    verb, arg = request_parts(msg)
    result = try
        value_request(Val(Symbol(verb)), sock, arg)
    catch e
        (e isa Base.IOError || e isa EOFError) && rethrow()
        write_msg(sock, "error\n" * request_error_text(e, catch_backtrace()))
        return nothing
    end
    write_msg(sock, "ok")
    # An "abort" inside tells the chat's side why the value did not come.
    result === nothing || send_value(sock, something(result))
    return nothing
end

request_error_text(e::RemoteSessionError, bt) = e.msg
request_error_text(e, bt) = trim_backtrace(sprint(showerror, e, bt))

function value_request(::Val{:set}, sock, name::AbstractString)
    value = receive_value(sock, "the chat's session")      # all of it, whatever follows
    Base.isidentifier(name) || error("$(repr(name)) is not a name a value can be stored under")
    Core.eval(Main, Expr(:(=), Symbol(name), QuoteNode(value)))
    return nothing
end

function value_request(::Val{:get}, sock, name::AbstractString)
    sym = Symbol(name)
    isdefined(Main, sym) || throw(UndefVarError(sym, Main))
    return Some(getglobal(Main, sym))
end

function value_request(::Val{:call}, sock, ::AbstractString)
    f, args, kwargs = receive_value(sock, "the chat's session")
    # Deserializing an anonymous function defined its method just now.
    return Some(Base.invokelatest(callable(f), args...; kwargs...))
end

value_request(::Val{V}, sock, ::AbstractString) where {V} = error("unknown value request '$(V)'")

# `r(:name, …)` calls the function this session calls `name`.
callable(f::Symbol) = getglobal(Main, f)
callable(f) = f
