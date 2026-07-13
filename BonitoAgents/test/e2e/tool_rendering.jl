# End-to-end tool-call rendering, UI-only via TestKit. No internal-API calls.
#
# One turn emits a tool of each interesting kind; we assert the chat renders
# each correctly:
#   * edit (multi)  -> a Monaco DiffEditor per file, wrapped in .bt-multi-diff
#   * search        -> one .bt-search-row per grep hit + a "N matches" summary
#   * other/eval    -> bt_julia_eval stdout/result sections (.bt-eval-section)
#   * read          -> the file body rendered as code
#   * move / fetch  -> header summary derived from content ("a → b", a domain)
#   * execute       -> a status pill that walks pending -> in_progress ->
#                      completed (driven by tool_update + delay, turn held open)
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Second turn (prompt mentions "error"): the failure corner cases — an eval
# tool that errors and an execute tool that fails. Kept in their own turn so
# they're the most-recent (rendered) messages when we assert on them, rather
# than recycled out of the virtual window behind the first turn's tools.
agent_script(prompt) = occursin("error", lowercase(prompt)) ? [
    TK.tool(kind = "other", title = "bt_julia_eval", id = "eval-err",
            tool_name = "mcp__btworker__bt_julia_eval", status = "failed",
            content = [TK.text_block("error:\nMethodError: no method matching foo(::Int64)")]),
    TK.tool(kind = "execute", title = "failed task", id = "exec-fail", tool_name = "Bash",
            status = "failed", content = [TK.text_block("exit code 1")]),
] : [
    TK.tool(kind = "edit", title = "multi", id = "edit-multi", tool_name = "Edit",
            content = [TK.diff_block("src/a.jl", "x = 1", "x = 2"),
                       TK.diff_block("src/b.jl", "y = 1", "y = 3")]),
    TK.tool(kind = "search", title = "rg foo", id = "search-1", tool_name = "Grep",
            content = [TK.text_block("src/a.jl:1:hit one\nsrc/b.jl:2:hit two\nsrc/c.jl:3:hit three")]),
    TK.tool(kind = "other", title = "bt_julia_eval", id = "eval-1",
            tool_name = "mcp__btworker__bt_julia_eval",
            content = [TK.text_block("stdout:\nhi there"), TK.text_block("result:\n42")]),
    TK.tool(kind = "read", title = "src/a.py", id = "read-1", tool_name = "Read",
            content = [TK.text_block("```python\nprint('hi')\n```")]),
    TK.tool(kind = "move", title = "mv", id = "mv-1", tool_name = "Bash",
            content = [TK.text_block("renamed src/old.jl -> src/new.jl")]),
    TK.tool(kind = "fetch", title = "fetch", id = "fetch-1", tool_name = "WebFetch",
            content = [TK.text_block("Fetched https://example.com/docs/page ok")]),
    # A control MCP tool (bt_julia_interrupt): no output reveals WHAT it acted
    # on, so it must ship its `executed_preview` as an always-visible command
    # preview. `env_path` rides rawInput.
    TK.tool(kind = "other", title = "bt_julia_interrupt", id = "int-1",
            tool_name = "mcp__btworker__bt_julia_interrupt",
            raw_input = Dict{String,Any}("env_path" => "/tmp/proj-x"),
            content = [TK.text_block("interrupted")]),
    # Execute tool that stays live so the status pill is observable mid-flight.
    TK.tool(kind = "execute", title = "long task", id = "prog-1", open_status = "pending",
            complete = false),
    TK.delay(700), TK.tool_update("prog-1", status = "in_progress"),
    TK.delay(700), TK.tool_update("prog-1", status = "completed",
                                  content = [TK.text_block("done")]),
    TK.text("All tools shown."),
]

# Click the header of the .bt-tool-msg that owns the body for `id` (expands it).
expand(id) = """(() => { for (const m of document.querySelectorAll('.bt-tool-msg')) {
    if (m.querySelector('.bt-tool-body[data-tool-id="$(id)"]')) {
        const h = m.querySelector('.bt-tool-header'); if (h) h.click(); return true; } }
    return false; })()"""
# Text of `sel` inside the card that owns the body for `id`.
in_card(id, sel) = """(() => { for (const m of document.querySelectorAll('.bt-tool-msg')) {
    if (m.querySelector('.bt-tool-body[data-tool-id="$(id)"]')) {
        const e = m.querySelector('$(sel)'); return e ? e.textContent.trim() : null; } }
    return null; })()"""
body_has(id) = "document.querySelector('.bt-tool-body[data-tool-id=\"$(id)\"]')"

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents tool rendering (UI-only)" begin
        TK.new_chat(server; title = "Tools")
        TK.send_message(server, "show me the tools")

        @test TK.wait_for(server, "tool cards rendered",
            "document.querySelectorAll('.bt-tool-msg').length >= 6"; timeout = 12) == true

        @testset "header summaries derive from content" begin
            @test TK.eval_js(server, in_card("search-1", ".bt-tool-summary")) == "3 matches"
            @test TK.eval_js(server, in_card("mv-1", ".bt-tool-summary"))     == "old.jl → new.jl"
            @test TK.eval_js(server, in_card("fetch-1", ".bt-tool-summary"))  == "example.com"
        end

        @testset "execute tool walks pending -> in_progress -> completed" begin
            @test TK.wait_for(server, "completed status pill",
                """(() => { for (const m of document.querySelectorAll('.bt-tool-msg')) {
                    if (m.querySelector('.bt-tool-body[data-tool-id="prog-1"]')) {
                        const s = m.querySelector('.bt-tool-status');
                        return !!(s && s.classList.contains('bt-status-completed')); } }
                    return false; })()"""; timeout = 8) == true
        end

        @testset "multi-edit renders one diff block per file" begin
            TK.eval_js(server, expand("edit-multi"))
            @test TK.wait_for(server, "two diff blocks",
                "$(body_has("edit-multi")).querySelectorAll('.bt-diff-block').length === 2"; timeout = 8) == true
            @test TK.eval_js(server,
                "!!$(body_has("edit-multi")).querySelector('.bt-multi-diff')") == true
        end

        @testset "search renders one row per hit" begin
            TK.eval_js(server, expand("search-1"))
            @test TK.wait_for(server, "three search rows",
                "$(body_has("search-1")).querySelectorAll('.bt-search-row').length === 3"; timeout = 8) == true
            @test TK.eval_js(server,
                "$(body_has("search-1")).querySelector('.bt-search-row .bt-search-path').textContent") == "src/a.jl"
        end

        @testset "bt_julia_eval renders stdout/result sections" begin
            TK.eval_js(server, expand("eval-1"))
            @test TK.wait_for(server, "two eval sections",
                "$(body_has("eval-1")).querySelectorAll('.bt-eval-section').length === 2"; timeout = 8) == true
            @test TK.eval_js(server,
                "[...$(body_has("eval-1")).querySelectorAll('.bt-section-label')].map(l => l.textContent)") ==
                ["STDOUT", "RESULT"]
        end

        @testset "control MCP tool always shows what it executes (.bt-cmd-preview)" begin
            # bt_julia_interrupt renders no output that reveals its target, so
            # the header ships `executed_preview` → an always-visible command
            # preview (the same block bash uses). Dispatched on the message TYPE
            # (JuliaInterruptToolMsg), never a tool-name/kind string match.
            @test TK.wait_for(server, "interrupt action preview visible",
                """(() => { for (const m of document.querySelectorAll('.bt-tool-msg')) {
                    if (m.querySelector('.bt-tool-body[data-tool-id="int-1"]')) {
                        const p = m.querySelector('.bt-cmd-preview pre');
                        return !!p && p.textContent.indexOf('interrupt (SIGINT)') !== -1
                                  && p.textContent.indexOf('/tmp/proj-x') !== -1; } }
                    return false; })()"""; timeout = 8) == true
        end

        @testset "read renders the file body as code" begin
            TK.eval_js(server, expand("read-1"))
            @test TK.wait_for(server, "code body",
                "/print\\('hi'\\)/.test(($(body_has("read-1")) || {}).textContent || '')"; timeout = 8) == true
        end

        @testset "failure states: failed status pill + eval error section" begin
            # A second turn so these are the most-recent (rendered) messages.
            TK.send_message(server, "now trigger an error")
            @test TK.wait_for(server, "failed status pill",
                """(() => { for (const m of document.querySelectorAll('.bt-tool-msg')) {
                    if (m.querySelector('.bt-tool-body[data-tool-id="exec-fail"]')) {
                        const s = m.querySelector('.bt-tool-status');
                        return !!(s && s.classList.contains('bt-status-failed')); } }
                    return false; })()"""; timeout = 10) == true
            TK.eval_js(server, expand("eval-err"))
            @test TK.wait_for(server, "eval error section",
                "[...$(body_has("eval-err")).querySelectorAll('.bt-section-label')].some(l => l.textContent === 'ERROR')"; timeout = 8) == true
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
