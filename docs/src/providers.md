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

## Session config

Each chat's header carries the agent's own settings as pills: the **permission
mode** (how much it may do before asking), the **effort** or thinking level, and
whatever else the provider reports, such as the model. The options come over ACP
from the running agent, so the list always matches the provider. Change them for
one chat in its header, or set fleet-wide starting points in the dashboard's
*Session defaults* bar, which every new chat inherits.

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

## MiMo, OpenCode and Kimi Code

Descriptors for [MiMo](https://github.com/XiaomiMiMo),
[OpenCode](https://github.com/sst/opencode) and
[Kimi Code](https://github.com/MoonshotAI) ship in the registry (all three
expose ACP under an `acp` subcommand). Select them per chat from the provider
dropdown; switching providers mid-project starts the next turn under the new
agent.

Kimi Code additionally advertises ACP `session/load`, but its sessions are not
resumed across a server restart yet: a project stores its session id without
the provider that created it, so restoring one under a different provider would
fail. Only Claude Code resumes today.

### Tool cards across providers

`bt_julia_eval` and the other `btworker` tools render as the same typed cards
whichever agent calls them, even though ACP leaves it up to the agent how to
identify an MCP tool. Claude Code states the name in a `_meta` extension, Kimi
puts it in the ACP title as `mcp__btworker__bt_julia_eval`, OpenCode as
`btworker_bt_julia_eval`, and Kimi streams the arguments as content text rather
than `rawInput`. All of these are normalised back to `(server, tool)` plus the
real arguments, so the code preview, output pane and live embeds behave the
same everywhere. A tool we don't recognise is left untouched and shows the
generic card.

## The mock agent

`MockAgent` is a deterministic, scriptable ACP agent used by the test suite
and the recorded
[`bt_julia_eval` walkthrough](https://github.com/SimonDanisch/BonitoAgents.jl/blob/main/examples/walkthrough_mock.jl).
A Julia function maps each prompt to a list of protocol events (text chunks,
tool calls with diffs, live-app pushes, delays for pacing). It only appears in
the dropdown when `BT_ENABLE_MOCK_AGENT` is set, which is handy for demos and
UI work without burning tokens.

## Adding your own

A provider is a small struct: binary, args, env, capability flags. If your
tool speaks ACP (or you can wrap it so it does), a descriptor is all it takes
for it to show up in the dropdown on every worker that has the binary.
