# Context meter + slash-command autocomplete, UI-only via TestKit.
#
# Behaviour asserted (the user-facing contract):
#   * A `usage_update` turns into the header context meter — real numbers
#     ("21.8k/200k · 11% · $0.42"), not the old chunk-count proxy. Hidden
#     until the first report.
#   * An `available_commands_update` feeds the composer autocomplete: typing
#     a lone "/query" first token opens a popup of matching commands
#     (prefix matches first), Enter accepts into "/name ", Escape closes
#     WITHOUT cancelling anything.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const CMDS = [(name = "compact", description = "Compact the chat history"),
              (name = "review", description = "Review a pull request", hint = "[pr]"),
              (name = "code-review", description = "Review the current diff")]

agent_script(_prompt) = [TK.usage(21784, 200000; cost = 0.42),
                         TK.commands(CMDS),
                         TK.text("done.")]

# Pane-scoped helpers (the shared soak server keeps other panes mounted).
const PANE = "[...document.querySelectorAll('.bt-chatpane')].find(x => x.offsetParent !== null)"

setinput(s, v) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const t = p.querySelector('.bt-text-input');
    t.focus(); t.value = $(repr(v));
    t.dispatchEvent(new Event('input', { bubbles: true }));
    return true; })()""")

key(s, k) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const t = p.querySelector('.bt-text-input');
    t.dispatchEvent(new KeyboardEvent('keydown', { key: $(repr(k)), bubbles: true }));
    return true; })()""")

acstate(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const ac = p.querySelector('.bt-cmd-ac');
    return JSON.stringify({
        open: ac.classList.contains('bt-cmd-ac-open'),
        names: [...ac.querySelectorAll('.bt-cmd-ac-name')].map(e => e.textContent),
        value: p.querySelector('.bt-text-input').value }); })()""")

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents usage meter + slash autocomplete (UI-only)" begin
        TK.new_chat(server; title = "Usage")

        @testset "header context meter shows the wire numbers" begin
            # Hidden until the first usage_update lands.
            @test TK.eval_js(server, """(() => {
                const p = $(PANE);
                const u = p.querySelector('.bt-header-usage');
                return u && u.offsetParent === null; })()""") == true
            TK.send_message(server, "hi")
            @test TK.wait_for(server, "usage pill populated",
                """(() => {
                    const p = $(PANE);
                    const u = p.querySelector('.bt-header-usage');
                    return u && u.textContent === '21.8k/200k · 11% · \$0.42'; })()""";
                timeout = 20) == true
            @test TK.wait_for(server, "turn done",
                "$(PANE).innerText.includes('done.')"; timeout = 10) == true
        end

        @testset "slash autocomplete: open, filter, accept, escape" begin
            setinput(server, "/")
            @test TK.wait_for(server, "popup open with all commands",
                """(() => { const p = $(PANE);
                    const ac = p.querySelector('.bt-cmd-ac');
                    return ac && ac.classList.contains('bt-cmd-ac-open') &&
                           ac.querySelectorAll('.bt-cmd-ac-item').length === 3; })()""";
                timeout = 5) == true
            # Filtering: "/co" prefix-matches compact + code-review (original
            # order preserved), and plain "review" doesn't sneak in.
            setinput(server, "/co")
            @test occursin("\"names\":[\"/compact\",\"/code-review\"]", acstate(server))
            # Enter accepts the selected (first) item into "/name ".
            key(server, "Enter")
            st = acstate(server)
            @test occursin("\"open\":false", st)
            @test occursin("\"value\":\"/compact \"", st)
            # Arrow selection: second item.
            setinput(server, "/co")
            key(server, "ArrowDown")
            key(server, "Enter")
            @test occursin("\"value\":\"/code-review \"", acstate(server))
            # Escape closes the popup and leaves the draft untouched.
            setinput(server, "/re")
            key(server, "Escape")
            st = acstate(server)
            @test occursin("\"open\":false", st)
            @test occursin("\"value\":\"/re\"", st)
            setinput(server, "")
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
