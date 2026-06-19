# Multi-turn sustained streaming through the REAL ACP pipeline, migrated onto the
# TestKit harness (real dev_server, real worker subprocess, real ACP wire, real
# Electron browser; only the agent's behaviour is faked via the `agent=`
# callback).
#
# We drive K user prompts through the actual chat composer. Each prompt provokes
# N agent text chunks from the mock agent, every chunk tagged `[turn:idx]`. The
# chunks travel the full production path:
#
#     mock agent (dispatcher streams the TestKit `text(...)` events)
#       → ACP JSON-RPC agent_message_chunk over real stdio
#       → conn.inbox (single FIFO Channel for ALL frame kinds)
#       → dispatcher_loop (one task; routes by kind in wire order)
#       → apply!(model, AgentUpdate(...)) → ingest!(::AgentStream, ...)
#       → AgentMsg.text accumulates the chunk + chat_emit(wire_chunk) to the DOM
#
# Invariants enforced (unchanged from the legacy MockTransport test; observed off
# the sealed store + the live comm stream, both real production state):
#
#   1. Total chunk count matches K × N exactly — no drops.
#   2. Within each turn, chunks arrive / accumulate in strictly ascending idx.
#   3. No cross-turn bleed — turn-K's bubble contains ONLY turn-K tags, and the
#      comm stream never interleaves a turn-(K+1) tag before turn-K finished
#      (the single-inbox FIFO + one-turn-at-a-time consumer guarantee).
#   4. msgs_store ends with K UserMsg + K AgentMsg.
#   5. Each AgentMsg's text contains BOTH the first and last tag of its turn —
#      all N chunks landed in the correct bubble, not split across bubbles.
#   6. Final state is idle (busy clears) — every turn finalized cleanly.
#   7. Exactly K AgentMsg bubbles — no orphan / collided AgentStreams across
#      turns, and the DOM shows K agent bubbles.
#
# SCALING NOTE: the legacy headless test ran 20 turns × 200 chunks = 4000 chunks
# straight through the Julia state machine (no DOM). Here every chunk is a REAL
# ACP frame over real stdio AND a real DOM render in Electron, so 4000 would take
# minutes. We scale to TURNS=6 × CHUNKS_PER_TURN=25 = 150 chunks — still many
# turns × many chunks, which is what every invariant above is structural in
# (order, no-drop, no-bleed, per-turn sealing). The counts are scaled, the
# invariants are not weakened.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
using Observables: on
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, end_turn

const TURNS = 6
const CHUNKS_PER_TURN = 25

@testset "sustained streaming — $TURNS turns × $CHUNKS_PER_TURN chunks, wire order preserved" begin
    # Per-prompt turn counter so chunk tags are unique across the run. The mock
    # streams N tagged text chunks then ends the turn.
    turn_counter = Ref(0)
    s = TK.dev_server(; agent = msg -> begin
        turn_counter[] += 1
        turn = turn_counter[]
        evs = Any[]
        for i in 1:CHUNKS_PER_TURN
            push!(evs, text("[$turn:$i] "))
        end
        push!(evs, end_turn())
        evs
    end)
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        sleep(0.5)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # Record every comm event that carries a `[turn:idx]` tag, in arrival
        # order, off the REAL comm stream — `agent` open events and `chunk`
        # events both flow here. We tag-match the text/html payload.
        arrivals = Tuple{String,Int,Int}[]   # (comm_type, turn, idx)
        on(model.comm) do payload
            typ = String(get(payload, "type", "?"))
            blob = String(get(payload, "text", "")) * String(get(payload, "html", ""))
            for m in eachmatch(r"\[(\d+):(\d+)\]", blob)
                push!(arrivals, (typ, parse(Int, m.captures[1]), parse(Int, m.captures[2])))
            end
            return nothing
        end

        # ── Drive the turns through the real composer, one at a time ──────────
        for k in 1:TURNS
            TK.send_message(s, "turn $k")
            # Each turn must fully finish (its AgentMsg seals) before the next —
            # wait on the sealed store growing to k user + k agent, busy cleared.
            ok = timedwait(45.0) do
                u = lock(model.lock) do
                    count(m -> m isa BT.UserMsg, model.msgs_store)
                end
                a = lock(model.lock) do
                    count(m -> m isa BT.AgentMsg, model.msgs_store)
                end
                u >= k && a >= k && !model.busy_active[]
            end
            @assert ok === :ok "turn $k never completed (store didn't reach $k user + $k agent, or still busy)"
        end

        # ── 4. msgs_store shape ───────────────────────────────────────────────
        store = lock(() -> copy(model.msgs_store), model.lock)
        n_user  = count(m -> m isa BT.UserMsg,  store)
        n_agent = count(m -> m isa BT.AgentMsg, store)
        @test n_user  == TURNS
        @test n_agent == TURNS

        agent_msgs = filter(m -> m isa BT.AgentMsg, store)

        # ── 1+5. Total chunk count + each AgentMsg has all N tags (first..last)
        # Parse each AgentMsg body's tags; they belong to its turn only.
        per_turn_tags = Vector{Vector{Tuple{Int,Int}}}()
        for am in agent_msgs
            tags = Tuple{Int,Int}[]
            for m in eachmatch(r"\[(\d+):(\d+)\]", am.text)
                push!(tags, (parse(Int, m.captures[1]), parse(Int, m.captures[2])))
            end
            push!(per_turn_tags, tags)
        end
        total_in_bodies = sum(length, per_turn_tags)
        @test total_in_bodies == TURNS * CHUNKS_PER_TURN

        # ── 2. Within each turn, chunks accumulate in ascending idx ───────────
        within_order_ok = true
        for (k, tags) in enumerate(per_turn_tags)
            idxs = [t[2] for t in tags]
            idxs == collect(1:CHUNKS_PER_TURN) || (within_order_ok = false)
        end
        @test within_order_ok

        # ── 3a. No cross-turn bleed in the bodies (turn-k body has only turn-k)
        no_bleed_bodies = true
        for (k, tags) in enumerate(per_turn_tags)
            all(t -> t[1] == k, tags) || (no_bleed_bodies = false)
        end
        @test no_bleed_bodies

        # ── 5. each AgentMsg has its turn's first + last chunk ────────────────
        bodies_have_endpoints = true
        for (k, am) in enumerate(agent_msgs)
            (occursin("[$k:1] ", am.text) && occursin("[$k:$CHUNKS_PER_TURN] ", am.text)) ||
                (bodies_have_endpoints = false)
        end
        @test bodies_have_endpoints

        # ── 3b. No cross-turn bleed on the live comm stream ───────────────────
        # Every turn-K tagged event arrives strictly before any turn-(K+1) one.
        no_bleed_stream = true
        for k in 1:(TURNS - 1)
            last_k    = findlast(a -> a[2] == k,     arrivals)
            first_nxt = findfirst(a -> a[2] == k + 1, arrivals)
            (last_k === nothing || first_nxt === nothing || last_k >= first_nxt) &&
                (no_bleed_stream = false)
        end
        @test no_bleed_stream

        # ── 6. Settled: not busy ──────────────────────────────────────────────
        @test model.busy_active[] == false

        # ── 7. Exactly K agent bubbles in the DOM ─────────────────────────────
        # Virtual scroll may window; but with only $TURNS*2 messages they all fit.
        @test TK.wait_for(s, "$TURNS agent bubbles in DOM",
            "document.querySelectorAll('.bt-agent-msg').length === $TURNS"; timeout = 8) == true

        TK.screenshot(s, joinpath(tempdir(), "bt-streaming-sustained-final.png"))

        # ── No JS errors across the whole run ─────────────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
