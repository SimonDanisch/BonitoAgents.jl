@testitem "unit:session_config" tags = [:unit] begin

# Coverage for the session-config work (#49). Runs headless — no MockTransport
# (that was removed with SubprocessTransport; the old top-level
# `test_session_config.jl` still references it and is part of the #26 rewrite) and
# no live agent: a never-started `WorkerAgent` backs the one `ChatModel` we need
# (same pattern as busy_test / between_turn_test).
#
#  Part A — header pills show a CATEGORY label + the RESOLVED value: the model
#           "default" alias resolves to the real model (from its description
#           headline) and a trailing "(recommended)" is stripped; `mode` reads
#           "permissions", `thought_level` reads "effort".
#  Part B — a server-wide "Defaults" control: `default_session_config` persisted to
#           settings.json, choice lists sourced from the last-seen config options
#           (`cache_config_options!` / `defaults_options`), overlaid UNDER each
#           chat's own picks in `effective_session_config`.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

mkopt(id, name, cat, cur, choices) = ACP.ConfigOption(id, name, nothing, cat, cur,
    [ACP.ConfigOptionChoice(v, n, d) for (v, n, d) in choices])

# Ground truth captured live from claude-agent-acp: model "default" is an alias
# whose description carries the real model; effort's current is "xhigh".
real_model() = mkopt("model", "Model", "model", "default",
    [("default", "Default (recommended)", "Opus 4.8 with 1M context · Best for everyday, complex tasks"),
     ("opus[1m]", "Opus", "Opus 4.8"),
     ("sonnet", "Sonnet", "Claude Sonnet 4.6")])
real_mode() = mkopt("mode", "Mode", "mode", "default",
    [("auto", "Auto", nothing),
     ("default", "Default", "Standard behavior, prompts for dangerous operations"),
     ("acceptEdits", "Accept Edits", nothing), ("plan", "Plan Mode", nothing),
     ("bypassPermissions", "Bypass Permissions", nothing)])
real_effort() = mkopt("effort", "Effort", "thought_level", "xhigh",
    [("default", "Default", nothing), ("low", "Low", nothing), ("high", "High", nothing),
     ("xhigh", "Xhigh", nothing), ("max", "Max", nothing)])

# ── Part A: resolved + labelled pills ────────────────────────────────────────
@testset "choice_label / pill_label resolve the model alias + strip (recommended)" begin
    m = real_model()
    dflt = m.choices[1]
    @test ACP.choice_label(m, dflt) == "Opus 4.8 with 1M context"    # alias → real model
    @test !occursin("recommended", ACP.choice_label(m, dflt))         # "(recommended)" stripped
    @test ACP.choice_label(m, m.choices[3]) == "Sonnet"               # explicit model → plain name
    @test ACP.pill_label(m) == "Opus 4.8 with 1M context"             # current IS the alias
    # Non-model options show their plain choice name (descriptions there explain,
    # they aren't the value).
    @test ACP.pill_label(real_mode()) == "Default"
    @test ACP.pill_label(real_effort()) == "Xhigh"
    # An explicit (non-alias) model selection shows its plain name.
    switched = mkopt("model", "Model", "model", "sonnet",
                     [(c.value, c.name, c.description) for c in m.choices])
    @test ACP.pill_label(switched) == "Sonnet"
end

@testset "pill_category_label maps categories to the user's words" begin
    @test BT.pill_category_label(real_model())  == "model"
    @test BT.pill_category_label(real_mode())   == "permissions"      # "mode" → the user's word
    @test BT.pill_category_label(real_effort()) == "effort"           # thought_level → effort
    # Unknown category degrades to the option name, lower-cased.
    @test BT.pill_category_label(mkopt("x", "Custom", "weird", "a", [("a", "A", nothing)])) == "custom"
end

@testset "header_pill (read-only): category prefix + resolved value" begin
    mp = string(BT.header_pill(real_model()))
    @test occursin("model:", mp) && occursin("Opus 4.8 with 1M context", mp)
    @test occursin("bt-header-meta-item", mp)
    md = string(BT.header_pill(real_mode()))
    @test occursin("permissions:", md) && occursin("Default", md)
    @test !occursin("mode:", md)                                     # the category reads "permissions", not "mode"
    @test occursin("effort:", string(BT.header_pill(real_effort())))
    @test occursin("whatever", string(BT.header_pill("whatever")))    # unknown kind degrades to its string
end

@testset "config_select_pill: resolved <option> label + category prefix" begin
    pick = BT.Bonito.Observable{Any}(["", ""])
    s = string(BT.config_select_pill(real_model(), pick))
    @test occursin("<select", s) && occursin("bt-header-meta-pick", s)
    @test occursin("model:", s)
    @test occursin(">Opus 4.8 with 1M context</option>", s)          # resolved, collapsed label
    @test !occursin(">Default (recommended)</option>", s)           # "(recommended)" gone from the option text
    @test occursin(">Sonnet</option>", s)
    # The mode pill in the Defaults bar is lower-cased → "permissions: default".
    sm = string(BT.config_select_pill(real_mode(), pick; lc = true))
    @test occursin("permissions:", sm)
    @test occursin(">default</option>", sm)                          # lower-cased label
end

# ── Part B: home "Defaults" + settings persistence ───────────────────────────
@testset "defaults_options: cold fallback, warm uses reported options" begin
    # Cold server (nothing reported yet): mode + effort from the built-in fallback,
    # NO model (a model needs a live agent to enumerate).
    cold = BT.defaults_options(Any[])
    @test [o.id for o in cold] == ["mode", "effort"]
    # Warm (a model was reported): model first, then mode + effort (header order).
    warm = BT.defaults_options(Any[real_model()])
    @test [o.id for o in warm] == ["model", "mode", "effort"]
    # A reported option REPLACES the fallback (the agent's own choices win).
    warm2 = BT.defaults_options(Any[real_mode()])
    reported_mode = warm2[findfirst(o -> o.id == "mode", warm2)]
    @test any(c -> c.value == "auto", reported_mode.choices)         # "auto" only exists in the reported option
end

@testset "save_settings! / load_settings! round-trip + tolerant load" begin
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), worker_secret = "x")
    @test st.default_session_config[] == Dict{String,String}()       # empty on a fresh server
    lock(st.lock) do
        st.default_session_config[] = Dict("mode" => "bypassPermissions",
                                           "model" => "sonnet", "effort" => "high")
    end
    BT.save_settings!(st)
    @test isfile(BT.settings_file(st))
    # A fresh state over the SAME dir reloads the persisted defaults.
    st2 = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), worker_secret = "x")
    @test st2.default_session_config[] ==
          Dict("mode" => "bypassPermissions", "model" => "sonnet", "effort" => "high")
    # Corrupt settings.json → treated as "no defaults set", never throws.
    write(BT.settings_file(st), "{ this is not valid json")
    st3 = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), worker_secret = "x")
    @test st3.default_session_config[] == Dict{String,String}()
end

@testset "effective_session_config: hardcoded < global default < per-chat" begin
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    m0 = BT.ChatModel(st, mktempdir(); agent = BT.WorkerAgent(st, "w1", "/p"))   # no project
    # No defaults, no project → the hardcoded base only.
    @test BT.effective_session_config(m0) ==
          Dict("mode" => BT.DEFAULT_PERMISSION_MODE, "effort" => BT.DEFAULT_EFFORT)
    # Global default overlays the base (and can ADD a model, which the base lacks).
    lock(st.lock) do
        st.default_session_config[] = Dict("mode" => "bypassPermissions", "model" => "sonnet")
    end
    c1 = BT.effective_session_config(m0)
    @test c1["mode"]   == "bypassPermissions"        # global beats the hardcoded "default"
    @test c1["model"]  == "sonnet"                   # global adds a model
    @test c1["effort"] == BT.DEFAULT_EFFORT           # a key the user didn't set keeps the base
    # A per-chat pick (project desired_config) beats the global default.
    pid = "p1"
    proj = BT.ProjectInfo(pid, "proj", "w1", mktempdir(), "/w", BT.now(BT.UTC))
    proj.desired_config["mode"] = "plan"
    lock(st.lock) do; st.projects[] = Dict(pid => proj); end
    m1 = BT.ChatModel(st, mktempdir(); project_id = pid, agent = BT.WorkerAgent(st, "w1", "/p"))
    c2 = BT.effective_session_config(m1)
    @test c2["mode"]  == "plan"        # per-chat wins over the global "bypassPermissions"
    @test c2["model"] == "sonnet"      # the global still applies where the chat is silent
end

@testset "cache_config_options! stores only ConfigOptions, keeps the last good set" begin
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    m = BT.ChatModel(st, mktempdir(); agent = BT.WorkerAgent(st, "w1", "/p"))
    @test st.last_config_options[] == Any[]
    BT.cache_config_options!(m, Any[real_model(), real_mode(), "non-config-kind"])
    @test [o.id for o in st.last_config_options[] if o isa ACP.ConfigOption] == ["model", "mode"]
    # An optionless report does NOT clobber the last good cache (home stays usable).
    BT.cache_config_options!(m, Any["only-non-config"])
    @test [o.id for o in st.last_config_options[] if o isa ACP.ConfigOption] == ["model", "mode"]
end

# ── Raw-result parsing (migrated from the retired test_session_config.jl, which
# drove the live ChatModel via the removed MockTransport). These are pure — they
# exercise the typed view over the agent's raw session/new result + wire updates.
# The live config-flow (bring-up asserts desired config, mid-turn updates patch
# the header, picking a model fires set_config_option) is covered by the e2e
# dev_server tier, which drives the real WorkerTransport instead of a fake one.
config_options_json() = [
    Dict("id"=>"mode", "name"=>"Mode", "description"=>"Session permission mode",
         "category"=>"mode", "type"=>"select", "currentValue"=>"default",
         "options"=>[
            Dict("value"=>"default", "name"=>"Default",
                 "description"=>"Standard behavior, prompts for dangerous operations"),
            Dict("value"=>"bypassPermissions", "name"=>"Bypass Permissions",
                 "description"=>"Bypass all permission checks")]),
    Dict("id"=>"model", "name"=>"Model", "description"=>"AI model to use",
         "category"=>"model", "type"=>"select", "currentValue"=>"default",
         "options"=>[
            Dict("value"=>"default", "name"=>"Default (recommended)",
                 "description"=>"Opus 4.8 with 1M context · Best for everyday, complex tasks"),
            Dict("value"=>"sonnet", "name"=>"Sonnet",
                 "description"=>"Sonnet 4.6 · Best for everyday tasks")]),
    Dict("id"=>"effort", "name"=>"Effort",
         "description"=>"Available effort levels for this model",
         "category"=>"thought_level", "type"=>"select", "currentValue"=>"default",
         "options"=>[Dict("value"=>"default", "name"=>"Default"),
                     Dict("value"=>"high", "name"=>"High")]),
]
session_result() = Dict{String,Any}(
    "sessionId" => "s",
    "models" => Dict("currentModelId"=>"default", "availableModels"=>[
        Dict("modelId"=>"default", "name"=>"Default (recommended)",
             "description"=>"Opus 4.8 with 1M context · Best for everyday, complex tasks")]),
    "modes" => Dict("currentModeId"=>"default", "availableModes"=>[
        Dict("id"=>"default", "name"=>"Default",
             "description"=>"Standard behavior, prompts for dangerous operations")]),
    "configOptions" => config_options_json(),
)
option_by_id(opts, id) = opts[findfirst(o -> o.id == id, opts)]

@testset "parse_config_options: typed view over the raw result" begin
    opts = ACP.parse_config_options(session_result())
    @test [o.id for o in opts] == ["mode", "model", "effort"]
    model = option_by_id(opts, "model")
    @test model.current_value == "default"
    @test model.category == "model"
    @test length(model.choices) == 2
    # MODEL "default" is an alias → resolved model, not the word "Default".
    @test ACP.pill_label(model) == "Opus 4.8 with 1M context"
    # Everything else shows its plain choice name.
    @test ACP.pill_label(option_by_id(opts, "mode")) == "Default"
    @test ACP.pill_label(option_by_id(opts, "effort")) == "Default"
    # An explicit (non-alias) selection shows its proper choice name.
    mode = option_by_id(opts, "mode")
    switched = ACP.ConfigOption(mode.id, mode.name, mode.description,
        mode.category, "bypassPermissions", mode.choices)
    @test ACP.pill_label(switched) == "Bypass Permissions"
    # Unresolvable current value → raw value, not an error.
    ghost = ACP.ConfigOption("x", "X", nothing, nothing, "gone", mode.choices)
    @test ACP.pill_label(ghost) == "gone"
end

@testset "parse_config_options: fallback synthesis from modes/models blocks" begin
    r = session_result()
    delete!(r, "configOptions")
    opts = ACP.parse_config_options(r)
    @test [o.id for o in opts] == ["mode", "model"]
    @test option_by_id(opts, "model").current_value == "default"
    @test ACP.pill_label(option_by_id(opts, "model")) == "Opus 4.8 with 1M context"
    @test ACP.parse_config_options(Dict{String,Any}("sessionId"=>"s")) == ACP.ConfigOption[]
end

@testset "wire: config/mode session updates parse to typed notifs" begin
    u = ACP.parse_session_update(Dict{String,Any}(
        "sessionUpdate" => "config_option_update",
        "configOptions" => config_options_json()))
    @test u isa ACP.ConfigOptionUpdateNotif
    @test length(u.options) == 3

    m = ACP.parse_session_update(Dict{String,Any}(
        "sessionUpdate" => "current_mode_update", "modeId" => "plan"))
    @test m isa ACP.CurrentModeUpdateNotif
    @test m.mode_id == "plan"
end

@testset "model picker: single-choice collapses to a span" begin
    # An agent that only offers one model — no point showing a dropdown.
    r = session_result()
    r["configOptions"][2]["options"] =
        [Dict("value"=>"default", "name"=>"Default", "description"=>"only")]
    opts = ACP.parse_config_options(r)
    model = option_by_id(opts, "model")
    pick = BT.Bonito.Observable{Any}(["", ""])
    @test !occursin("<select", string(BT.header_pill(model, pick)))
end

@testset "apply_config_pick! is a safe no-op without a live client" begin
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    chat = BT.ChatModel(st, mktempdir(); agent = BT.WorkerAgent(st, "w1", "/p"))
    chat.session_meta[] = Any[ACP.parse_config_options(session_result())...]
    # No live client on the (never-started) agent → no-op, session_meta untouched.
    BT.apply_config_pick!(chat, "model", "sonnet")
    m = option_by_id([x for x in chat.session_meta[] if x isa ACP.ConfigOption], "model")
    @test m.current_value == "default"
end

end
