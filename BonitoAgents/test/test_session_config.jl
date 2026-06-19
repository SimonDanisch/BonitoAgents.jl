# Session config in the chat header: the session-setup result (session/new /
# session/load) carries models/modes/configOptions; we keep the RAW result on
# the ACP Client, parse typed `ConfigOption`s as a view, surface them on
# `ChatModel.session_meta`, and render read-only pills via `header_pill`
# dispatch. Mid-session `config_option_update` / `current_mode_update`
# session updates patch the observable without disturbing open bubbles.
#
# TestKit migration. The deleted `MockTransport` (the `transport=` kwarg is gone;
# `agent=` replaces it) used to script a session/new carrying configOptions and a
# mid-turn config_option_update, plus capture the set_config_option RPC. The
# mock claude-agent-acp (the only fake left) replies to session/new with just
# `{sessionId}` and exposes NO config-update event, so config bring-up / mid-turn
# patches are NOT drivable through the harness's agent. Per the migration rule —
# "assert what's drivable; unit-test the parse/apply contract directly" — these
# are split:
#
#   • ConfigOption parse / pill / header / select rendering, `process!`
#     (ConfigUpdate / ModeUpdate), the optimistic `apply_config_pick!` patch, and
#     the "a mid-turn ConfigUpdate must not split a streaming AgentMsg" contract
#     are PURE/direct unit tests on a real `ServerState` + a `ChatModel` whose
#     agent is a no-op `MockAgent([])` (never started — just a state holder).
#   • The one genuinely agent-driven assertion — "picking a model dispatches a
#     real `session/set_config_option` RPC over the ACP wire" — is driven through
#     the REAL stack: a live `MockAgent` (real mock subprocess, real Connection)
#     with an `on_frame` tap captures the outgoing request frame.

using Test
using JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# Mirrors the real claude-agent-acp session/new result (from a live acp.jsonl).
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
                 "description"=>"Opus 4.7 with 1M context · Most capable for complex work"),
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
             "description"=>"Opus 4.7 with 1M context · Most capable for complex work")]),
    "modes" => Dict("currentModeId"=>"default", "availableModes"=>[
        Dict("id"=>"default", "name"=>"Default",
             "description"=>"Standard behavior, prompts for dangerous operations")]),
    "configOptions" => config_options_json(),
)

option_by_id(opts, id) = opts[findfirst(o -> o.id == id, opts)]

# Real ServerState + a ChatModel whose agent is a no-op MockAgent. Nothing in the
# pure tests drives a turn, so the agent is never `start!`ed — it only gives the
# typed-config paths a real `session_meta` observable + `comm` to bind to.
function make_chat()
    state = BT.ServerState(; state_dir = mktempdir(),
                             working_dir = mktempdir(), worker_secret = "x")
    BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
end

@testset "session config in the header" begin

    @testset "parse_config_options: typed view over the raw result" begin
        opts = ACP.parse_config_options(session_result())
        @test [o.id for o in opts] == ["mode", "model", "effort"]
        model = option_by_id(opts, "model")
        @test model.current_value == "default"
        @test model.category == "model"
        @test length(model.choices) == 2

        # For the MODEL, "default" is an alias — the label surfaces the
        # description's first segment, not the word "Default".
        @test ACP.pill_label(model) == "Opus 4.7 with 1M context"
        # Everything else shows its plain choice name (descriptions there are
        # explanations, not values).
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

    @testset "fallback synthesis from modes/models blocks" begin
        r = session_result()
        delete!(r, "configOptions")
        opts = ACP.parse_config_options(r)
        @test [o.id for o in opts] == ["mode", "model"]
        @test option_by_id(opts, "model").current_value == "default"
        @test ACP.pill_label(option_by_id(opts, "model")) == "Opus 4.7 with 1M context"

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

    @testset "process!: ConfigUpdate replaces options, preserves other kinds" begin
        chat = make_chat()
        opts = ACP.parse_config_options(session_result())
        chat.session_meta[] = Any["future-meta-kind"]

        BT.process!(chat, ACP.ConfigUpdate(opts))
        @test count(x -> x isa ACP.ConfigOption, chat.session_meta[]) == 3
        @test "future-meta-kind" in chat.session_meta[]

        BT.process!(chat, ACP.ModeUpdate("bypassPermissions"))
        mode = option_by_id([x for x in chat.session_meta[] if x isa ACP.ConfigOption], "mode")
        @test mode.current_value == "bypassPermissions"
        @test BT.AgentClientProtocol.pill_label(mode) == "Bypass Permissions"
        @test "future-meta-kind" in chat.session_meta[]
    end

    @testset "header_pill dispatch + meta line" begin
        opts = ACP.parse_config_options(session_result())
        pill = BT.header_pill(option_by_id(opts, "model"))
        @test occursin("Opus 4.7 with 1M context", string(pill))
        @test occursin("bt-header-meta-item", string(pill))
        # Non-model options read as "name: value".
        @test occursin("mode: Default", string(BT.header_pill(option_by_id(opts, "mode"))))
        # Unknown meta kind degrades to its string form.
        @test occursin("whatever", string(BT.header_pill("whatever")))

        # Display policy: only the MODEL is shown — mode/effort report
        # unhelpful "default"s. They stay in the data, not in the line.
        line = string(BT.header_meta_line(Any[opts...]))
        @test occursin("bt-header-meta", line)
        @test occursin("Opus 4.7 with 1M context", line)
        @test !occursin("mode:", line)
        @test !occursin("effort:", line)
        @test count("bt-header-meta-item", line) == 1   # single item shown
        # Future meta kinds default to visible, joined with the separator.
        line2 = string(BT.header_meta_line(Any[option_by_id(opts, "model"), "v2.1"]))
        @test occursin(" · ", line2) && occursin("v2.1", line2)
        # Empty meta still renders the `.bt-header-meta` element (keeps its
        # margin-left:auto so the header controls don't jump during a switch).
        @test string(BT.header_meta_line(Any[])) == string(BT.DOM.div(; class = "bt-header-meta"))
    end

    # The old "bring-up populates session_meta; mid-turn update patches it" e2e
    # leaned on a scripted MockTransport. The mock claude-agent-acp can't carry
    # configOptions on session/new nor a mid-turn config update, so the SAME
    # behaviour is asserted as a direct contract: a mid-turn `ConfigUpdate` patches
    # the option WITHOUT splitting the streaming agent bubble it interleaves with.
    @testset "mid-turn ConfigUpdate patches meta without splitting the bubble" begin
        chat = make_chat()
        chat.session_meta[] = Any[ACP.parse_config_options(session_result())...]
        opts = [x for x in chat.session_meta[] if x isa ACP.ConfigOption]
        @test [o.id for o in opts] == ["mode", "model", "effort"]
        @test option_by_id(opts, "effort").current_value == "default"

        # A streaming agent bubble, mid-turn: chunk → config flips effort → chunk.
        am = BT.send!(chat, BT.AgentMsg(chat, ""))
        append!(am, "hello ")
        flipped = deepcopy(config_options_json())
        flipped[3]["currentValue"] = "high"
        BT.process!(chat, ACP.ConfigUpdate(ACP.parse_config_options(
            Dict{String,Any}("sessionId"=>"s", "configOptions"=>flipped))))
        append!(am, "world")
        close(am)

        # The metadata update landed…
        opts = [x for x in chat.session_meta[] if x isa ACP.ConfigOption]
        @test option_by_id(opts, "effort").current_value == "high"
        # …and the streaming bubble was not split by it.
        ams = [m for m in chat.msgs_store if m isa BT.AgentMsg]
        @test length(ams) == 1
        @test ams[1].text == "hello world"
    end

    @testset "model picker: <select> rendering" begin
        opts = ACP.parse_config_options(session_result())
        model = option_by_id(opts, "model")
        pick = BT.Bonito.Observable(Tuple{String,String}(("", "")))

        # With a picker AND >1 choices → renders a <select>, NOT a plain span.
        s = string(BT.header_pill(model, pick))
        @test occursin("<select", s)
        @test occursin("bt-header-meta-pick", s)
        @test occursin("bt-header-meta-select", s)
        # Each choice ships as an <option> with value=choice.value + label=choice.name.
        @test occursin("value=\"default\"", s)
        @test occursin("value=\"sonnet\"", s)
        @test occursin("Default (recommended)", s)
        @test occursin("Sonnet", s)
        # Exactly ONE option is marked `selected` (the current value's), and
        # the same `<option>` tag carries `value="default"`. Bonito sorts
        # attributes alphabetically, so we can't depend on left-of-value
        # ordering — assert structurally instead: count + intra-tag pairing.
        @test count("selected", s) == 1
        @test occursin(r"<option[^>]*\bselected\b[^>]*value=\"default\"", s)

        # Without a picker → plain span fallback, byte-identical to before.
        plain = string(BT.header_pill(model))
        @test occursin("<span", plain)
        @test !occursin("<select", plain)
    end

    @testset "model picker: single-choice collapses to a span" begin
        # An agent that only offers one model — no point showing a dropdown.
        r = session_result()
        r["configOptions"][2]["options"] =
            [Dict("value"=>"default", "name"=>"Default", "description"=>"only")]
        opts = ACP.parse_config_options(r)
        model = option_by_id(opts, "model")
        pick = BT.Bonito.Observable(Tuple{String,String}(("", "")))
        @test !occursin("<select", string(BT.header_pill(model, pick)))
    end

    @testset "apply_config_pick! is a safe no-op without a live client" begin
        chat = make_chat()
        chat.session_meta[] = Any[ACP.parse_config_options(session_result())...]
        # No client[] yet (agent never started) → no-op, session_meta untouched
        # (no nil-deref).
        @test BT.client(chat.agent) === nothing
        BT.apply_config_pick!(chat, "model", "sonnet")
        m = option_by_id([x for x in chat.session_meta[] if x isa ACP.ConfigOption], "model")
        @test m.current_value == "default"
    end

    # The one genuinely agent-driven case: a model pick must (a) optimistically
    # patch session_meta immediately, and (b) dispatch a real
    # `session/set_config_option` request over the ACP wire. Driven through the
    # REAL stack — a live MockAgent (real subprocess + Connection) with an
    # `on_frame` tap capturing the outgoing frame. `apply_config_pick!` fires the
    # RPC off-task; the mock has no handler for it (the @async request just stays
    # pending), but the request frame is on the wire, which is what we assert.
    @testset "picking a model dispatches session/set_config_option (real wire)" begin
        frames = Tuple{Symbol,Dict{String,Any}}[]
        lk = ReentrantLock()
        tap = (dir, msg) -> lock(() -> push!(frames, (dir, Dict{String,Any}(msg))), lk)

        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        cwd   = mktempdir()
        agent = BT.MockAgent(; cwd = cwd)
        model = BT.ChatModel(state, cwd; agent = agent)
        setcfg = nothing
        has_setcfg() = lock(lk) do
            any(t -> t[1] == :out && get(t[2], "method", "") == "session/set_config_option", frames)
        end
        try
            t = @async BT.start!(agent; on_frame = tap)
            @assert timedwait(() -> istaskdone(t), 30.0) === :ok "agent bring-up hung"
            istaskfailed(t) && fetch(t)
            @test BT.client(agent) !== nothing

            # Seed session_meta with the model option (bring-up would, for a real
            # config-carrying agent).
            model.session_meta[] = Any[ACP.parse_config_options(session_result())...]
            @test option_by_id([x for x in model.session_meta[] if x isa ACP.ConfigOption],
                               "model").current_value == "default"

            # Trigger the pick (as the JS onchange handler does).
            BT.apply_config_pick!(model, "model", "sonnet")

            # Optimistic patch: reflected immediately, BEFORE any agent confirmation.
            @test option_by_id([x for x in model.session_meta[] if x isa ACP.ConfigOption],
                               "model").current_value == "sonnet"

            # The RPC frame lands on the wire (dispatched off-task).
            @assert timedwait(has_setcfg, 30.0) === :ok "set_config_option never reached the wire"
            lock(lk) do
                idx = findfirst(t -> t[1] == :out &&
                                get(t[2], "method", "") == "session/set_config_option", frames)
                setcfg = frames[idx][2]
            end
            @test setcfg !== nothing
            @test setcfg["params"]["sessionId"] == "s"
            @test setcfg["params"]["configId"]  == "model"
            @test setcfg["params"]["value"]     == "sonnet"
            @test haskey(setcfg, "id")          # it's a REQUEST, not a notification
        finally
            try; BT.stop!(agent); catch; end
        end
    end

end
