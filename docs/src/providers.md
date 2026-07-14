# Agent Providers

Agents plug in as **provider descriptors**
([`AgentProviders`](https://github.com/SimonDanisch/BonitoAgents.jl/tree/main/AgentProviders)):
a name, the binary and arguments to spawn, and provider-specific environment.
The worker resolves and spawns the binary, so `Sys.which` runs on the machine
that owns it, and the same descriptor list drives the provider dropdown in the
chat header, so server and worker can never disagree about what is available.

Everything speaks the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP): one agent
process per project, spawned on the first message and reaped when idle.

## Claude Code

The default provider. Prerequisites on each worker machine:

```bash
npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp
claude   # log in once
```

Node 20+ is required (the ACP adapter uses import attributes). The worker
install one-liner checks all of this up front and tells you exactly what is
missing.

Because Claude Code keeps its session files on the worker, **Discover** can
list every folder you have ever used `claude` in and import it as a project,
including the conversation history, which the dashboard reconciles into its
transcript. Resuming a session continues it with the same context, now with
the dashboard's rendering, file tree and live-app tooling on top.

## MiMo and OpenCode

Descriptors for [MiMo](https://github.com/XiaomiMiMo) and
[OpenCode](https://github.com/sst/opencode) ship in the registry (both expose
ACP under an `acp` subcommand). Select them per chat from the provider
dropdown; switching providers mid-project starts the next turn under the new
agent.

## The mock agent

`MockAgent` is a deterministic, scriptable ACP agent used by the test suite
and the recorded
[walkthrough](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough.jl).
A Julia function maps each prompt to a list of protocol events (text chunks,
tool calls with diffs, live-app pushes, delays for pacing). It only appears in
the dropdown when `BT_ENABLE_MOCK_AGENT` is set, which is handy for demos and
UI work without burning tokens.

## Adding your own

A provider is a small struct: binary, args, env, capability flags. If your
tool speaks ACP (or you can wrap it so it does), a descriptor is all it takes
for it to show up in the dropdown on every worker that has the binary.
