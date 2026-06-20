# Regression tests for the lazy-streaming review fixes (2026-06-12):
#
#   • SummaryMsg carries a wire id — `summary_final` targets the bubble by id;
#     the previous DOM-only lookup missed summaries the virtual scroll held
#     detached, stranding "summary loading…" forever.
#   • msgs.request against an empty store is a no-op — `clamp(x, 0, -1)`
#     inverts the bounds, and `store[0:0]` threw a BoundsError inside the comm
#     handler for a stale request right after a reset.
#   • thought.render renders through `markdown_html` (CommonMark), the same
#     renderer `thought_final` uses — the stdlib `Markdown.parse` it used
#     before italicizes intraword `_`, so the body changed appearance between
#     live and reload-expand.
#   • `ensure_html!` vs `append!` is serialized under MARKDOWN_LOCK — a
#     concurrent reader (msgs.request on the comm task) could previously
#     strand a STALE render in the html cache after `append!` cleared it, and
#     `close` then shipped a final missing the trailing chunks.
#   • The "thinking" liveness tick is throttled (~150 ms), not emitted per
#     redacted token chunk.

using Test
using Bonito
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
mkchat() = BT.ChatModel(newstate(), mktempdir();
                        transport = BT.MockTransport((o, i) -> nothing))

@testset "lazy-streaming review fixes" begin

    @testset "SummaryMsg id rides every wire shape" begin
        chat = mkchat()
        m = BT.SummaryMsg(chat, "compact *summary* body")
        @test !isempty(m.id)
        wn = BT.wire_new(chat, m)
        @test wn["type"] == "summary" && wn["id"] == m.id
        @test BT.msg_to_dict(m)["id"] == m.id
        fin = BT.wire_final(m)
        @test fin["type"] == "summary_final" && fin["id"] == m.id
        @test occursin("summary", fin["html"])
        # Reload-constructed summaries get an id too (fresh uuid is fine —
        # finals only happen live).
        @test !isempty(BT.SummaryMsg("reloaded body").id)
    end

    @testset "msgs.request on an empty store is a no-op" begin
        chat = mkchat()
        events = Dict{String,Any}[]
        on(d -> push!(events, d), chat.comm)
        @test isempty(chat.msgs_store)
        @test BT.handle_command!(chat, Session(), BT.MsgsRequestCommand(0, 10)) === nothing
        @test !any(e -> get(e, "type", "") == "msgs.range", events)
    end

    @testset "thought.render uses the CommonMark renderer" begin
        chat = mkchat()
        tm = BT.ThoughtMsg(chat, "intra_word_underscores must not italicize")
        push!(chat.msgs_store, tm)
        events = Dict{String,Any}[]
        on(d -> push!(events, d), chat.comm)
        BT.handle_command!(chat, Session(), BT.ThoughtRenderCommand(tm.id))
        body = only([e for e in events if get(e, "type", "") == "thought.body"])
        @test body["id"] == tm.id
        # CommonMark wrapper + no intraword <em> (the stdlib renderer's bug).
        @test occursin("markdown-body", body["html"])
        @test !occursin("<em>", body["html"])
        @test occursin("intra_word_underscores", body["html"])
    end

    @testset "ensure_html! cannot strand a stale render after append!" begin
        chat = mkchat()
        for _ in 1:10
            m = BT.AgentMsg(chat, "")
            push!(chat.msgs_store, m)
            stop = Threads.Atomic{Bool}(false)
            # The comm task's msgs.request path, hammering the cache while
            # the consumer task streams appends.
            reader = Threads.@spawn begin
                while !stop[]
                    BT.ensure_html!(m)
                    yield()
                end
            end
            for i in 1:50
                append!(m, "chunk$(i) ")
                yield()
            end
            stop[] = true
            wait(reader)
            close(m)   # builds + caches the final html
            @test occursin("chunk50", m.html)
            @test occursin("chunk1 ", m.text)
        end
    end

    @testset "thinking liveness ticks are throttled" begin
        chat = mkchat()
        events = Dict{String,Any}[]
        on(d -> push!(events, d), chat.comm)
        th = ACP.Thought("")
        for _ in 1:200          # buffered (channel cap 256), drain is fast
            append!(th, "x")
        end
        close(th)
        BT.process!(chat, th)
        ticks = [e for e in events if get(e, "type", "") == "thinking"]
        # initial(count=0) + first-delta tick + final(active=false); a couple
        # extra if draining ever crosses the 150 ms window — but never one
        # per chunk (the old behavior: 202 events).
        @test 3 <= length(ticks) <= 8
        @test first(ticks)["active"] === true
        @test last(ticks)["active"] === false
    end

end
