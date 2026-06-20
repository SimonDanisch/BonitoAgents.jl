# Tests for the agent-thinking path, end to end:
#
#   ACP coalescer   — agent_thought_chunk(s) → one `Thought`, text reconstructed
#   process!        — transient "reasoning…" indicator; commit a ThoughtMsg ONLY
#                     if non-empty (this agent redacts thinking → empty thoughts,
#                     which must leave no trace in the store)
#   persistence     — a non-empty thought round-trips append_thought → load_history
#                     (reloaded with id + text); empty thoughts are not persisted
#   wire shapes     — wire_new / wire_final carry the thought id + html
#   Collapsable     — the eager server-side component renders a <details>
#
# Background: claude-agent-acp returns thinking blocks with an empty plaintext
# `thinking` field and only an encrypted `signature`, so every thought reaching
# us is empty. The pipeline must (a) still signal "the model is reasoning" and
# (b) never render/persist an empty bubble — while staying correct for a future
# agent that DOES expose plaintext thinking.

using Test
using Dates
using Markdown
using BonitoAgents
using Bonito
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

# Build a ChatModel with an inert mock transport (process! never touches it).
mkchat() = BT.ChatModel(newstate(), mktempdir();
                        transport = BT.MockTransport((o, i) -> nothing))

# Run a sequence of SessionUpdates through the per-turn coalescer exactly like
# `prompt!` does, and return the resulting messages with each streaming body
# fully drained into a `(message, text)` pair.
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

thought(text) = ACP.AgentThoughtChunk(ACP.TextContent(text))

@testset "agent thinking" begin

    @testset "coalescer reconstructs thought text" begin
        # Multiple thought chunks coalesce into ONE Thought whose text is the
        # concatenation of the seed + every delta.
        got = coalesce_updates([thought("Let me "), thought("think "), thought("carefully.")])
        @test length(got) == 1
        @test got[1][1] isa ACP.Thought
        @test got[1][2] == "Let me think carefully."

        # A single empty chunk (the redacted case) still produces a Thought, but
        # with empty text — process! is what drops it, not the coalescer.
        got_empty = coalesce_updates([thought("")])
        @test length(got_empty) == 1
        @test got_empty[1][1] isa ACP.Thought
        @test got_empty[1][2] == ""
    end

    @testset "process!: empty thought leaves no trace, only the indicator" begin
        chat = mkchat()
        events = Dict{String,Any}[]
        on(d -> push!(events, d), chat.comm)

        th = ACP.Thought("")        # redacted: empty plaintext
        close(th)
        BT.process!(chat, th)

        # No stored bubble, nothing persisted.
        @test isempty([m for m in chat.msgs_store if m isa BT.ThoughtMsg])
        @test isempty([m for m in BT.load_history(chat.chat_session) if m isa BT.ThoughtMsg])

        # The transient indicator was raised then lowered, and no `thought`
        # message event was emitted.
        kinds = [get(e, "type", "") for e in events]
        @test count(==("thinking"), kinds) == 2
        @test !any(==("thought"), kinds)
        @test !any(==("thought_final"), kinds)
        active = [e["active"] for e in events if get(e, "type", "") == "thinking"]
        @test active == [true, false]
    end

    @testset "process!: non-empty thought commits a collapsed, persisted bubble" begin
        chat = mkchat()
        events = Dict{String,Any}[]
        on(d -> push!(events, d), chat.comm)

        th = ACP.Thought("Hello ")
        append!(th, "world")        # a streamed delta (buffered)
        close(th)
        BT.process!(chat, th)

        tms = [m for m in chat.msgs_store if m isa BT.ThoughtMsg]
        @test length(tms) == 1
        @test tms[1].text == "Hello world"

        # Indicator raised (count=0), the first delta's count tick (later
        # ticks are throttled to ~150 ms, irrelevant for one delta), then
        # lowered — plus the bubble's new + final events. The active pattern
        # is what matters: starts true, ends false.
        kinds = [get(e, "type", "") for e in events]
        @test count(==("thinking"), kinds) == 3
        thinking = [e for e in events if get(e, "type", "") == "thinking"]
        @test first(thinking)["active"] === true
        @test last(thinking)["active"] === false
        @test count(==("thought"), kinds) == 1          # wire_new
        @test count(==("thought_final"), kinds) == 1    # wire_final

        # The final event carries the rendered html (the text reached the wire).
        fin = events[findfirst(e -> get(e, "type", "") == "thought_final", events)]
        @test fin["id"] == tms[1].id
        @test occursin("Hello world", fin["html"])
    end

    @testset "persistence round-trips a thought; empties are skipped" begin
        chat = mkchat()
        BT.append_thought(chat.chat_session, BT.ThoughtMsg("tid-keep", "real reasoning\nsecond line"))
        BT.append_thought(chat.chat_session, BT.ThoughtMsg("tid-empty", "   "))

        reloaded = [m for m in BT.load_history(chat.chat_session) if m isa BT.ThoughtMsg]
        @test length(reloaded) == 1                    # the empty one was not written
        @test reloaded[1].id == "tid-keep"
        @test reloaded[1].text == "real reasoning\nsecond line"

        # A reloaded thought still renders to non-empty html (lazy body source).
        html = sprint(show, MIME("text/html"), Markdown.parse(reloaded[1].text))
        @test occursin("real reasoning", html)
    end

    @testset "wire shapes" begin
        chat = mkchat()
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
    end

    @testset "Collapsable component" begin
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

end
