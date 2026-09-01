# bt_wait, through the real stack.
#
# The unit tests in BonitoMCP check the handler's logic. They cannot check the
# thing the tool EXISTS for: that calling it actually stops the turn. That is a
# property of the whole chain — mock agent → ACP tool call → MCP handler → the
# agent blocking on the result — and it is exactly the kind of contract that
# stays "green" in unit tests while being broken in the app.
#
# So this measures wall-clock: the turn's closing text must not appear before
# the wait is over. And the other half of the promise — that it leaves nothing
# behind — is checked as "the task bar did not grow", which is what distinguishes
# it from `Bash(run_in_background:)` (one pill and one notification per call, the
# thing that piled up 130 orphans).
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Long enough that "returned early" is unambiguous against scheduling noise,
# short enough not to tax the suite.
const WAIT_SECONDS = 5

agent_script(_prompt) = Any[
    TK.mcp_call("bt_wait"; seconds = WAIT_SECONDS, reason = "e2e probe"),
    TK.text("done waiting"), TK.end_turn()]

slot_count(server) =
    TK.eval_js(server, "document.querySelectorAll('.bt-taskbar-slot').length")

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "bt_wait stops the turn and leaves nothing behind" begin
        TK.new_chat(server; title = "Waiting")
        # Counted, not asserted to be zero: this runs on the shared soak server,
        # where an earlier suite may legitimately have left a pill pinned.
        before = slot_count(server)

        t0 = time()
        TK.send_message(server, "wait for the job")
        @test TK.wait_for(server, "turn's closing text",
            "[...document.querySelectorAll('.bt-agent-msg')].some(e => " *
            "e.innerText.includes('done waiting'))"; timeout = 60) == true
        elapsed = time() - t0

        # THE contract. A turn that came back early means the wait did not block,
        # which is the failure that sends the agent back to spawning sleepers.
        @test elapsed >= WAIT_SECONDS

        # The card is there and finished.
        @test TK.wait_for(server, "bt_wait tool card",
            "[...document.querySelectorAll('.bt-tool-msg')].some(e => " *
            "(e.querySelector('.bt-tool-title')?.textContent || '').includes('bt_wait'))";
            timeout = 10) == true

        # The REAL handler ran, not a mock of it: `reason` is echoed by
        # `wait_handler` and by nothing else on this path. The body is lazily
        # mounted, so open it first — same reason `bt_eval`'s probe does.
        TK.eval_js(server, """(() => {
            const t = [...document.querySelectorAll('.bt-tool-msg')].find(e =>
                (e.querySelector('.bt-tool-title')?.textContent || '').includes('bt_wait'));
            t?.querySelector('.bt-tool-header')?.click();
            return true;
        })()""")
        @test TK.wait_for(server, "wait result in the card body",
            "[...document.querySelectorAll('.bt-tool-msg')].some(e => " *
            "(e.innerText || '').includes('waited') && (e.innerText || '').includes('e2e probe'))";
            timeout = 15) == true

        # No pill, no background task, nothing to notify about later — the tool
        # result IS the completion. This is the whole difference from starting a
        # sleeper, so it is asserted rather than assumed.
        @test slot_count(server) == before
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
