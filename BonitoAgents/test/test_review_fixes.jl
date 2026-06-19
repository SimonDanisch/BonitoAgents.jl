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
#
# TestKit migration: every regression above is on a PURE function or a direct
# wire/cache contract — they stay DIRECT unit tests. The ONLY change is the
# fixture: `mkchat()` now binds a no-op `MockAgent([])` instead of the deleted
# `MockTransport` (the `transport=` kwarg is gone; `agent=` replaces it). None
# of these drive a turn, so the MockAgent is never `start!`ed — it just gives
# the model a real `comm` to broadcast on.
#
# The SummaryMsg-id fix has a USER-VISIBLE half — "a summary that arrives while
# its bubble is virtually scrolled out still fills in, not stuck on
# 'loading…'". That half is driven through the REAL stack on TestKit: after a
# real turn, the server `send!`s + `close`s a SummaryMsg on the live model, and
# we assert the `.bt-summary-msg` body in the DOM carries the rendered text
# (`summary_final` found the node by id).

using Test
using Bonito
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
using .TestKit: text, end_turn

# Real ServerState + a ChatModel whose agent is a no-op MockAgent. Nothing here
# drives a turn, so the agent is never started — it only gives the model a real
# `comm` / `chat_session` for the wire + persistence paths to bind to.
newstate() = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
mkchat() = BT.ChatModel(newstate(), mktempdir(); agent = BT.MockAgent([]))

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

    # ── DOM e2e: a SummaryMsg fills its bubble by id (not stuck on "loading…") ──
    # The user-visible half of the SummaryMsg-id fix. We drive a real turn so a
    # chat is live + mounted, then server-side `send!` + `close` a SummaryMsg on
    # the live model: `send!` ships `{type:"summary", id, html:"", streaming}`
    # (the JS renders "summary loading…"), `close` ships `{type:"summary_final",
    # id, html}`. The id lets `onSummaryFinal` find the node and fill the body —
    # the bug was a DOM-only lookup that left scrolled-out summaries stranded.
    @testset "summary_final fills the bubble by id (DOM)" begin
        s = TK.dev_server(; agent = msg -> [text("ok"), end_turn()])
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
            TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
            chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

            TK.send_message(s, "hi")
            @test TK.wait_for(s, "agent answer landed",
                "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 30) == true
            @assert timedwait(() -> !chat.busy_active[], 20.0) === :ok "turn never settled"

            # Server-side: emit the summary bubble, then finalize it. Mirrors a
            # live `/compact` summary arriving on the consumer task.
            sm = BT.SummaryMsg(chat, "compact *recap* of the conversation")
            BT.send!(chat, sm)
            # The placeholder bubble renders (carrying the summary's id).
            @test TK.wait_for(s, "summary bubble appears",
                "document.querySelectorAll('.bt-summary-msg').length >= 1"; timeout = 10) == true

            close(sm)   # emits summary_final → onSummaryFinal fills the body by id
            @test TK.wait_for(s, "summary body filled (not stuck on loading)", """
                (() => { const b = document.querySelector('.bt-summary-msg .bt-summary-body');
                         return !!b && (b.innerHTML||'').indexOf('recap') !== -1
                                    && (b.textContent||'').indexOf('loading') === -1; })()
            """; timeout = 10) == true

            errs = TK.eval_js(s, "window.__errs || []")
            @test isempty(errs)
        finally
            close(s)
        end
    end

end
