# Session config in the chat header: the session-setup result (session/new /
# session/load) carries models/modes/configOptions; we keep the RAW result on
# the ACP Client, parse typed `ConfigOption`s as a view, surface them on
# `ChatModel.session_meta`, and render read-only pills via `header_pill`
# dispatch. Mid-session `config_option_update` / `current_mode_update`
# session updates patch the observable without disturbing open bubbles.

using Test
using JSON
using BonitoAgents
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
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        chat = BT.ChatModel(state, mktempdir();
                            transport = BT.MockTransport((o, i) -> nothing))
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

    @testset "e2e: bring-up populates session_meta; mid-turn update patches it" begin
        upd_chunk(text) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
            "params"=>Dict("sessionId"=>"s",
                "update"=>Dict("sessionUpdate"=>"agent_message_chunk",
                               "content"=>Dict("type"=>"text","text"=>text)))))
        upd_config(opts) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
            "params"=>Dict("sessionId"=>"s",
                "update"=>Dict("sessionUpdate"=>"config_option_update",
                               "configOptions"=>opts))))
        resp(id, result) = JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result))

        # On prompt: chunk → config update (effort flips) → chunk → end_turn.
        # The metadata update must NOT split the streaming agent bubble.
        # NOTE: bring-up fires NO extra requests (no set_config_option) —
        # the responder would hang any unexpected RPC, failing the test.
        flipped = deepcopy(config_options_json())
        flipped[3]["currentValue"] = "high"
        on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
            Base.errormonitor(@async try
                for line in outgoing
                    msg    = JSON.parse(line)
                    method = get(msg, "method", "")
                    id     = get(msg, "id", nothing)
                    if method == "initialize" && id !== nothing
                        put!(incoming, resp(id, Dict()))
                    elseif method == "session/new" && id !== nothing
                        put!(incoming, resp(id, session_result()))
                    elseif method == "session/prompt" && id !== nothing
                        put!(incoming, upd_chunk("hello "))
                        put!(incoming, upd_config(flipped))
                        put!(incoming, upd_chunk("world"))
                        put!(incoming, resp(id, Dict("stopReason" => "end_turn")))
                    end
                end
            catch e
                e isa InvalidStateException || @warn "responder failed" exception=e
            end)
            return nothing
        end

        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        model = BT.ChatModel(state, mktempdir();
                             transport = BT.MockTransport(on_setup))
        BT.start_chat_client!(model)

        # Bring-up: raw result on the client, typed options on the observable.
        @test model.client[].session_result["configOptions"] isa AbstractVector
        opts = [x for x in model.session_meta[] if x isa ACP.ConfigOption]
        @test [o.id for o in opts] == ["mode", "model", "effort"]
        @test option_by_id(opts, "mode").current_value == "default"

        # Record busy transitions via a LISTENER, not by polling: a fast
        # scripted turn can flip busy on AND off inside one `timedwait` poll
        # interval, which made the bare `timedwait(() -> busy[])` flaky.
        busy_seen = Bool[]
        BT.Bonito.Observables.on(b -> push!(busy_seen, b), model.busy_active)
        BT.send_message!(model, BT.UserMsg("go"))
        @test timedwait(() -> busy_seen == [true, false], 5.0) === :ok

        # The mid-turn metadata update landed…
        opts = [x for x in model.session_meta[] if x isa ACP.ConfigOption]
        @test option_by_id(opts, "effort").current_value == "high"
        # …and the streaming bubble was not split by it.
        am = [m for m in model.msgs_store if m isa BT.AgentMsg]
        @test length(am) == 1
        @test am[1].text == "hello world"
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
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        chat = BT.ChatModel(state, mktempdir();
                            transport = BT.MockTransport((o, i) -> nothing))
        chat.session_meta[] = Any[ACP.parse_config_options(session_result())...]
        # No client[] yet → no-op, session_meta untouched (no nil-deref).
        BT.apply_config_pick!(chat, "model", "sonnet")
        m = option_by_id([x for x in chat.session_meta[] if x isa ACP.ConfigOption], "model")
        @test m.current_value == "default"
    end

    @testset "e2e: picking a model fires session/set_config_option" begin
        sent_rpcs = Channel{Dict{String,Any}}(16)
        resp(id, result) = JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result))
        on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
            Base.errormonitor(@async try
                for line in outgoing
                    msg    = JSON.parse(line)
                    put!(sent_rpcs, msg)
                    method = get(msg, "method", "")
                    id     = get(msg, "id", nothing)
                    if method == "initialize" && id !== nothing
                        put!(incoming, resp(id, Dict()))
                    elseif method == "session/new" && id !== nothing
                        put!(incoming, resp(id, session_result()))
                    elseif method == "session/set_config_option" && id !== nothing
                        # claude-agent-acp returns an empty object on success.
                        put!(incoming, resp(id, Dict{String,Any}()))
                    end
                end
            catch e
                e isa InvalidStateException || @warn "responder failed" exception=e
            end)
            return nothing
        end

        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        model = BT.ChatModel(state, mktempdir();
                             transport = BT.MockTransport(on_setup))
        BT.start_chat_client!(model)

        # Bring-up populated session_meta with the model option.
        opts = [x for x in model.session_meta[] if x isa ACP.ConfigOption]
        @test option_by_id(opts, "model").current_value == "default"

        # Trigger a model switch directly (as the JS onchange handler would).
        BT.apply_config_pick!(model, "model", "sonnet")

        # Optimistic patch: session_meta reflects the new value immediately, BEFORE
        # the agent's confirmation comes back.
        opts = [x for x in model.session_meta[] if x isa ACP.ConfigOption]
        @test option_by_id(opts, "model").current_value == "sonnet"

        # The RPC is dispatched off-task; wait for it to land in sent_rpcs.
        deadline = time() + 5.0
        set_cfg = nothing
        while time() < deadline && set_cfg === nothing
            if isready(sent_rpcs)
                m = take!(sent_rpcs)
                get(m, "method", "") == "session/set_config_option" && (set_cfg = m)
            else
                sleep(0.05)
            end
        end
        @test set_cfg !== nothing
        @test set_cfg["params"]["sessionId"] == "s"
        @test set_cfg["params"]["configId"]  == "model"
        @test set_cfg["params"]["value"]     == "sonnet"
        @test haskey(set_cfg, "id")          # it's a REQUEST, not a notification
    end

end

