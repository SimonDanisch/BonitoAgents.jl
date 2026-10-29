# The thinking-progress patch on claude-agent-acp (adapter_patches.jl). It goes in
# at the one spot where the adapter drops `thinking_tokens`, once, and leaves a
# version without that spot alone. The fixture is a runnable module shaped like
# the adapter's message loop (the same in 0.80 to 0.91), without the names only
# recent versions have (`attachUsageModel`, `workEndReported`), which the patch
# must do without. With node on PATH the patched module runs.
using Test, BonitoWorker
import JSON
const BW = BonitoWorker

const RECEIPT_FIXTURE = raw"""
class Agent {
  sent = [];
  logger = { error: (...args) => { throw new Error(args.join(" ")); } };
  client = { extNotification: async (method, params) => { this.sent.push({method, params}); } };
  initialize() { return { agentCapabilities: { _meta: { claudeCode: { promptQueueing: true } } }, _meta: { steering: { supported: true } } }; }
  async steer(params) {
    if (params._meta?.steering?.idleBehavior === "promptRequired") return {outcome:"promptRequired"};
  }
  async prompt(params) {
    let events;
    const outcome = new Promise((resolve, reject) => {
      events = { inserted() {}, ended: resolve, failed: reject };
    });
    if (params.consume) events.inserted("sdk-uuid");
    events.ended({stopReason: params.consume ? "end_turn" : "cancelled"});
    return outcome;
  }
}
const agent = new Agent();
await agent.prompt({sessionId:"s", _meta:{bonitoPromptId:"never-consumed"}, consume:false});
await agent.prompt({sessionId:"s", _meta:{bonitoPromptId:"received"}, consume:true});
await agent.prompt({sessionId:"s", consume:true}); // ordinary ACP clients need no extension
console.log(JSON.stringify({caps:agent.initialize(), sent:agent.sent}));
"""

@testset "claude-agent-acp: prompt receipts" begin
    patched = BW.patch_prompt_receipts(RECEIPT_FIXTURE)
    @test patched !== nothing
    @test BW.patch_prompt_receipts(patched) === nothing
    @test BW.patch_prompt_receipts(replace(RECEIPT_FIXTURE, "inserted() {}"=>"inserted() { changed(); }")) === nothing
    mktempdir() do root
        @test BW.patch_prompt_receipts!(root) === :absent
        file = joinpath(root, "npm", "node_modules", "@agentclientprotocol", "claude-agent-acp", "dist", "acp-agent.js")
        mkpath(dirname(file))
        write(file, RECEIPT_FIXTURE)
        Sys.iswindows() || chmod(file, 0o751)
        @test BW.patch_prompt_receipts!(root) === :patched
        @test BW.patch_prompt_receipts!(root) === :patched
        Sys.iswindows() || @test filemode(file) & 0o777 == 0o751
        node = Sys.which("node")
        if node !== nothing
            result = JSON.parse(read(`$node --input-type=module -e $(read(file,String))`, String))
            @test result["caps"]["agentCapabilities"]["_meta"]["promptReceipts"] === true
            @test result["caps"]["_meta"]["steering"]["idleBehavior"] == "promptRequired"
            @test only(result["sent"])["method"] == "_bonito/prompt_received"
            @test only(result["sent"])["params"] == Dict("sessionId"=>"s", "messageId"=>"received")
        end
    end
end

const STEERING_FIXTURE = raw"""
class Agent {
  started = 0;
  initialize() { return { steering: { supported: true } }; }
  parseSessionSteerParams(params) {
    const sessionId = params["sessionId"];
    const prompt = params["prompt"];
    return { sessionId, prompt };
  }
  async performSteeringRequest(params) {
    if (this.active && this.injected) return { outcome: "injected" };
    return await this.startNewTurnFromSteering(params);
  }
  async startNewTurnFromSteering(params) {
    this.started++;
    return { outcome: "startedNewTurn" };
  }
}
const agent = new Agent();
const request = agent.parseSessionSteerParams({ sessionId: "s", prompt: [], activeOnly: true });
const outcomes = [];
agent.active = true; agent.injected = true;
outcomes.push(await agent.performSteeringRequest(request));
agent.active = false;
outcomes.push(await agent.performSteeringRequest(request));
agent.active = true; agent.injected = false; // turn ended during injection
outcomes.push(await agent.performSteeringRequest(request));
console.log(JSON.stringify({ capabilities: agent.initialize(), outcomes, started: agent.started }));
"""

@testset "codex-acp: active-only steering" begin
    patched = BW.patch_active_steering(STEERING_FIXTURE)
    @test patched !== nothing
    @test count(BW.ACTIVE_STEERING_PATCH_MARK, patched) == 1
    @test BW.patch_active_steering(patched) === nothing
    @test BW.patch_active_steering(replace(STEERING_FIXTURE, "parseSessionSteerParams" => "parseOther")) === nothing
    mktempdir() do root
        @test BW.patch_active_steering!(root) === :absent
        file = joinpath(root, "npm", "node_modules", "@agentclientprotocol", "codex-acp", "dist", "index.js")
        # Reproduce npm's actual launch path, rather than running the source
        # through `node -e` (which cannot detect a missing executable bit).
        source = "#!/usr/bin/env node\n" * STEERING_FIXTURE
        mkpath(dirname(file)); write(file, source)
        package = dirname(dirname(file))
        write(joinpath(package, "package.json"), JSON.json(Dict("type" => "module",
            "bin" => Dict("codex-acp" => "dist/index.js"))))
        Sys.iswindows() || chmod(file, 0o751)
        @test BW.patch_active_steering!(root) === :patched
        Sys.iswindows() || @test filemode(file) & 0o777 == 0o751
        @test BW.patch_active_steering!(root) === :patched
        Sys.iswindows() || @test filemode(file) & 0o777 == 0o751
        @test count(BW.ACTIVE_STEERING_PATCH_MARK, read(file, String)) == 1
        node = Sys.which("node")
        if node !== nothing
            result = JSON.parse(read(`$node --input-type=module -e $(read(file, String))`, String))
            @test result["capabilities"]["steering"]["activeOnly"] === true
            @test [x["outcome"] for x in result["outcomes"]] == ["injected", "notInjected", "notInjected"]
            @test result["started"] == 0
            if Sys.isunix()
                launcher = joinpath(root, "npm", "node_modules", ".bin", "codex-acp")
                mkpath(dirname(launcher))
                symlink(relpath(file, dirname(launcher)), launcher)
                command() = addenv(Cmd([launcher]), "PATH" => dirname(node) * ":" * get(ENV, "PATH", ""))
                @test JSON.parse(read(command(), String))["started"] == 0
                # Already-patched installs still need repair: skipping npm and
                # skipping the JS patch must not leave their launcher broken.
                chmod(file, 0o644)
                @test BW.patch_active_steering!(root) === :patched
                @test_throws Base.IOError read(command(), String)
                BW.repair_package_bins!(root, "@agentclientprotocol/codex-acp")
                @test filemode(file) & 0o777 == 0o755
                @test JSON.parse(read(command(), String))["started"] == 0
                BW.repair_package_bins!(root, "@agentclientprotocol/codex-acp")
                @test filemode(file) & 0o777 == 0o755
            end
        end
    end
end

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
        Sys.iswindows() || chmod(joinpath(dist, "acp-agent.js"), 0o640)
        @test BW.patch_thinking_tokens!(root) == :patched
        Sys.iswindows() || @test filemode(joinpath(dist, "acp-agent.js")) & 0o777 == 0o640
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
