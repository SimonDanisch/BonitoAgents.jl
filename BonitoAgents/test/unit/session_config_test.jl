# Headless unit coverage for PR #10's session-config layer: the typed
# `ConfigOption` view over a session/new result, pill-label resolution, the
# config/mode session-update parsing, and the header `<select>` / `<span>`
# rendering. The ChatModel-level behaviours (bring-up populates session_meta,
# a pick fires set_config_option, a mid-turn update patches without splitting
# the bubble) are covered black-box by `e2e/session_config.jl`.
@testitem "unit:session_config" tags = [:unit] begin
    using BonitoAgents
    const BT  = BonitoAgents
    const ACP = BonitoAgents.AgentClientProtocol

    config_options_json() = [
        Dict("id"=>"mode", "name"=>"Mode", "category"=>"mode", "type"=>"select",
             "currentValue"=>"default", "options"=>[
                Dict("value"=>"default", "name"=>"Default",
                     "description"=>"Standard behavior, prompts for dangerous operations"),
                Dict("value"=>"bypassPermissions", "name"=>"Bypass Permissions",
                     "description"=>"Bypass all permission checks")]),
        Dict("id"=>"model", "name"=>"Model", "category"=>"model", "type"=>"select",
             "currentValue"=>"default", "options"=>[
                Dict("value"=>"default", "name"=>"Default (recommended)",
                     "description"=>"Opus 4.7 with 1M context · Most capable for complex work"),
                Dict("value"=>"sonnet", "name"=>"Sonnet",
                     "description"=>"Sonnet 4.6 · Best for everyday tasks")]),
        Dict("id"=>"effort", "name"=>"Effort", "category"=>"thought_level", "type"=>"select",
             "currentValue"=>"default", "options"=>[
                Dict("value"=>"default", "name"=>"Default"),
                Dict("value"=>"high", "name"=>"High")]),
    ]

    session_result() = Dict{String,Any}(
        "sessionId" => "s",
        "models" => Dict("currentModelId"=>"default", "availableModels"=>[
            Dict("modelId"=>"default", "name"=>"Default (recommended)",
                 "description"=>"Opus 4.7 with 1M context · Most capable for complex work")]),
        "modes" => Dict("currentModeId"=>"default", "availableModes"=>[
            Dict("id"=>"default", "name"=>"Default",
                 "description"=>"Standard behavior, prompts for dangerous operations")]),
        "configOptions" => config_options_json(),
    )

    by_id(opts, id) = opts[findfirst(o -> o.id == id, opts)]

    @testset "parse_config_options: typed view over the raw result" begin
        opts = ACP.parse_config_options(session_result())
        @test [o.id for o in opts] == ["mode", "model", "effort"]
        model = by_id(opts, "model")
        @test model.current_value == "default"
        @test model.category == "model"
        @test length(model.choices) == 2

        # For the MODEL, "default" is an alias — the label surfaces the
        # description's first segment, not the word "Default".
        @test ACP.pill_label(model) == "Opus 4.7 with 1M context"
        # Other options show their plain choice name.
        @test ACP.pill_label(by_id(opts, "mode"))   == "Default"
        @test ACP.pill_label(by_id(opts, "effort")) == "Default"

        # An explicit (non-alias) selection shows its proper choice name.
        mode = by_id(opts, "mode")
        switched = ACP.ConfigOption(mode.id, mode.name, mode.description,
            mode.category, "bypassPermissions", mode.choices)
        @test ACP.pill_label(switched) == "Bypass Permissions"

        # Unresolvable current value → raw value, not an error.
        ghost = ACP.ConfigOption("x", "X", nothing, nothing, "gone", mode.choices)
        @test ACP.pill_label(ghost) == "gone"
    end

    @testset "fallback synthesis from modes/models blocks" begin
        r = session_result()
        delete!(r, "configOptions")
        opts = ACP.parse_config_options(r)
        @test [o.id for o in opts] == ["mode", "model"]
        @test by_id(opts, "model").current_value == "default"
        @test ACP.pill_label(by_id(opts, "model")) == "Opus 4.7 with 1M context"

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

    @testset "header_pill dispatch + meta line" begin
        opts = ACP.parse_config_options(session_result())
        pill = BT.header_pill(by_id(opts, "model"))
        @test occursin("Opus 4.7 with 1M context", string(pill))
        @test occursin("bt-header-meta-item", string(pill))
        # Non-model options show just their value (no "name:" prefix).
        @test occursin("Default", string(BT.header_pill(by_id(opts, "mode"))))
        @test !occursin("mode:", string(BT.header_pill(by_id(opts, "mode"))))
        # Unknown meta kind degrades to its string form.
        @test occursin("whatever", string(BT.header_pill("whatever")))

        # model + permission mode + effort are all shown.
        line = string(BT.header_meta_line(Any[opts...]))
        @test occursin("bt-header-meta", line)
        @test occursin("Opus 4.7 with 1M context", line)
        @test !occursin("mode:", line)
        @test !occursin("effort:", line)
        @test count("bt-header-meta-item", line) == 3
        # Future meta kinds default to visible, joined with the separator.
        line2 = string(BT.header_meta_line(Any[by_id(opts, "model"), "v2.1"]))
        @test occursin(" · ", line2) && occursin("v2.1", line2)
        # Empty meta still renders the `.bt-header-meta` element.
        @test string(BT.header_meta_line(Any[])) == string(BT.DOM.div(; class = "bt-header-meta"))
    end

    @testset "model picker renders a <select>" begin
        opts  = ACP.parse_config_options(session_result())
        model = by_id(opts, "model")
        pick  = BT.Bonito.Observable(Tuple{String,String}(("", "")))

        s = string(BT.header_pill(model, pick))
        @test occursin("<select", s)
        @test occursin("bt-header-meta-pick", s)
        @test occursin("bt-header-meta-select", s)
        @test occursin("value=\"default\"", s)
        @test occursin("value=\"sonnet\"", s)
        @test occursin("Default (recommended)", s)
        @test occursin("Sonnet", s)
        # Exactly ONE option is `selected` (the current value's).
        @test count("selected", s) == 1
        @test occursin(r"<option[^>]*\bselected\b[^>]*value=\"default\"", s)

        # Without a picker → plain span fallback.
        plain = string(BT.header_pill(model))
        @test occursin("<span", plain)
        @test !occursin("<select", plain)
    end

    @testset "mode + effort are interactive selects too" begin
        opts = ACP.parse_config_options(session_result())
        pick = BT.Bonito.Observable{Any}(["", ""])
        for id in ("mode", "effort", "model")
            s = string(BT.header_pill(by_id(opts, id), pick))
            @test occursin("<select", s)
            @test occursin("bt-header-meta-pick", s)
        end
        @test !occursin("mode:",   string(BT.header_pill(by_id(opts, "mode"), pick)))
        @test !occursin("effort:", string(BT.header_pill(by_id(opts, "effort"), pick)))
    end

    @testset "single-choice option collapses to a span" begin
        r = session_result()
        r["configOptions"][2]["options"] =
            [Dict("value"=>"default", "name"=>"Default", "description"=>"only")]
        opts  = ACP.parse_config_options(r)
        model = by_id(opts, "model")
        pick  = BT.Bonito.Observable(Tuple{String,String}(("", "")))
        @test !occursin("<select", string(BT.header_pill(model, pick)))
    end
end
