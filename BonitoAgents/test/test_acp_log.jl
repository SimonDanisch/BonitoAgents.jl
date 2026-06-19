# ACP wire-frame log: the `on_frame` tap on the ACP `Connection` captures every
# raw JSON-RPC frame (both directions, and ONLY protocol frames), the
# `acp_frame_logger` writes them as {"ts","dir","msg"} JSONL into
# chat_dir/acp.jsonl, and `acp_log_response` serves that file for
# GET /acp-log/<project_id>.
#
# TestKit migration. The deleted `MockTransport` / `BT.start_session` scaffolding
# is gone; the tap + logger are exercised against the REAL stack instead:
#
#   1. tap unit       — a real `MockAgent` (the mock claude-agent-acp subprocess)
#                       brought up with an `on_frame` collector tap. The real
#                       bring-up emits out-frames (initialize, session/new) and
#                       their in-frame responses in per-direction wire order; a
#                       THROWING tap must not break the bring-up. (`start!`, the
#                       real Connection, the real subprocess — only the agent's
#                       behaviour is faked.)
#   2. logger e2e     — a full TestKit turn (real dev_server + worker + ACP wire):
#                       acp.jsonl exists under the chat dir, every line parses,
#                       envelopes are well-formed, the client's requests are
#                       logged outbound in order and the streamed updates inbound.
#   3. route          — `acp_log_response` 200 + exact file body for a known
#                       project id, 404 for unknown / path-traversal ids; the
#                       happy path also hit over REAL HTTP against the live
#                       dev_server; plus the `ACP_LOG_ROUTE_RE` regex (pure).

using Test
using JSON
using HTTP
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
using .TestKit: text, end_turn

# Bring up a real mock-agent ACP session with an `on_frame` tap, run `body` with
# the captured frames + the live agent, and always tear the agent down. The mock
# (scenario "normal", no dispatcher) answers initialize + session/new exactly as
# real claude-agent-acp does, so the bring-up frames are real wire traffic.
function with_tapped_agent(body; on_frame)
    cwd   = mktempdir()
    agent = BT.MockAgent(; cwd = cwd)
    try
        # `start!` is synchronous (blocks on the session/new response); guard it
        # with a generous bound so a wedged subprocess fails the test, never hangs.
        t = @async BT.start!(agent; on_frame = on_frame)
        @assert timedwait(() -> istaskdone(t), 30.0) === :ok "agent bring-up hung"
        istaskfailed(t) && fetch(t)        # surface a real bring-up error
        body(agent)
    finally
        try; BT.stop!(agent); catch; end
    end
end

@testset "ACP wire-frame log" begin

    @testset "tap: per-direction wire order, dicts only" begin
        frames = Tuple{Symbol,Dict{String,Any}}[]
        lk = ReentrantLock()
        tap = (dir, msg) -> lock(() -> push!(frames, (dir, Dict{String,Any}(msg))), lk)

        with_tapped_agent(; on_frame = tap) do agent
            cli = BT.client(agent)
            @test cli !== nothing
            @test cli.session_id == "s"
        end

        outs = [m for (d, m) in frames if d == :out]
        ins  = [m for (d, m) in frames if d == :in]
        @test [get(m, "method", "") for m in outs] == ["initialize", "session/new"]
        # Each out-request got its response, in request order.
        @test [m["id"] for m in ins] == [m["id"] for m in outs]
        @test all(haskey(m, "result") for m in ins)
        # The tap only ever sees protocol frames — JSON objects (dicts), never
        # raw strings / partial lines.
        @test all(m -> m isa AbstractDict, [m for (_, m) in frames])
    end

    @testset "tap: a throwing tap never breaks the connection" begin
        with_tapped_agent(; on_frame = (dir, msg) -> error("boom")) do agent
            # Bring-up completed despite the tap throwing on every frame.
            @test BT.client(agent) !== nothing
            @test BT.client(agent).session_id == "s"
        end
    end

    @testset "logger e2e + route" begin
        # A full real turn: two streamed agent text chunks, then end_turn. The
        # real `start_chat_client!` arms `acp_frame_logger` on the worker session,
        # so every frame of this turn lands in acp.jsonl.
        s = TK.dev_server(; agent = msg -> [text("hello "), text("world"), end_turn()])
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
            TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
            chat  = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
            state = s.h.state

            TK.send_message(s, "go")
            @test TK.wait_for(s, "answer streamed",
                "document.body.textContent.indexOf('world') !== -1"; timeout = 30) == true
            @assert timedwait(() -> !chat.busy_active[], 20.0) === :ok "turn never settled"

            path = BT.acp_log_file(chat.chat_dir)
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

            @testset "route: 200 with exact body / 404s (direct)" begin
                r = BT.acp_log_response(state, pid)
                @test r.status == 200
                @test String(r.body) == read(path, String)
                @test BT.acp_log_response(state, "nosuchproject").status == 404
                @test BT.acp_log_response(state, "../" * pid).status == 404
                @test BT.acp_log_response(state, "").status == 404
            end

            @testset "route: live HTTP GET /acp-log/<pid>" begin
                base = "http://127.0.0.1:$(state.srv.port)"
                ok = HTTP.get("$base/acp-log/$pid"; status_exception = false)
                @test ok.status == 200
                @test String(ok.body) == read(path, String)
                # Unknown project id → 404 over the wire.
                miss = HTTP.get("$base/acp-log/nosuchproject"; status_exception = false)
                @test miss.status == 404
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
        finally
            close(s)
        end
    end

end
