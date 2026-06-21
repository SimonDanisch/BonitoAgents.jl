# End-to-end lens search bar, UI-only via TestKit. No internal-API calls.
#
# The lens bar lives in the header and filters the message list by a small
# query language (`/user_message "monitor"`, `/agent_message`, …) plus actions.
# We drive a real chat with a mixed history, then:
#   * the bar + server-supplied vocabulary are present
#   * typing a partial token offers autocomplete
#   * applying a lens filters the list to only matching messages
#   * clearing restores everything
#   * saving makes a persisted chip; deleting removes it
#
# Reading the chat's own client state (`.bt-messages.__bt_chat.*`) is fair game
# here — it's the UI's state, not a Julia internal.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Keep saved lenses out of the real ~/.config — point them at a temp file.
# `lenses_path()` reads this ENV live (in the server process, same process as
# the test), so setting it inside `run` is enough; we also set it here so a
# standalone run never touches ~/.config.
const LENS_FILE = joinpath(mktempdir(), "lenses.json")
ENV["BONITOAGENTS_LENSES_PATH"] = LENS_FILE

agent_script(prompt) = occursin("chart", lowercase(prompt)) ?
    [TK.text("Here is a chart."), TK.bash("plot.sh", "rendered chart")] :
    [TK.text("On it.")]

set_lens(q) = """(() => { const i = document.querySelector('.bt-lens-input');
    i.value = $(TK.json(q)); i.dispatchEvent(new Event('input', {bubbles:true})); return true; })()"""
chat_state(expr) = "document.querySelector('.bt-messages').__bt_chat.$(expr)"

function run_suite(server)
    server.agent_fn[] = agent_script
    ENV["BONITOAGENTS_LENSES_PATH"] = LENS_FILE   # ensure our temp file under the shared runner

    @testset "BonitoAgents lens search (UI-only)" begin
        TK.new_chat(server; title = "Lens")
        # Mixed history: a user msg mentioning "monitor", an agent reply, a
        # second user msg that does NOT, and an agent reply with a tool.
        TK.send_message(server, "please start a resource monitor"); sleep(2.5)
        TK.send_message(server, "show me a chart"); sleep(2.5)

        @testset "the lens bar and its vocabulary are present" begin
            @test TK.eval_js(server, "!!document.querySelector('.bt-header .bt-lens-bar')") == true
            @test TK.eval_js(server, "!!document.querySelector('.bt-lens-input')") == true
            # The vocabulary is chat-DERIVED: `lens_vocabulary` always offers
            # `all`, but the message-type keys (`user_message`, …) only arrive
            # once the messages they describe exist and the server re-emits
            # `lens.vocab`. Gate on the real key the autocomplete test below
            # needs — `length > 0` is satisfied by the trivial `["all"]` seed
            # and would let the next testset race the actual vocab push.
            @test TK.wait_for(server, "message-derived vocabulary arrived",
                "$(chat_state("lensVocab")).includes('user_message')"; timeout = 8) == true
        end

        @testset "typing a partial token offers autocomplete" begin
            TK.eval_js(server, set_lens("/user"))
            @test TK.wait_for(server, "autocomplete items",
                "document.querySelectorAll('.bt-lens-ac-item').length > 0"; timeout = 5) == true
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-lens-ac-item')].some(e => e.textContent.includes('user_message'))") == true
            TK.eval_js(server, set_lens(""))
        end

        @testset "applying a lens filters to only matching messages" begin
            TK.eval_js(server, set_lens("/user_message \"monitor\""))
            TK.eval_js(server, "document.querySelector('.bt-lens-go').click()")
            @test TK.wait_for(server, "lens active",
                "$(chat_state("lensActive")) === true"; timeout = 5) == true
            # Only the user message that mentions "monitor" stays visible.
            @test TK.wait_for(server, "one user message visible",
                "[...document.querySelectorAll('.bt-user-msg')].filter(e => e.offsetParent !== null).length === 1"; timeout = 5) == true
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-user-msg')].filter(e => e.offsetParent !== null)[0].innerText.trim()") ==
                "please start a resource monitor"
        end

        @testset "clearing the lens restores every message" begin
            TK.eval_js(server, "document.querySelector('.bt-lens-clear').click()")
            @test TK.wait_for(server, "lens cleared",
                "$(chat_state("lensActive")) === false"; timeout = 5) == true
        end

        @testset "saving makes a persisted chip; deleting removes it" begin
            TK.eval_js(server, set_lens("/agent_message"))
            TK.eval_js(server, "document.querySelector('.bt-lens-save').click()")
            @test TK.wait_for(server, "saved-lens chip",
                "!!document.querySelector('.bt-lens-chip')"; timeout = 5) == true
            sleep(0.4)
            @test isfile(LENS_FILE)
            TK.eval_js(server, "document.querySelector('.bt-lens-chip-x').click()")
            @test TK.wait_for(server, "chip removed",
                "document.querySelector('.bt-lens-chip') === null"; timeout = 5) == true
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
