# More end-to-end chat features, UI-only via TestKit: streaming accumulation,
# markdown rendering, responsive (mobile) layout, and switching between chats.
# Same rules as workflows.jl: real app, no internal-API calls.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const MARKDOWN = """
# Heading One

Some **bold** text and a [link](https://example.com).

- first item
- second item

```julia
println("hi")
```
"""

function agent_script(prompt::AbstractString)
    p = lowercase(prompt)
    if occursin("stream", p)
        # Several chunks that must accumulate into ONE agent bubble.
        return [TK.text("Hello "), TK.text("from "), TK.text("the agent.")]
    elseif occursin("markdown", p)
        return [TK.text(MARKDOWN)]
    else
        return [TK.text("Echo: $(prompt)")]
    end
end

turn(server, msg) = (TK.send_message(server, msg); sleep(2.5))

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents chat features (UI-only)" begin

        pidA = TK.new_chat(server; title = "Alpha")   # one cold start

        @testset "streaming: chunks accumulate into one bubble" begin
            turn(server, "stream please")
            @test TK.wait_for(server, "agent bubble",
                "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 30) == true
            # the three chunks land in a single bubble
            @test TK.wait_for(server, "accumulated",
                "[...document.querySelectorAll('.bt-agent-msg')].some(b => { const t=b.innerText||''; return t.includes('Hello') && t.includes('the agent.'); })"; timeout = 10) == true
        end

        @testset "markdown rendering" begin
            turn(server, "markdown please")
            @test TK.wait_for(server, "heading rendered",
                "[...document.querySelectorAll('.bt-agent-msg')].some(b => b.querySelector('h1'))"; timeout = 30) == true
            # the same bubble has a list, code block, bold, and a link
            bubble_has = sel -> TK.eval_js(server,
                "[...document.querySelectorAll('.bt-agent-msg')].some(b => b.querySelector($(TK.json(sel))))")
            @test bubble_has("ul li") == true
            @test bubble_has("pre") == true
            @test bubble_has("strong") == true
            @test bubble_has("a[href]") == true
        end

        @testset "responsive / mobile layout" begin
            # Wide: the sidebar shows its name labels.
            TK.set_window_size(server, 1280, 800)
            @test TK.wait_for(server, "labels visible",
                "[...document.querySelectorAll('.bt-side-name')].some(e => e.offsetParent !== null)"; timeout = 8) == true
            # Narrow: labels collapse to icons (display:none).
            TK.set_window_size(server, 480, 800)
            @test TK.wait_for(server, "labels hidden",
                "[...document.querySelectorAll('.bt-side-name')].every(e => e.offsetParent === null)"; timeout = 8) == true
            # Restore.
            TK.set_window_size(server, 1280, 800)
            @test TK.wait_for(server, "labels back",
                "[...document.querySelectorAll('.bt-side-name')].some(e => e.offsetParent !== null)"; timeout = 8) == true
        end

        @testset "multiple chats + sidebar switching" begin
            # Note: sending a message renames a chat to that message's text, so
            # switch by the stable project id rather than the title.
            pidB = TK.new_chat(server; title = "Beta")
            @test TK.current_chat_id(server) == pidB
            TK.open_chat(server, pidA)
            @test TK.current_chat_id(server) == pidA
            TK.open_chat(server, pidB)
            @test TK.current_chat_id(server) == pidB
        end
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
