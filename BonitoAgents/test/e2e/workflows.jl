# End-to-end workflow tests, driven ONLY through the UI via TestKit
# (ElectronCall.Testing under the hood). No test reaches into ServerState /
# ChatModel / msgs_store: every action is a real click or keystroke, and every
# assertion reads the rendered DOM. The server side (real dev_server, real
# worker, real ACP over stdio) runs unchanged; only the agent binary is the
# mock, scripted by `agent_script`.
#
# A single chat is reused across the conversation testsets: creating a chat
# spawns a fresh mock-agent subprocess (slow cold start), but once its session
# is bound, further turns in the same chat are fast.
#
# Shared-runner form: `run(server)` swaps the server's agent script to this
# suite's `agent_script`, then drives the shared page. It does NOT create or
# close the server. The standalone tail at the bottom lets a single suite still
# be debugged alone (`julia --project=. test/e2e/workflows.jl`).

using Test
# Guarded: when run under run_all.jl, the runner injects a SHARED `TestKit` into
# this module first (so every suite drives the one server through the one harness
# type). Standalone, we include our own copy.
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# One scripted agent: branches on the prompt so each testset gets the events it
# needs by wording its message.
function agent_script(prompt::AbstractString)
    p = lowercase(prompt)
    if occursin("edit", p)
        return [TK.text("I'll edit that file."),
                TK.edit("/tmp/foo.jl", "old contents", "new contents"),
                TK.text("Done.")]
    elseif occursin("bash", p)
        return [TK.bash("ls -la", "total 0\nfile_a.jl\nfile_b.jl"),
                TK.text("That's the listing.")]
    elseif occursin("think", p)
        return [TK.thought("Let me reason about this first."),
                TK.text("Here is the answer.")]
    else
        return [TK.text("Echo: $(prompt)")]
    end
end

# Send a message, then let the (fast) mock turn settle before the next one.
function turn(server, msg)
    TK.send_message(server, msg)
    sleep(2.5)
end

"""
    run_suite(server) -> server

Drive this suite against an already-open shared `TestServer` (browser open).
Swaps the server's agent script to ours, scopes work to a fresh chat, and runs
the testsets. Does not create or close the server.
"""
function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents e2e (UI-only)" begin

        @testset "dev server + dashboard" begin
            TK.to_dashboard(server)
            @test TK.wait_for(server, "dashboard", "!!document.querySelector('.bt-dash')"; timeout = 10) == true
            @test TK.eval_js(server, "document.querySelectorAll('.bt-card').length") >= 1
            @test TK.eval_js(server, "document.body.innerText.includes('workers online')") == true
        end

        # One chat for the whole conversation.
        pid = TK.new_chat(server; title = "Workflows")

        @testset "open a project (new chat via folder picker)" begin
            @test !isempty(pid)
            @test TK.current_chat_id(server) == pid
            @test TK.eval_js(server, "!!document.querySelector('.bt-text-input')") == true
            @test TK.eval_js(server, "[...document.querySelectorAll('.bt-side-item')].some(e => (e.innerText||'').includes('Workflows'))") == true
        end

        @testset "chatting: user message + agent reply" begin
            turn(server, "hello there")
            @test TK.wait_for(server, "agent reply",
                "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 30) == true
            txt = TK.eval_js(server, "document.querySelector('.bt-messages').innerText")
            @test occursin("hello there", txt)
            @test occursin("Echo: hello there", txt)
        end

        @testset "tool call rendering: edit" begin
            turn(server, "please edit the config")
            @test TK.wait_for(server, "edit tool",
                "[...document.querySelectorAll('.bt-tool-title')].some(e => (e.innerText||'').includes('foo.jl'))"; timeout = 30) == true
            # expand the most recent tool to reveal the diff body
            TK.eval_js(server, "(() => { const h=[...document.querySelectorAll('.bt-tool-header')].pop(); if(h)h.click(); return true; })()")
            @test TK.wait_for(server, "diff body",
                "!!document.querySelector('.bt-diff-block, .bt-edit-tool-body, .bt-tool-body')"; timeout = 8) == true
        end

        @testset "tool call rendering: bash" begin
            turn(server, "run a bash command")
            @test TK.wait_for(server, "bash tool",
                "[...document.querySelectorAll('.bt-tool-title')].some(e => (e.innerText||'').trim() === 'Bash')"; timeout = 30) == true
            # expand the bash tool; its command/output shows in the body
            TK.eval_js(server, "(() => { const h=[...document.querySelectorAll('.bt-tool-header')].pop(); if(h)h.click(); return true; })()")
            @test TK.wait_for(server, "bash output",
                "(() => { const m=document.querySelector('.bt-messages'); return !!m && (m.innerText.includes('file_a.jl') || m.innerText.includes('ls -la')); })()"; timeout = 8) == true
        end

        @testset "thinking / reasoning render" begin
            turn(server, "think about this")
            @test TK.wait_for(server, "thinking",
                "!!document.querySelector('.bt-thinking, [class*=thinking]')"; timeout = 30) == true
        end

        @testset "switching agents (provider dropdown)" begin
            # A REAL switch between two DISTINCT provider types. The chat starts on
            # the default backend (Mock Agent); we switch to a SECOND hermetic mock
            # backend (Mock Agent 2). Regression guard: the per-tab `provider`
            # observable used to narrow to the initial provider's concrete type, so
            # `switch_provider!` threw a `convert` MethodError on the backend swap —
            # the session never restarted and the header showed "switch failed".
            # (Switching to the SAME provider is a no-op early-return, which is why
            # a single mock backend can never exercise this path.)
            opts = TK.eval_js(server, "(() => { const s=document.querySelector('.bt-header-provider-select'); return s ? [...s.options].map(o => o.textContent.trim()) : []; })()")
            @test "Mock Agent" in opts
            @test "Mock Agent 2" in opts
            # Must really start on the default — otherwise the switch below would be
            # a no-op early-return and prove nothing.
            @test TK.eval_js(server, "(() => { const s=document.querySelector('.bt-header-provider-select'); return !!s && s.selectedOptions[0].textContent.trim() === 'Mock Agent'; })()") == true

            TK.switch_agent(server, "Mock Agent 2")
            # The dropdown reflects the new provider (this alone does NOT prove the
            # switch worked — `provider[]` is set before the restart that can fail).
            @test TK.wait_for(server, "provider = Mock Agent 2",
                "(() => { const s=document.querySelector('.bt-header-provider-select'); return !!s && s.selectedOptions[0].textContent.trim() === 'Mock Agent 2'; })()";
                timeout = 10) == true
            # Wait for the switch to FULLY settle BEFORE sending a turn: the header
            # status clears to "" (from "Switching…") only after `switch_provider!`
            # finishes the restart and the new session is alive — never "switch
            # failed". Sending a turn before this races the half-torn-down session
            # (the new backend spawn) and the turn errors ("connection torn down").
            @test TK.wait_for(server, "switch settled (status cleared, not failed)",
                "(() => { const s=document.querySelector('.bt-header-status'); return !!s && (s.innerText||'').trim() === ''; })()";
                timeout = 30) == true
            # The real proof the switch SUCCEEDED: the new backend is LIVE and
            # answers a fresh turn. A failed switch leaves the old session dead and
            # no reply ever lands.
            turn(server, "after the switch")
            @test TK.wait_for(server, "reply from switched backend",
                "[...document.querySelectorAll('.bt-agent-msg')].some(b => (b.innerText||'').includes('Echo: after the switch'))";
                timeout = 30) == true
        end
    end
    return server
end

# Standalone: a single suite is still debuggable alone.
if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    # Suite passed if we reach here (a failing @testset throws first).
    TK.exit_success()
end
