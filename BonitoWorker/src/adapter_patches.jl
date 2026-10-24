# ── claude-agent-acp: thinking progress, until upstream ships it ────────────
# Recent models stream no thinking text, so during a long think the adapter sends
# nothing for minutes and a chat cannot tell a model that is thinking from a
# stalled one. Claude Code still emits an estimate of the tokens thought so far
# (its `thinking_tokens` messages, about every second); the adapter drops them,
# with a "Todo". This makes it forward the estimate as a `usage_update` carrying
# `_meta["_claude/thinkingTokens"]`: the same change as the pull request on
# claude-agent-acp (branch feat/thinking-token-usage). Remove this patch once a
# release has it.
#
# It patches whatever version is installed, on every sync, at one exact spot. A
# version where that spot is gone (upstream rewrote it, or shipped the feature)
# is left as it is, and its chats show no estimate. The inserted code uses the
# names of recent versions only where they exist, and a failure in it is logged
# by the adapter instead of ending the agent's message loop.

const THINKING_PATCH_MARK = "/* bonitoworker: thinking_tokens */"

"""
    patch_thinking_tokens(src) -> Union{String,Nothing}

`src`, claude-agent-acp's `dist/acp-agent.js`, with `thinking_tokens` forwarded
as a `usage_update`, or `nothing` when this version has not exactly the spot the
patch replaces, or not the names it needs.
"""
function patch_thinking_tokens(src::AbstractString)
    # The adapter's case for the messages it drops: `thinking_tokens` falls
    # through with `plugin_install` and `notification` to the "Todo" and its `break`.
    todo = r"\n([ \t]*)case \"thinking_tokens\":\n([ \t]*)(// Todo: process via status api:[^\n]*)\n[ \t]*break;"
    length(collect(eachmatch(todo, src))) == 1 || return nothing
    (occursin("const sendUpdate = ", src) && occursin("let lastAssistantTotalUsage", src)) ||
        return nothing
    m = match(todo, src)
    case, body = m.captures[1], m.captures[2]
    ind(n) = body * " "^(4n)
    lines = [
        "\n$(body)$(m.captures[3])",             # the other cases keep their Todo
        "$(body)break;",
        "$(case)case \"thinking_tokens\": { $(THINKING_PATCH_MARK)",
        "$(body)try {",
        "$(ind(1))if (session.cancelled && (typeof this.workEndReported !== \"function\" ||",
        "$(ind(1))    this.workEndReported(params.sessionId, session)))",
        "$(ind(2))break;",
        "$(ind(1))const estimated = message.estimated_tokens;",
        "$(ind(1))const before = lastAssistantTotalUsage ?? session.contextUsedTokens;",
        "$(ind(1))if (!Number.isFinite(estimated) || estimated <= 0 || before == null)",
        "$(ind(2))break;",
        "$(ind(1))const update = {",
        "$(ind(2))sessionUpdate: \"usage_update\",",
        "$(ind(2))used: before + estimated,",
        "$(ind(2))size: session.contextWindowSize,",
        "$(ind(2))_meta: { \"_claude/thinkingTokens\": estimated },",
        "$(ind(1))};",
        "$(ind(1))await sendUpdate({",
        "$(ind(2))sessionId: params.sessionId,",
        "$(ind(2))update: typeof attachUsageModel === \"function\" ? attachUsageModel(update) : update,",
        "$(ind(1))});",
        "$(body)} catch (e) {",
        "$(ind(1))this.logger?.error?.(`thinking_tokens: \${e}`);",
        "$(body)}",
        "$(body)break;",
        "$(case)}",
    ]
    return string(src[1:prevind(src, m.offset)], join(lines, "\n"),
                  src[nextind(src, m.offset + ncodeunits(m.match) - 1):end])
end

"""
    patch_thinking_tokens!(root = harness_root()) -> Symbol

Patch the installed claude-agent-acp under `root` (see `patch_thinking_tokens`):
`:patched` (now, or already), `:unchanged` (this version has no spot for it), or
`:absent` (not installed).
"""
function patch_thinking_tokens!(root::AbstractString = harness_root())
    file = joinpath(package_dir(root, "@agentclientprotocol/claude-agent-acp"), "dist", "acp-agent.js")
    isfile(file) || return :absent
    src = read(file, String)
    occursin(THINKING_PATCH_MARK, src) && return :patched
    patched = patch_thinking_tokens(src)
    patched === nothing && return :unchanged
    tmp = file * ".partial"
    write(tmp, patched)
    chmod(tmp, filemode(file) & 0o777)
    mv(tmp, file; force = true)
    return :patched
end

# codex-acp's steering fallback starts a new turn without reporting its end on
# ACP v1. Until upstream offers active-only steering, add that optional guard
# at its existing fallback. The original prompt still owns turn completion.
const ACTIVE_STEERING_PATCH_MARK = "/* bonitoworker: active-only steering */"

function patch_active_steering(src::AbstractString)
    capability = r"steering:\s*\{\s*supported:\s*true\s*\}"
    parser = r"(?s)(parseSessionSteerParams\(params\)\s*\{.*?return\s*\{\s*sessionId,\s*prompt)(\s*\};\s*\})"
    fallback = "return await this.startNewTurnFromSteering(params);"
    all(pattern -> length(collect(eachmatch(pattern, src))) == 1, (capability, parser)) || return nothing
    count(fallback, src) == 1 || return nothing
    parsed = match(parser, src)
    patched = replace(src, parsed.match => parsed.captures[1] *
        ", activeOnly: params.activeOnly === true" * parsed.captures[2]; count = 1)
    patched = replace(patched, capability => "steering: { supported: true, activeOnly: true }"; count = 1)
    return replace(patched, fallback =>
        "$ACTIVE_STEERING_PATCH_MARK\n    if (params.activeOnly === true) return { outcome: \"notInjected\" };\n    $fallback";
        count = 1)
end

function patch_active_steering!(root::AbstractString = harness_root())
    file = joinpath(package_dir(root, "@agentclientprotocol/codex-acp"), "dist", "index.js")
    isfile(file) || return :absent
    src = read(file, String)
    occursin(ACTIVE_STEERING_PATCH_MARK, src) && return :patched
    patched = patch_active_steering(src)
    patched === nothing && return :unchanged
    tmp = file * ".partial"
    write(tmp, patched)
    # index.js is also npm's executable entry point; replacing it must keep +x.
    chmod(tmp, filemode(file) & 0o777)
    mv(tmp, file; force = true)
    return :patched
end
