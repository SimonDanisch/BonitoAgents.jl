# Session config: resolved/labelled pills + a home "Defaults" control

Status: approved design (2026-07-14). Next: implementation plan.

## Problem

Two related complaints about the session-config pills (model / permission mode /
reasoning effort) rendered in the chat header:

1. **The pills show the bare word "default", which is uninformative.** The model
   pill reads "Default (recommended)" instead of the model actually running; a
   fresh chat's permission-mode pill reads "default". With two pills both reading
   "default" you get `[default] [default]` — you can't tell what each is about.
2. **The default model/mode/effort are hardcoded and not user-settable.** There
   is no way to say "all my chats should default to bypassPermissions / Opus"
   from the dashboard — you re-pick per chat every time.

## Ground truth (real claude-agent-acp, captured live via the relay path)

A real `session/new` + first turn reports (`ChatModel.session_meta`):

- **mode** `currentValue="default"`, choices: `auto`, `default` ("Standard
  behavior, prompts for dangerous operations"), `acceptEdits`, `plan`, `dontAsk`,
  `bypassPermissions`.
- **model** `currentValue="default"`, choices: `default` (name "Default
  (recommended)", **description "Opus 4.8 with 1M context · Best for everyday,
  complex tasks"**), `opus[1m]`, `claude-fable-5[1m]`, `sonnet`, `haiku`.
- **effort** `currentValue="xhigh"`, choices `default/low/medium/high/xhigh/max`.

Key facts this establishes:
- The resolved model **is** available in-protocol: the `default` choice's
  `description` carries "Opus 4.8 with 1M context". `ACP.pill_label` already
  extracts that headline (first segment before "·") → "Opus 4.8 with 1M context".
  The bug is that the **interactive** pill (`config_select_pill`) shows the raw
  choice `name` ("Default (recommended)") instead of that resolved label.
- Config options land on `session_meta` only after `apply_session_config!` runs
  (turn start), not at bare `session/new`. Not changed by this work.
- "default" for **mode** is a genuine named mode (no hidden value); for **model**
  it is an alias whose real value lives in the description.

Config options are consumed cross-agent via `ACP.parse_config_options` (the
`modes`/`models`/`configOptions` blocks), so all logic here stays agent-agnostic
(Claude Code, OpenCode, …): we resolve from `currentValue` + `choices` +
`description`, never a hardcoded model name.

## Design

### Part A — pills show a category label + the resolved value

Each header pill renders `"<label>: <resolved value>"`:

- **label** — a friendly category name: `model`, `permissions` (for the `mode`
  category — the user's word), `effort`. Rendered as a small prefix span *outside*
  the `<select>` (a native select can't show a prefix only on the collapsed value,
  so the prefix is a sibling label, not baked into each option).
- **resolved value** — the current choice's display name, resolved the same way
  `pill_label` already does: for a model whose current choice is an alias
  ("default"), use the description headline ("Opus 4.8 with 1M context"); for
  everything else, the plain choice name. `config_select_pill` is changed to label
  its options (and thus the collapsed display) with this resolved name instead of
  the raw `name`.
- **Drop "(recommended)"** from the model `default` choice's displayed name (it's
  redundant once the real model shows). Strip a trailing "(recommended)" when
  building the resolved label.

Net effect: `[permissions: default] [model: Opus 4.8 with 1M context] [effort: xhigh]`.
"default" stays a selectable choice; it just never displays as the bare word.

Scope: `config_select_pill`, `header_pill`, and `ACP.pill_label` (extend to strip
"(recommended)"). No change to the config data model or assertion path.

### Part B — home "Defaults" control

A "Defaults" control on the dashboard home (reusing the pill picker component)
that sets a **server-wide** default model / permission mode / effort.

- **Persistence:** a new `state_dir/settings.json` (sibling of `projects.json`),
  holding `{"default_config": {"model":…, "mode":…, "effort":…}}`. Loaded in
  `ServerState(...)`; saved via a `save_settings!(state)` mirroring
  `save_projects!` (snapshot + atomic write under `state.lock`). A
  `default_session_config :: Dict{String,String}` field on `ServerState` holds the
  live value.
- **Effect:** `effective_session_config(model)` starts from
  `state.default_session_config` (falling back to the current hardcoded
  `DEFAULT_PERMISSION_MODE` / `DEFAULT_EFFORT` for keys the user hasn't set)
  instead of the hardcoded constants directly; the project's `desired_config`
  still overlays on top (per-chat picks win). Model gains a global default here
  (previously none).
- **UI:** the home view renders the three selects bound to
  `state.default_session_config`; changing one persists via `save_settings!` and
  notifies. Applies to future bring-ups (and the next turn's `apply_session_config!`);
  it does not force-reassert onto every already-live session.
- **Available choices for the home selects:** the home has no live session, so it
  has no `availableModels`/`availableModes`. Source the choice lists from the most
  recent `session_meta` seen from any of this server's sessions (cache the last
  non-empty config options on `ServerState`); if none seen yet, fall back to a
  minimal built-in list (the known claude modes/efforts) so the control still
  renders on a cold server. This keeps it cross-agent: once any agent has reported
  its options, the home uses them.

## Data flow

Agent `session/new`/turn → `parse_config_options` → `session_meta` (per chat) →
header pills (Part A shows resolved+labelled). Home Defaults select → `pick`
observable → `save_settings!` + `state.default_session_config` → next
`effective_session_config` → `apply_session_config!` asserts on bring-up. Server
also caches the last-seen config-option choice list for the home selects.

## Error handling

- Missing/corrupt `settings.json` → treat as "no defaults set" (fall back to
  hardcoded), like the tolerant `projects.json` load. Never crash bring-up.
- An agent that reports no `models`/config options → pills simply don't render
  (unchanged); home Defaults uses the built-in fallback list.
- Resolution never fabricates: if a choice is an alias with no description, show
  the plain name (today's behaviour) rather than invent a model.

## Testing

- **Unit (`test_session_config.jl`, extended):** update the fixture to the current
  real shape; assert the resolved+labelled pill text ("model: Opus 4.8 with 1M
  context", "permissions: default", "effort: xhigh"), the "(recommended)" strip,
  and that `config_select_pill`'s collapsed label uses the resolved name.
- **Unit (settings):** `save_settings!`/load round-trip; `effective_session_config`
  overlay order (hardcoded < global default < per-chat).
- **e2e:** a home-Defaults test — set a default mode, open a fresh chat, assert the
  permission-mode pill reflects it; a per-chat pick still overrides.
- Full BonitoAgents suite stays green.

## Out of scope

- Re-asserting new defaults onto already-live sessions (future turn picks it up).
- Any change to the one relay transport / the config-assertion mechanism.
