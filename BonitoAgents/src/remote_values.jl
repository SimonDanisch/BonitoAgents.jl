# ── Julia values between a chat's session and one on another worker ─────────
# `remote_session("MacBook")` in a chat's eval session (BonitoMCP's
# remote_values.jl has the API and the wire). That session opens a "values"
# channel through its worker's relay and names the worker and env it wants;
# this file checks the chat's "remote julia" switch, has the chat's eval host on
# that worker connect the session asked for (host op "values", with a pair
# token only this exchange knows), and pipes the two channels together until
# either side hangs up.
#
# The server reads the "open" line and nothing else. The values are
# Serialization streams, and deserializing one runs code: never here.

# The host starts the session first if it is not running (a julia start).
const VALUE_SESSION_TIMEOUT_S = 180.0
# After the host said the session connected, its channel is here or on its way.
const VALUE_PEER_TIMEOUT_S = 30.0

"""
    serve_values_channel(state, ch, project_id, host_worker, header)

A "values" channel a relay opened: the chat's own session asking for a session
on another worker (`host_worker == ""`), or that session answering, named by
the pair token the server handed its eval host.
"""
function serve_values_channel(state::ServerState, ch::WorkerLink.LinkChannel, project_id::String,
                              host_worker::String, header::AbstractDict)
    pair = String(get(header, "pair", ""))
    if isempty(host_worker)
        isempty(pair) || return WorkerLink.abort(ch, "a chat's own session does not answer value exchanges")
        accept_channel(ch)
        return open_value_exchange(state, ch, project_id)
    end
    vp = lock(() -> get(state.value_pairs, pair, nothing), state.lock)
    if vp === nothing || vp.project_id != project_id || vp.worker_id != host_worker
        return WorkerLink.abort(ch, "no value exchange is waiting for this session")
    end
    accept_channel(ch)
    try
        put!(vp.peer, ch)
    catch e
        e isa InvalidStateException || rethrow()      # given up meanwhile
        WorkerLink.abort(ch, "the value exchange was given up")
    end
    return nothing
end

# "open\n<worker>\n<env_path>" from the chat's session: connect it, or tell it why not.
function open_value_exchange(state::ServerState, ch::WorkerLink.LinkChannel, project_id::String)
    msg = HTTP.WebSockets.receive(ch)
    parts = msg isa String ? split(msg, '\n'; limit = 3) : SubString{String}[]
    if length(parts) != 3 || parts[1] != "open"
        return WorkerLink.abort(ch, "a value exchange starts with 'open'")
    end
    worker, env_path = String(parts[2]), String(parts[3])
    peer, name = try
        p = remote_eval_project(state, project_id)
        w = remote_target(state, p, Dict{String,Any}("worker" => worker))
        (connect_value_peer(state, p, w, env_path), w.name)
    catch e
        e isa InterruptException && rethrow()
        why = sprint(showerror, e)
        @info "value exchange refused" project_id worker reason = why
        HTTP.WebSockets.send(ch, "error\n" * why)
        close(ch)
        return nothing
    end
    HTTP.WebSockets.send(ch, "ok\n" * name)
    @info "value exchange open" project_id worker = name env_path
    pipe_channels(ch, peer)
    @info "value exchange closed" project_id worker = name env_path
    return nothing
end

# The other side's channel: have the chat's eval host on `w` connect its session
# for `env_path` ("" = its temp session) under a fresh pair token, and wait for it.
function connect_value_peer(state::ServerState, p::ProjectInfo, w::WorkerInfo, env_path::String)
    ws = ensure_eval_host!(state, p, w)
    pair = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
    vp = ValuePair(p.id, w.worker_id, Channel{WorkerLink.LinkChannel}(1))
    lock(() -> (state.value_pairs[pair] = vp), state.lock)
    try
        host_rpc(state, ws, "values", Dict{String,Any}("pair" => pair, "env_path" => env_path);
                 timeout = VALUE_SESSION_TIMEOUT_S)
        timedwait(() -> isready(vp.peer), VALUE_PEER_TIMEOUT_S) === :ok ||
            error("the session on '$(w.name)' said it connected, but its channel never arrived")
        return take!(vp.peer)
    finally
        lock(() -> delete!(state.value_pairs, pair), state.lock)
        close(vp.peer)
        # One that connected as this was given up.
        isready(vp.peer) && WorkerLink.abort(take!(vp.peer), "the value exchange was given up")
    end
end

"""
    pipe_channels(a, b)

Pass every message of `a` on to `b` and back, until one side ends; its end is
passed on too, a clean close as a close, anything else as an abort of both.
"""
function pipe_channels(a::WorkerLink.LinkChannel, b::WorkerLink.LinkChannel)
    back = Base.errormonitor(@async forward_messages(b, a))
    forward_messages(a, b)
    wait(back)
    return nothing
end

function forward_messages(from::WorkerLink.LinkChannel, to::WorkerLink.LinkChannel)
    try
        for msg in from
            HTTP.WebSockets.send(to, msg)
        end
        close(to)
    catch e
        e isa HTTP.WebSockets.WebSocketError || rethrow()
        WorkerLink.abort(from, "the value exchange ended")
        WorkerLink.abort(to, "the value exchange ended")
    end
    return nothing
end
