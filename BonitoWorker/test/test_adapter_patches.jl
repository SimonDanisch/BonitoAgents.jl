# The thinking-progress patch on claude-agent-acp (adapter_patches.jl). It goes in
# at the one spot where the adapter drops `thinking_tokens`, once, and leaves a
# version without that spot alone. The fixture is a runnable module shaped like
# the adapter's message loop (the same in 0.80 to 0.91), without the names only
# recent versions have (`attachUsageModel`, `workEndReported`), which the patch
# must do without. With node on PATH the patched module runs.
using Test, BonitoWorker
import JSON
const BW = BonitoWorker

const ADAPTER_FIXTURE = raw"""
const sent = [];
class Agent {
    logger = { error: (m) => sent.push({ error: m }) };
    async prompt(session, messages, start) {
        let lastAssistantTotalUsage = start;
        const params = { sessionId: "s1" };
        const sendUpdate = async (notification) => { sent.push(notification); };
        for (const message of messages) {
            switch (message.type) {
                case "system":
                    switch (message.subtype) {
                        case "plugin_install":
                        case "notification":
                        case "thinking_tokens":
                            // Todo: process via status api: https://docs.claude.com/en/docs/claude-code/hooks#hook-output
                            break;
                        case "api_retry": {
                            sent.push({ retry: true });
                            break;
                        }
                    }
                    break;
            }
        }
    }
}
const thinking = (n) => ({ type: "system", subtype: "thinking_tokens", estimated_tokens: n });
const agent = new Agent();
const window = { cancelled: false, contextWindowSize: 200000 };
// Context known from the response's start: the estimate goes on top of it.
await agent.prompt(window, [thinking(150), { type: "system", subtype: "notification" },
                            { type: "system", subtype: "api_retry" }], 1300);
// Neither known: nothing to put the estimate on.
await agent.prompt(window, [thinking(150)], null);
// No usable estimate.
await agent.prompt(window, [thinking(0)], 1300);
// Cancelled: nothing.
await agent.prompt({ ...window, cancelled: true }, [thinking(150)], 1300);
console.log(JSON.stringify(sent));
"""

@testset "claude-agent-acp: thinking progress patch" begin
    fixture = ADAPTER_FIXTURE
    patched = BW.patch_thinking_tokens(fixture)
    @test patched !== nothing
    @test count(BW.THINKING_PATCH_MARK, patched) == 1
    # The cases that fell through with it keep their Todo and `break`.
    @test occursin("case \"notification\":\n", patched)
    @test occursin("// Todo: process via status api", patched)
    @test BW.patch_thinking_tokens(patched) === nothing        # its spot is gone now

    # A version without the spot, or without the names, is left alone.
    @test BW.patch_thinking_tokens(replace(fixture, "case \"thinking_tokens\":\n" => "")) === nothing
    @test BW.patch_thinking_tokens(replace(fixture, "let lastAssistantTotalUsage" => "let usage")) === nothing

    @testset "on an install: once, and never again" begin
        root = mktempdir()
        dist = mkpath(joinpath(root, "npm", "node_modules", "@agentclientprotocol", "claude-agent-acp", "dist"))
        @test BW.patch_thinking_tokens!(root) == :absent
        write(joinpath(dist, "acp-agent.js"), fixture)
        @test BW.patch_thinking_tokens!(root) == :patched
        once = read(joinpath(dist, "acp-agent.js"), String)
        @test BW.patch_thinking_tokens!(root) == :patched
        @test read(joinpath(dist, "acp-agent.js"), String) == once
        write(joinpath(dist, "acp-agent.js"), "export const unrelated = 1;\n")
        @test BW.patch_thinking_tokens!(root) == :unchanged
    end

    node = Sys.which("node")
    if node === nothing
        @info "node is not on PATH: the patched adapter code is checked as text only"
    else
        @testset "the patched code runs" begin
            file = joinpath(mktempdir(), "adapter.mjs")
            write(file, patched)
            sent = JSON.parse(read(`$node $file`, String))
            @test length(sent) == 2
            @test sent[1]["sessionId"] == "s1"
            u = sent[1]["update"]
            @test u["sessionUpdate"] == "usage_update"
            @test u["used"] == 1450 && u["size"] == 200000
            @test u["_meta"]["_claude/thinkingTokens"] == 150
            @test sent[2] == Dict("retry" => true)          # the next case still runs
            @test !any(haskey(s, "error") for s in sent)   # no failure was logged
        end
    end
end
