# Regression: a single agent turn that streams a large burst of messages must
# not deadlock. The ACP `deliver_update!` used to DROP the oldest update when the
# per-turn `updates` channel (capacity BUF=256) filled under load — but those are
# DISTINCT updates for different messages, so dropping one discarded a tool's
# terminal `tool_call_update`; that tool's per-message `updates` channel never
# closed and the chat consumer's `for snap in m.updates` blocked FOREVER. The
# turn wedged at ~130 messages (≈ BUF/2 updates) every time. deliver_update! now
# backpressures (blocks until the consumer drains) instead of dropping.
#
# We assert against the SERVER-side msgs_store (the authoritative count): a single
# "fill 500" must reach all 500 tool rows + the user + the trailing text. This is
# the one allowed server-side read — a SECONDARY count, not used to drive.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# "fill N" streams N tool messages in ONE turn (the burst that triggered the
# deadlock — NOT split across turns).
function agent_script(prompt)
    m = match(r"fill (\d+)", lowercase(prompt))
    m === nothing && return [TK.text("Echo: $(prompt)")]
    n = parse(Int, m.captures[1])
    evs = Any[TK.tool(; kind = "execute", title = "step $(i)",
                      content = [TK.text_block("result:\nline a\nline b\nline c")]) for i in 1:n]
    push!(evs, TK.text("done $(n)"))
    return evs
end

function run_suite(server)
    server.agent_fn[] = agent_script
    pid = TK.new_chat(server; title = "Flood")
    TK.open_chat(server, pid)
    TK.wait_for(server, "input", "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 15)

    state = server.h.state
    serverlen() = (m = get(state.chat_models, pid, nothing); m === nothing ? -1 : length(m.msgs_store))

    @testset "BonitoAgents streaming flood (no deadlock)" begin
        TK.send_message(server, "fill 500")
        # 502 = 1 user + 500 tools + 1 trailing text. The burst streams in a few
        # seconds; the pre-fix deadlock never got past ~130, so reaching 502 is
        # the detector.
        ok = false
        for _ in 1:20   # ~4x the few-second stream; the pre-fix hang never finishes
            if serverlen() >= 502; ok = true; break; end
            sleep(1)
        end
        @test ok == true
        @test serverlen() == 502
        # And the browser virtual-scroll agrees (the wire events all arrived). The
        # runner schedules this suite EARLY (2nd, near-empty session) so the 500-row
        # burst paints in ~1–2s — see the ordering note in run_all.jl. A tight
        # budget is therefore the right detector (the pre-fix hang NEVER reaches
        # 502; a wedge here would blow this budget). Run late, an unrelated
        # client-side accumulation bug makes the same burst take minutes — which is
        # exactly why it runs early.
        @test TK.wait_for(server, "browser totalCount",
            "(() => { const c=document.querySelector('.bt-messages'); return c&&c.__bt_chat&&c.__bt_chat.totalCount>=502; })()"; timeout = 20) == true
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
