# Multi-turn sustained streaming through the real ACP pipeline.
#
# Drives K user prompts, each provoking N agent_message_chunk events from
# a MockTransport responder. The chunks travel:
#
#     mock responder
#       → MockTransport.incoming Channel
#       → ACP.reader_loop (parse JSON-RPC, put! to inbox)
#       → conn.inbox (FIFO Channel{Any} for ALL frame kinds)
#       → dispatcher_loop (single task; routes by kind in wire order)
#       → on_update(::ChatHandler, ::AgentMessageChunk)
#       → apply!(model, AgentUpdate(...))
#       → do_apply! → ingest!(::AgentStream, ...) → comm[]
#
# Every chunk text is tagged `[turn:idx]` so the test can verify wire-order
# preservation end-to-end across many turns. The assertions enforce:
#
#   1. Total chunk count matches K × N exactly — no drops.
#   2. Within each turn, chunks arrive in strictly ascending `idx`.
#   3. Across turns, every turn-K chunk arrives strictly before any
#      turn-(K+1) chunk. This is the structural guarantee of the
#      single-inbox dispatcher in `Connection`: `prompt!` only returns
#      after the dispatcher delivers the end_turn response, which
#      means every preceding chunk has already been ingested.
#   4. `msgs_store` ends with K UserMsg + K AgentMsg.
#   5. Each AgentMsg's text contains BOTH the first and last tag of its
#      turn — i.e. all N chunks landed in the correct bubble, not split
#      across bubbles.
#   6. Final `streaming` state is `NoStream()` — every turn finalized cleanly.
#   7. No comm `agent` events get id-collided across turns (each turn has
#      exactly one fresh AgentStream).
#
# Runs headless — no Electron — because the streaming guarantees we're
# asserting live in the Julia state machine, not in any DOM rendering.

isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using BonitoAgents
using JSON
using Observables: on
import AgentClientProtocol as ACP

const TURNS = 20
const CHUNKS_PER_TURN = 200

# Build a mock transport whose responder fires CHUNKS_PER_TURN agent chunks
# per `session/prompt` request. Turn counter increments per prompt so the
# tags are unique across the run.
function multi_turn_transport()
    turn_counter = Ref(0)
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg    = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>id,
                        "result"=>Dict())))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>id,
                        "result"=>Dict("sessionId"=>"mock-sess-1"))))
                elseif method == "session/prompt" && id !== nothing
                    turn_counter[] += 1
                    turn = turn_counter[]
                    # Stream the chunks in their own task so the responder
                    # loop stays responsive to additional outgoing frames
                    # (cancel, fs requests). Each `put!` is in order.
                    @async try
                        for i in 1:CHUNKS_PER_TURN
                            put!(incoming, JSON.json(Dict(
                                "jsonrpc" => "2.0",
                                "method"  => "session/update",
                                "params"  => Dict(
                                    "sessionId" => "mock-sess-1",
                                    "update" => Dict(
                                        "sessionUpdate" => "agent_message_chunk",
                                        "content" => Dict(
                                            "type" => "text",
                                            "text" => "[$turn:$i] "))))))
                        end
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>id,
                            "result"=>Dict("stopReason"=>"end_turn"))))
                    catch e
                        @warn "multi_turn_transport streamer failed" exception=e
                    end
                elseif id !== nothing
                    # Generic id-bearing reply (session/cancel, etc).
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>id,
                        "result"=>nothing)))
                end
            end
        catch e
            e isa InvalidStateException ||
                @warn "multi_turn_transport responder failed" exception=e
        end)
        return nothing
    end
    return BonitoAgents.MockTransport(on_setup)
end

# Wait for predicate to become true (or timeout). Returns true on success.
function wait_for(pred::Function; timeout::Real = 30.0, interval::Real = 0.02)
    deadline = time() + timeout
    while time() < deadline
        pred() && return true
        sleep(interval)
    end
    return false
end

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]
mock  = multi_turn_transport()
model = BonitoAgents.ChatModel(state, proj.server_path;
                              project_id = proj.id,
                              transport  = mock)

# Listener that records every comm event with its tag (when present). We
# only count events that carry a `[turn:idx]` tag — that's the chunk and
# `agent` events we care about; busy_start / busy_end / etc. are ignored.
arrivals = Tuple{String,Int,Int}[]   # (comm_type, turn, idx)
on(model.comm) do payload
    typ = String(get(payload, "type", "?"))
    txt = String(get(payload, "text", ""))
    m = match(r"^\[(\d+):(\d+)\] ?$", strip(txt))
    if m !== nothing
        push!(arrivals, (typ, parse(Int, m.captures[1]),
                              parse(Int, m.captures[2])))
    end
    return nothing
end

BonitoAgents.start_chat_client!(model)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Sustained streaming: $TURNS turns × $CHUNKS_PER_TURN chunks") do
        t_start = time()
        # Enqueue all turns. `send_message!` is asynchronous now (it `put!`s a
        # UserMessage onto the queue); the single `run_chat!` consumer drives
        # them strictly one at a time, in order. Wait for the store to fill
        # (TURNS user + TURNS agent messages) — the reliable "all done" signal,
        # since busy_active flickers between turns.
        for k in 1:TURNS
            BonitoAgents.send_message!(model, BonitoAgents.UserMsg("turn $k"))
        end
        ok = wait_for(() -> length(model.msgs_store) >= 2TURNS && !model.busy_active[];
                      timeout = 120)
        ok || error("not all turns completed: msgs_store=$(length(model.msgs_store)), busy=$(model.busy_active[])")
        t_total = time() - t_start
        println("  drove $TURNS turns in $(round(t_total, digits=2))s ",
                "($(round(TURNS * CHUNKS_PER_TURN / t_total, digits=0)) chunks/s)")

        # 1. Total chunk count
        record("all $(TURNS * CHUNKS_PER_TURN) chunks delivered",
               @TH.test_eq length(arrivals) (TURNS * CHUNKS_PER_TURN))

        # 2. Within-turn order
        all_in_order = true
        for k in 1:TURNS
            chunks = [a for a in arrivals if a[2] == k]
            for (pos, a) in enumerate(chunks)
                if a[3] != pos
                    all_in_order = false
                    @info "out-of-order chunk" turn=k expected_idx=pos got_idx=a[3] pos=pos
                end
            end
        end
        record("within each turn, chunks arrive in idx order",
               @TH.test_true all_in_order)

        # 3. No cross-turn bleed (every turn-K chunk comes before turn-(K+1))
        no_bleed = true
        for k in 1:(TURNS - 1)
            last_k    = findlast(a -> a[2] == k,     arrivals)
            first_nxt = findfirst(a -> a[2] == k + 1, arrivals)
            if last_k === nothing || first_nxt === nothing ||
               last_k >= first_nxt
                no_bleed = false
                @info "cross-turn bleed" turn=k last_k=last_k first_next=first_nxt
            end
        end
        record("no cross-turn bleed (single-inbox FIFO holds)",
               @TH.test_true no_bleed)

        # 4. msgs_store shape
        n_user  = count(m -> m isa BonitoAgents.UserMsg,  model.msgs_store)
        n_agent = count(m -> m isa BonitoAgents.AgentMsg, model.msgs_store)
        record("msgs_store has $TURNS UserMsg", @TH.test_eq n_user TURNS)
        record("msgs_store has $TURNS AgentMsg", @TH.test_eq n_agent TURNS)

        # 5. Each AgentMsg contains its turn's first and last tag
        agent_msgs = filter(m -> m isa BonitoAgents.AgentMsg, model.msgs_store)
        agent_bodies_ok = true
        for (k, am) in enumerate(agent_msgs)
            if !occursin("[$k:1] ", am.text) ||
               !occursin("[$k:$CHUNKS_PER_TURN] ", am.text)
                agent_bodies_ok = false
                @info "agent body missing chunks" turn=k
            end
        end
        record("each AgentMsg has its turn's first+last chunk",
               @TH.test_true agent_bodies_ok)

        # 6. Settled: not busy (every turn's prompt loop ran to completion; the
        #    per-turn parser seals the trailing message at end_turn, so there is
        #    no model-level streaming state left to inspect).
        record("final state idle (not busy)",
               @TH.test_true (!model.busy_active[]))

        # 7. Exactly one `agent` open event per turn (no orphan AgentStreams)
        agent_open_events = count(a -> a[1] == "agent", arrivals)
        record("exactly $TURNS `agent` open events", @TH.test_eq agent_open_events TURNS)
    end
finally
    TH.report!("Tier — sustained streaming", results)
    # Tear down the mock client cleanly so the dispatcher tasks shut down.
    try
        c = model.client[]
        c === nothing || close(c)
    catch e
        @warn "teardown failed" exception=e
    end
end
