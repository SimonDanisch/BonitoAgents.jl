# Rendering-contract tests for the 2026-06 UX batch:
#
#   1. TodoListMsg → wire dict (the JS plan bubble + taskbar feed off this):
#      html rows, live flag, "n/m done" summary, plan_update shape.
#   2. Background BashToolMsg → header dict: taskbar slot + background flag,
#      and the bg-streaming summary/finalize wire events.
#   3. bt_julia_eval extras: live code preview (`code`), the timeout badge
#      (`timeout_s`), the ⊗ stop affordance (`stoppable`) — and that
#      bt_julia_interrupt itself is NOT stoppable.
#   4. ✎ editor affordance (`editable`) for Read / bt_show text files.
#   5. Permission/question requests: handle_permission_request emits the
#      `permission` wire event and resolves with the clicked option.
#   6. Small helpers: eval_timeout_label, permission_question_text,
#      compact_sync_label, identicon_svg.

using Test
using Bonito
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
const obs_on = Bonito.Observables.on

function make_chat_x()
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    BT.ChatModel(state, mktempdir();
                  transport = BT.MockTransport((o, i) -> nothing))
end

mkentries_x(pairs::Vector) =
    [BT.PlanEntry(String(c), "", String(s)) for (c, s) in pairs]

@testset "render extras" begin

# ── 1. TodoListMsg wire dict ────────────────────────────────────────────────
@testset "TodoListMsg → wire dict" begin
    chat = make_chat_x()
    t = BT.TodoListMsg(chat, mkentries_x([("write tests", "completed"),
                                          ("fix the bug", "in_progress"),
                                          ("ship it", "pending")]))
    d = BT.msg_to_dict(t)
    @test d["type"] == "plan"
    @test d["live"] === true
    @test d["summary"] == "1/3 done"
    @test occursin("write tests", d["html"])
    @test occursin("✓", d["html"])         # completed glyph
    @test occursin("▶", d["html"])         # in_progress glyph
    @test occursin("○", d["html"])         # pending glyph
    @test !haskey(d, "finished_at")        # still live

    u = BT.plan_update_dict(t)
    @test u["type"] == "plan_update"
    @test u["id"] == t.id

    # All-done list: finished_at set (via absorb path) ⇒ live false on the wire.
    t.entries = mkentries_x([("write tests", "completed"), ("ship it", "completed")])
    t.finished_at = time()
    d2 = BT.msg_to_dict(t)
    @test d2["live"] === false
    @test d2["summary"] == "2/2 done"
    @test haskey(d2, "finished_at")
end

# ── 2. Background bash rendering ────────────────────────────────────────────
@testset "background BashToolMsg → header + bg stream events" begin
    chat = make_chat_x()
    m = BT.BashToolMsg("bg1", "execute", "sleep 99", "completed", "",
                       time(), nothing,
                       "sleep 99", true,
                       "/tmp/out.log", 0, true, "", chat)
    d = BT.tool_header_dict(m)
    @test d["taskbar"] === true
    @test d["background"] === true
    @test BT.is_live(m)                    # bg_running keeps it live

    events = Dict{String,Any}[]
    obs_on(d -> push!(events, d), BT.shared(chat).comm)

    m.bg_text = "line one\nline two\n"
    BT.stream_bg_update!(chat, m)
    @test !isempty(events)
    e = events[end]
    @test e["type"] == "tool_update" && e["status"] == "in_progress"
    @test occursin("2 lines", e["summary"])
    @test e["taskbar"] === true

    BT.finalize_bg_task!(chat, m)
    @test m.bg_running === false
    @test m.finished_at !== nothing
    f = events[end]
    @test f["type"] == "tool_update" && f["status"] == "completed"
    @test occursin("done", f["summary"])
    @test !BT.is_live(m)
end

# ── 3. bt_julia_eval extras ────────────────────────────────────────────────
@testset "eval tool header: code preview / timeout / stoppable" begin
    chat = make_chat_x()
    raw = Dict{String,Any}("code" => "1 + 1\nsleep(60)",
                           "env_path" => "/tmp/proj", "timeout" => 45)
    m = BT.MCPToolMsg("e1", "other", "mcp__btworker__bt_julia_eval",
                      "in_progress", "", time(), nothing,
                      "btworker", "bt_julia_eval", raw, chat)
    d = BT.tool_header_dict(m)
    @test d["title"] == "bt_julia_eval"
    @test d["server"] == "btworker"
    @test d["code"] == "1 + 1\nsleep(60)"
    @test d["timeout_s"] == "45s"
    @test d["stoppable"] === true

    # interrupt itself is not stoppable, but still shows code + timeout
    m2 = BT.MCPToolMsg("e2", "other", "mcp__btworker__bt_julia_interrupt",
                       "in_progress", "", time(), nothing,
                       "btworker", "bt_julia_interrupt",
                       Dict{String,Any}("env_path" => "/tmp/proj"), chat)
    d2 = BT.tool_header_dict(m2)
    @test !haskey(d2, "stoppable")
    @test d2["timeout_s"] == "30s"     # default cadence

    # non-eval MCP tools get none of the extras
    m3 = BT.MCPToolMsg("e3", "other", "mcp__btworker__bt_show",
                       "in_progress", "", time(), nothing,
                       "btworker", "bt_show",
                       Dict{String,Any}("path" => "x.png"), chat)
    d3 = BT.tool_header_dict(m3)
    @test !haskey(d3, "code") && !haskey(d3, "timeout_s") && !haskey(d3, "stoppable")
end

@testset "eval_timeout_label" begin
    @test BT.eval_timeout_label(Dict{String,Any}("timeout" => 45)) == "45s"
    @test BT.eval_timeout_label(Dict{String,Any}("timeout" => 0)) == "no timeout"
    @test BT.eval_timeout_label(Dict{String,Any}("code" => "Pkg.add(\"X\")")) == "no timeout"
    @test BT.eval_timeout_label(Dict{String,Any}("code" => "1 + 1")) == "30s"
    @test BT.eval_timeout_label(Dict{String,Any}()) == "30s"
end

# ── 4. ✎ editor affordance ─────────────────────────────────────────────────
@testset "editable_path_from" begin
    # Read tool on a text file → editable
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "src/foo.jl"), Any[]) ==
        "src/foo.jl"
    # Read on an image → not editable
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "img.png"), Any[]) === nothing
    # bt_show ref on a text file → editable (the ref wins over the title)
    content = Any[ACP.TextContent("shown: notes/readme.md (text/markdown, 1 KB)")]
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "other", "title" => "bt_show"), content) ==
        "notes/readme.md"
    # no path at all → nothing
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "execute", "title" => "ls"), Any[]) === nothing

    # ── generalized sources: any tool that identifies a file gets the ✎ ──
    # edit tool → its DiffContent target (title is just a label)
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "edit", "title" => "Edit"),
        Any[ACP.DiffContent("/abs/x.rs", "old", "new")]) == "/abs/x.rs"
    # any kind with a path-looking title
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "execute", "title" => "scripts/run.sh"), Any[]) ==
        "scripts/run.sh"
    # MCP path argument (bt_show's `path`, custom tools' `file_path`)
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "other", "title" => "bt_show",
                          "path_hint" => "data/table.csv"), Any[]) == "data/table.csv"
    @test BT.mcp_path_hint(Dict{String,Any}("file_path" => "a.txt")) == "a.txt"
    @test BT.mcp_path_hint(Dict{String,Any}("code" => "1+1")) === nothing

    # ── gate is "not binary" now, not a text-extension whitelist ──
    # extensionless + dotfiles + unknown text extensions are editable
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "sub/Makefile"), Any[]) ==
        "sub/Makefile"
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "repo/.gitignore"), Any[]) ==
        "repo/.gitignore"
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "main.rs"), Any[]) == "main.rs"
    # media + binary formats refused
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "model.safetensors"), Any[]) === nothing
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "clip.mp4"), Any[]) === nothing
    # labels / sentences / URLs are not paths
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "execute", "title" => "bash"), Any[]) === nothing
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "other", "title" => "Search the docs"), Any[]) === nothing
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "fetch", "title" => "https://x.org/a.md"), Any[]) === nothing
end

# ── 5. Permission / question round-trip ─────────────────────────────────────
@testset "permission request → card event → answer resolves" begin
    chat = make_chat_x()
    events = Dict{String,Any}[]
    obs_on(d -> push!(events, d), BT.shared(chat).comm)

    params = Dict{String,Any}(
        "options" => Any[
            Dict("optionId" => "opt-a", "name" => "Use approach A", "kind" => "allow_once"),
            Dict("optionId" => "opt-b", "name" => "Use approach B", "kind" => ""),
        ],
        "toolCall" => Dict{String,Any}(
            "title" => "AskUserQuestion",
            "rawInput" => Dict{String,Any}(
                "questions" => Any[Dict{String,Any}(
                    "question" => "Which approach should I take?")])))

    result = Ref{Any}(nothing)
    t = @async (result[] = BT.handle_permission_request(chat, params))
    # Wait for the card event to land.
    deadline = time() + 5
    while time() < deadline &&
          !any(e -> get(e, "type", "") == "permission", events)
        sleep(0.02)
    end
    perm = events[findlast(e -> get(e, "type", "") == "permission", events)]
    @test perm["question"] == "Which approach should I take?"
    @test length(perm["options"]) == 2
    @test perm["options"][2]["name"] == "Use approach B"

    # Click the second option (via the dispatch path the JS uses).
    BT.handle_command!(chat, nothing,
        BT.PermissionAnswerCommand(String(perm["key"]), "opt-b"))
    wait(t)
    @test result[] == Dict("outcome" => Dict("outcome" => "selected",
                                             "optionId" => "opt-b"))
    # The card-teardown broadcast went out.
    @test any(e -> get(e, "type", "") == "permission_done", events)
    # Nothing left pending.
    @test !haskey(BT.PENDING_PERMISSIONS, String(perm["key"]))
end

# ── 5b. Form elicitation (AskUserQuestion) round-trip ───────────────────────
@testset "elicitation: schema parse + answer round-trip" begin
    # The exact shape claude-agent-acp's askUserQuestionsToCreateRequest emits.
    schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "question_0" => Dict{String,Any}(
                "type" => "string", "title" => "Parser",
                "oneOf" => Any[
                    Dict("const" => "Rewrite", "title" => "Rewrite — start fresh"),
                    Dict("const" => "Patch",   "title" => "Patch"),
                ]),
            "question_1" => Dict{String,Any}(
                "type" => "array", "title" => "Targets",
                "items" => Dict{String,Any}("anyOf" => Any[
                    Dict("const" => "lexer"), Dict("const" => "parser"),
                ])),
            "customAnswer" => Dict{String,Any}(
                "type" => "string", "title" => "Other")))
    fields = BT.parse_elicitation_fields(schema)
    @test [f["key"] for f in fields] == ["question_0", "question_1", "customAnswer"]
    @test fields[1]["kind"] == "select"
    @test fields[1]["options"][1]["value"] == "Rewrite"
    @test fields[1]["options"][1]["label"] == "Rewrite — start fresh"
    @test fields[2]["kind"] == "multiselect"
    @test length(fields[2]["options"]) == 2
    @test fields[3]["kind"] == "text"

    chat = make_chat_x()
    events = Dict{String,Any}[]
    obs_on(d -> push!(events, d), BT.shared(chat).comm)
    params = Dict{String,Any}(
        "mode" => "form",
        "message" => "Which approach should I take?",
        "requestedSchema" => schema)
    result = Ref{Any}(nothing)
    t = @async (result[] = BT.handle_elicitation_request(chat, params))
    deadline = time() + 5
    while time() < deadline && !any(e -> get(e, "type", "") == "question", events)
        sleep(0.02)
    end
    qev = events[findlast(e -> get(e, "type", "") == "question", events)]
    @test qev["message"] == "Which approach should I take?"
    @test length(qev["fields"]) == 3
    BT.handle_command!(chat, nothing, BT.QuestionAnswerCommand(String(qev["key"]),
        Dict{String,Any}("question_0" => "Patch", "question_1" => Any["lexer"],
                          "customAnswer" => "also add tests")))
    wait(t)
    @test result[]["action"] == "accept"
    @test result[]["content"]["question_0"] == "Patch"
    @test any(e -> get(e, "type", "") == "question_done", events)

    # Skip path → decline.
    t2 = @async BT.handle_elicitation_request(chat, params)
    n_questions() = count(e -> get(e, "type", "") == "question", events)
    deadline2 = time() + 5
    while n_questions() < 2 && time() < deadline2
        sleep(0.02)
    end
    qev2 = events[findlast(e -> get(e, "type", "") == "question", events)]
    BT.handle_command!(chat, nothing, BT.QuestionSkipCommand(String(qev2["key"])))
    @test fetch(t2) == Dict("action" => "decline")

    # URL-mode can't be rendered → cancel.
    @test BT.handle_elicitation_request(chat,
        Dict{String,Any}("mode" => "url", "message" => "x")) ==
        Dict("action" => "cancel")
end

@testset "permission_question_text" begin
    @test BT.permission_question_text(Dict{String,Any}(
        "rawInput" => Dict{String,Any}("question" => "Deploy now?"))) == "Deploy now?"
    @test BT.permission_question_text(Dict{String,Any}(
        "title" => "Bash")) == "Bash"
    @test BT.permission_question_text(Dict{String,Any}()) ==
        "The agent is asking for permission"
end

# ── 6. Small helpers ────────────────────────────────────────────────────────
@testset "compact_sync_label" begin
    @test BT.compact_sync_label("") == "Sync"
    @test BT.compact_sync_label("__click__") == "Sync"
    @test BT.compact_sync_label("starting…") == "starting…"
    long = "Sending 137/999: src/some/very/long/path/file.jl"
    @test endswith(BT.compact_sync_label(long), "…")
    @test length(BT.compact_sync_label(long)) <= 26
end

@testset "identicon_svg" begin
    a = BT.identicon_svg("p-1")
    b = BT.identicon_svg("p-1")
    c = BT.identicon_svg("p-2")
    @test a == b                       # deterministic
    @test a != c                       # distinct per id
    @test startswith(a, "<svg")
    @test occursin("rect", a)
    @test !occursin('"', a)            # single-quoted: embeddable in url("…")
end

end
