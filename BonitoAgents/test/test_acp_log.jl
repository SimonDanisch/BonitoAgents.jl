# ACP wire-frame log: the `on_frame` tap on `ACP.Connection` captures every
# raw JSON-RPC frame (both directions, and ONLY protocol frames), the
# `acp_frame_logger` writes them as {"ts","dir","msg"} JSONL into
# chat_dir/acp.jsonl, and `acp_log_response` serves that file for
# GET /acp-log/<project_id>.
#
# Three layers:
#   1. tap unit       — start_session over MockTransport with a collector tap:
#                       out-frames (initialize, session/new) and in-frames
#                       (their responses) arrive in per-direction wire order;
#                       a THROWING tap must not break the bring-up.
#   2. logger e2e     — real ChatModel + start_chat_client! (which arms the
#                       logger) through a full prompt turn: acp.jsonl exists,
#                       every line parses, envelopes are well-formed, updates
#                       are logged as dir=="in".
#   3. route          — acp_log_response: 200 + exact file body for a known
#                       project id, 404 for unknown / path-traversal ids.

using Test
using JSON
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# JSON-RPC responder: answers initialize + session/new; on session/prompt
# streams two agent chunks + resolves end_turn. (Pattern from test_clean_cancel.)
function scripted_transport()
    upd(text) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
        "params"=>Dict("sessionId"=>"s",
            "update"=>Dict("sessionUpdate"=>"agent_message_chunk",
                           "content"=>Dict("type"=>"text","text"=>text)))))
    resp(id, result) = JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result))
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg    = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, resp(id, Dict()))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, resp(id, Dict("sessionId" => "s")))
                elseif method == "session/prompt" && id !== nothing
                    put!(incoming, upd("hello "))
                    put!(incoming, upd("world"))
                    put!(incoming, resp(id, Dict("stopReason" => "end_turn")))
                end
            end
        catch e
            e isa InvalidStateException || @warn "responder failed" exception=e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

@testset "ACP wire-frame log" begin

    @testset "tap: per-direction wire order, dicts only" begin
        frames = Tuple{Symbol,Dict{String,Any}}[]
        lk = ReentrantLock()
        tap = (dir, msg) -> lock(() -> push!(frames, (dir, msg)), lk)

        t = scripted_transport()
        client, replay = BT.start_session(t, ACP.FSRequestHandler("/tmp"); on_frame = tap)
        @test client isa ACP.Client
        @test isempty(replay)

        outs = [m for (d, m) in frames if d == :out]
        ins  = [m for (d, m) in frames if d == :in]
        @test [get(m, "method", "") for m in outs] == ["initialize", "session/new"]
        # Each out-request got its response, in request order.
        @test [m["id"] for m in ins] == [m["id"] for m in outs]
        @test all(haskey(m, "result") for m in ins)

        close(client)
    end

    @testset "tap: a throwing tap never breaks the connection" begin
        t = scripted_transport()
        client, _ = BT.start_session(t, ACP.FSRequestHandler("/tmp");
                                     on_frame = (dir, msg) -> error("boom"))
        # Bring-up completed despite the tap throwing on every frame.
        @test client.session_id == "s"
        close(client)
    end

    @testset "logger e2e: chat turn lands in acp.jsonl" begin
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        pid = "acplog42"
        model = BT.ChatModel(state, mktempdir(); project_id = pid,
                             transport = scripted_transport())
        BT.start_chat_client!(model)
        # Record busy transitions via a LISTENER, not by polling: the scripted
        # turn can flip busy on AND off inside one `timedwait` poll interval,
        # which made the bare `timedwait(() -> busy[])` flaky.
        busy_seen = Bool[]
        BT.Bonito.Observables.on(b -> push!(busy_seen, b), model.busy_active)
        BT.send_message!(model, BT.UserMsg("go"))
        @test timedwait(() -> busy_seen == [true, false], 5.0) === :ok

        path = BT.acp_log_file(model.chat_dir)
        @test path == joinpath(state.state_dir, "chats", pid, "acp.jsonl")
        @test isfile(path)

        lines = readlines(path)
        @test !isempty(lines)
        envs = [JSON.parse(l) for l in lines]
        # Every envelope is well-formed.
        @test all(e -> haskey(e, "ts") && e["dir"] in ("in", "out") &&
                       e["msg"] isa AbstractDict, envs)
        @test all(e -> occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$",
                                e["ts"]), envs)

        method_of(e) = get(e["msg"], "method", "")
        # The client's requests were logged outbound, in order.
        out_methods = [method_of(e) for e in envs if e["dir"] == "out"]
        @test out_methods == ["initialize", "session/new", "session/prompt"]
        # The streamed session/update notifications were logged inbound.
        in_updates = [e for e in envs
                      if e["dir"] == "in" && method_of(e) == "session/update"]
        @test length(in_updates) == 2
        texts = [e["msg"]["params"]["update"]["content"]["text"] for e in in_updates]
        @test texts == ["hello ", "world"]

        @testset "route: 200 with exact body / 404s" begin
            r = BT.acp_log_response(state, pid)
            @test r.status == 200
            @test String(r.body) == read(path, String)
            @test BT.acp_log_response(state, "nosuchproject").status == 404
            @test BT.acp_log_response(state, "../" * pid).status == 404
            @test BT.acp_log_response(state, "").status == 404
        end

        @testset "route regex: slash/query variants, no traversal" begin
            cap(t) = (m = match(BT.ACP_LOG_ROUTE_RE, t);
                      m === nothing ? nothing : String(m.captures[1]))
            @test cap("/acp-log/$pid")        == pid
            @test cap("/acp-log/$pid/")       == pid   # browser trailing slash
            @test cap("/acp-log/$pid?x=1")    == pid   # query string in target
            @test cap("/acp-log")             === nothing  # exact-String route's job
            @test cap("/acp-log/")            === nothing  # ditto
            @test cap("/acp-log/../secrets")  === nothing
            @test cap("/acp-log/a/b")         === nothing
        end
    end

end
