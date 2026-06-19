# Agent-thinking path, end to end. Migrated onto the TestKit harness for the
# agent-driven parts (real dev_server, real worker subprocess, real ACP wire,
# real Electron browser; only the agent's behaviour is faked via the `agent=`
# callback). The genuinely agent-free pieces — the ACP per-turn coalescer and
# the reusable `Collapsable` server-side component — stay plain unit tests that
# call the functions directly (no ChatModel, no transport).
#
# Background: claude-agent-acp returns thinking blocks with an empty plaintext
# `thinking` field and only an encrypted `signature`, so every thought reaching
# us is empty. The pipeline must (a) still signal "the model is reasoning" via a
# transient indicator and (b) never render/persist an empty bubble — while
# staying correct for a future agent that DOES expose plaintext thinking.
#
# Behaviour asserted through the REAL DOM (driven by `TK.thought(...)` events):
#
#   * empty thought  → only the transient indicator; no `.bt-thought-msg`
#                      committed, nothing persisted.
#   * non-empty one  → persists + renders a `.bt-thought-msg` Collapsable
#                      (`<details>`) whose body carries the rendered thought.
#   * wire shapes    → the model's msgs_store ends with exactly one ThoughtMsg
#                      whose text round-trips; wire_new/wire_final carry id+html.

using Test
using Markdown
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
using Bonito
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
using .TestKit: text, thought, end_turn

# ── Pure unit tests (no agent, no chat) ─────────────────────────────────────

# Run a sequence of SessionUpdates through the per-turn coalescer exactly like
# `prompt!` does, draining each streaming body into a `(message, text)` pair.
function coalesce_updates(updates::Vector)
    out = Channel{ACP.Message}(256)
    st  = ACP.TurnState()
    for u in updates
        ACP.parse_update!(out, st, u)
    end
    close(st)        # finish the trailing message + close its stream
    close(out)
    msgs = collect(out)
    return [(m, m isa ACP.Thought || m isa ACP.AgentMessage ?
                m.text * join(collect(m.updates)) : "") for m in msgs]
end

acp_thought(t) = ACP.AgentThoughtChunk(ACP.TextContent(t))

@testset "agent thinking" begin

    @testset "coalescer reconstructs thought text (pure)" begin
        # Multiple thought chunks coalesce into ONE Thought whose text is the
        # concatenation of the seed + every delta.
        got = coalesce_updates([acp_thought("Let me "), acp_thought("think "), acp_thought("carefully.")])
        @test length(got) == 1
        @test got[1][1] isa ACP.Thought
        @test got[1][2] == "Let me think carefully."

        # A single empty chunk (the redacted case) still produces a Thought, but
        # with empty text — process! is what drops it, not the coalescer.
        got_empty = coalesce_updates([acp_thought("")])
        @test length(got_empty) == 1
        @test got_empty[1][1] isa ACP.Thought
        @test got_empty[1][2] == ""
    end

    @testset "Collapsable component (pure)" begin
        # tool_subsection delegates to the reusable Collapsable.
        sub = BT.tool_subsection("Code", DOM.div("x = 1"); preview="x = 1")
        @test sub isa BT.Collapsable
        @test sub.label == "Code"
        @test sub.open == true
        @test sub.preview == "x = 1"

        # jsrender produces a native <details> wrapping the body.
        app = App(() -> BT.Collapsable("Output", DOM.div("the-body-text"); open=true))
        html = repr(MIME("text/html"), app)
        @test occursin("<details", html)
        @test occursin("the-body-text", html)
        @test occursin("bt-subsection", html)
        @test occursin("Output", html)
    end

    @testset "wire shapes (pure)" begin
        # wire_new/wire_final carry the thought id + html. A ThoughtMsg bound to a
        # model is enough — no transport, no streaming.
        s = TK.dev_server()
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

            tm = BT.ThoughtMsg(chat, "some reasoning")
            wn = BT.wire_new(chat, tm)
            @test wn["type"] == "thought"
            @test wn["id"] == tm.id
            @test haskey(wn, "summary")        # collapsed/lazy, NOT streaming
            @test !get(wn, "streaming", false)

            wf = BT.wire_final(tm)
            @test wf["type"] == "thought_final"
            @test wf["id"] == tm.id
            @test occursin("some reasoning", wf["html"])
        finally
            close(s)
        end
    end

    # ── DOM e2e: empty vs non-empty thoughts through the REAL stack ──────────

    @testset "empty thought → indicator only, no bubble, not persisted (DOM)" begin
        # The agent emits a single EMPTY thought (the redacted case) then ends.
        s = TK.dev_server(; agent = msg -> [thought(""), text("answer"), end_turn()])
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
            TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
            chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

            TK.send_message(s, "think then answer")
            # The agent's text answer lands…
            @test TK.wait_for(s, "agent answer landed",
                "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 30) == true
            @assert timedwait(() -> !chat.busy_active[], 20.0) === :ok "turn never settled"

            # …but an EMPTY thought leaves NO committed bubble in the DOM and
            # nothing in the store / persistence.
            @test TK.eval_js(s, "document.querySelectorAll('.bt-thought-msg').length") == 0
            tms = lock(() -> [m for m in chat.msgs_store if m isa BT.ThoughtMsg], chat.lock)
            @test isempty(tms)
            @test isempty([m for m in BT.load_history(chat.chat_session) if m isa BT.ThoughtMsg])

            errs = TK.eval_js(s, "window.__errs || []")
            @test isempty(errs)
        finally
            close(s)
        end
    end

    @testset "non-empty thought → persisted Collapsable bubble in the DOM" begin
        # A future agent that DOES expose plaintext reasoning: the thought must
        # commit a real (collapsed, persisted) bubble.
        s = TK.dev_server(; agent = msg -> [thought("Hello world reasoning"), text("the answer"), end_turn()])
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
            TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
            chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

            TK.send_message(s, "reason out loud")

            # A real thought bubble renders to a `.bt-thought-msg` carrying a
            # native <details> (the Collapsable).
            @test TK.wait_for(s, "thought bubble appears",
                "document.querySelectorAll('.bt-thought-msg').length >= 1"; timeout = 30) == true
            @test TK.wait_for(s, "thought body carries the reasoning text",
                "(document.querySelector('.bt-thought-msg').innerHTML||'').indexOf('Hello world reasoning') !== -1";
                timeout = 10) == true
            @test TK.eval_js(s,
                "document.querySelector('.bt-thought-msg details') !== null") == true

            @assert timedwait(() -> !chat.busy_active[], 20.0) === :ok "turn never settled"

            # Store shape: exactly one ThoughtMsg whose text round-trips, and it
            # persisted (reloads from history with its text intact).
            tms = lock(() -> [m for m in chat.msgs_store if m isa BT.ThoughtMsg], chat.lock)
            @test length(tms) == 1
            @test tms[1].text == "Hello world reasoning"
            reloaded = [m for m in BT.load_history(chat.chat_session) if m isa BT.ThoughtMsg]
            @test length(reloaded) == 1
            @test reloaded[1].text == "Hello world reasoning"
            # A reloaded thought still renders to non-empty html (lazy body source).
            html = sprint(show, MIME("text/html"), Markdown.parse(reloaded[1].text))
            @test occursin("Hello world reasoning", html)

            errs = TK.eval_js(s, "window.__errs || []")
            @test isempty(errs)
        finally
            close(s)
        end
    end

end
