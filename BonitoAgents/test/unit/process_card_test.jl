# The `bt_process` card and the JSON tools' card. Their results are JSON text, which
# used to go through markdown: lines ran together, `--flag` lost a dash and `_` turned
# into italics, with "33 lines · 2639 bytes" on a green pill for a job that had failed.
@testitem "unit:process_card" tags = [:unit] begin
    using BonitoAgents
    import JSON
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    TC = ACP.TextContent

    # A result as `public_process_result` and BonitoMCP's `dev_result` write it.
    job(; kw...) = merge(Dict{String,Any}("id" => "build-1", "label" => "Build docs",
        "status" => "succeeded", "argv" => ["make", "--jobs=4", "my_target"], "cwd" => "/tmp",
        "worker" => "Desktop", "worker_id" => "w1", "pid" => 42, "pgid" => 42, "exitcode" => 0,
        "signal" => 0, "started" => 1000.0, "finished" => 1002.5, "error" => "", "last_action" => "",
        "output" => "one\ntwo\n", "output_bytes" => 8, "output_offset" => 0, "next_offset" => 8,
        "output_truncated" => false), Dict{String,Any}(string(k) => v for (k, v) in kw))
    reply(d) = Any[TC(JSON.json(d, 2))]

    function card(status = "completed"; input...)
        m = BT.ProcessToolMsg(BT.Message("t1", "other", "", "bt_process", status, "", time(), nothing, nothing), "btworker")
        BT.apply_input!(m, Dict{String,Any}(string(k) => v for (k, v) in input))
        return m
    end
    function finished(d, status = "completed"; input...)
        m = card(status; input...)
        BT.adopt_reply!(m, reply(d))
        return m
    end

    @testset "a result decodes exactly, or not at all" begin
        j = BT.process_reply(reply(job()))
        @test j isa BT.ProcessJob
        @test j.argv == ["make", "--jobs=4", "my_target"]
        @test j.exitcode == 0 && j.pid == 42 && j.finished == 1002.5
        running = BT.process_reply(reply(job(status = "running", exitcode = nothing, signal = nothing, finished = nothing)))
        @test running.exitcode === nothing && running.finished === nothing
        @test BT.process_reply(reply(job(wait_reason = "timeout"))).wait_reason == "timeout"

        # Newest first, whatever order the worker's Dict gave.
        list = BT.process_reply(reply(Dict("jobs" => [job(id = "old", started = 1.0), job(id = "new", started = 2.0)])))
        @test list isa BT.ProcessJobList
        @test [j.id for j in list.jobs] == ["new", "old"]
        @test BT.process_reply(reply(Dict("jobs" => []))).jobs == BT.ProcessJob[]

        # What an agent can hand back instead: an error, JSON it cut short, a fence.
        text = JSON.json(job(), 2)
        @test BT.process_reply(Any[TC("no managed process with that id in this chat")]) === nothing
        @test BT.process_reply(Any[TC(first(text, length(text) ÷ 2))]) === nothing
        @test BT.process_reply(Any[TC("{\"unrelated\": 1}")]) === nothing
        @test BT.process_reply(Any[TC("[1, 2]")]) === nothing
        @test BT.process_reply(Any[]) === nothing
        @test BT.process_reply(Any[TC("```\n" * text * "\n```")]) isa BT.ProcessJob
    end

    @testset "the title says what the call did" begin
        @test BT.process_title(card(action = "start", id = "build-1", label = "Build docs", argv = ["make"])) == "Start Build docs"
        @test BT.process_title(card(action = "list")) == "List background commands"
        for (action, verb) in ("wait" => "Wait for", "status" => "Check", "output" => "Read output of",
                               "interrupt" => "Interrupt", "terminate" => "Terminate", "kill" => "Force kill")
            @test BT.process_title(card(action = action, id = "build-1")) == "$verb build-1"
        end
        # No label: the worker labels a job with its id, the command says more.
        m = card(action = "start", id = "build-1", argv = ["make", "two words"])
        @test BT.process_title(m) == "Start make 'two words'"
        BT.adopt_reply!(m, reply(job(label = "build-1", argv = ["make", "two words"])))
        @test BT.process_title(m) == "Start make 'two words'"
        # A wait names only an id; the result names the job.
        m = finished(job(), action = "wait", id = "build-1")
        @test BT.process_title(m) == "Wait for Build docs"
        @test BT.snap_title(m, "whatever the agent calls it") == "Wait for Build docs"
        # chat.md keeps a title on one line between backticks.
        @test BT.process_title(card(action = "start", id = "x", label = "a `b`\n  c")) == "Start a b c"
        long = BT.process_title(card(action = "start", id = "x", argv = ["sh", "-c", repeat("echo hi; ", 100)]))
        @test length(long) == 120 && endswith(long, "…")
        # Arguments not streamed in yet: the tool's own name, not a half sentence.
        @test BT.snap_title(card(), "") == "bt_process"
    end

    @testset "the summary says how it went" begin
        summary(d; input...) = BT.process_summary(finished(d; input...), reply(d))
        @test summary(job()) == "succeeded · 2.5 s"
        @test summary(job(status = "failed", exitcode = 3)) == "failed · exit 3 · 2.5 s"
        @test summary(job(status = "killed", exitcode = nothing, signal = 9)) == "killed · signal 9 · 2.5 s"
        @test summary(job(status = "running", exitcode = nothing, signal = nothing, finished = nothing)) == "running"
        @test summary(job(status = "running", exitcode = nothing, signal = nothing, finished = nothing, wait_reason = "timeout")) ==
              "running · wait timed out"
        @test summary(job(status = "running", exitcode = nothing, signal = nothing, finished = nothing, wait_reason = "message")) ==
              "running · woken by a message"
        @test summary(job(finished = 1000.0 + 192)) == "succeeded · 3 min 12 s"
        @test summary(job(finished = 1000.0 + 3900)) == "succeeded · 1 h 5 min"
        @test summary(Dict("jobs" => [job(), job(id = "b", status = "running")])) == "2 commands · 1 running"
        @test summary(Dict("jobs" => [job()])) == "1 command · 0 running"
        @test BT.process_summary(card("pending"; action = "wait", id = "x", seconds = 30), Any[]) == "up to 30.0 s"
        @test BT.process_summary(card("pending"; action = "status", id = "x"), Any[]) == ""
        # A failed call: its error, one line, also out of the fence claude-agent-acp adds.
        @test BT.process_summary(card("failed"; action = "status", id = "x"), Any[TC("```\nno such job\nmore\n```")]) == "no such job"
        # A result that is not a job keeps the plain size.
        @test occursin("bytes", BT.process_summary(card(; action = "status", id = "x"), Any[TC("not json")]))
    end

    @testset "the pill follows the job" begin
        for s in ("failed", "lost")
            @test BT.tool_status(finished(job(status = s, exitcode = 1), action = "wait", id = "x")) == "failed"
        end
        for s in ("succeeded", "running", "killed", "interrupted")
            @test BT.tool_status(finished(job(status = s), action = "status", id = "x")) == "completed"
        end
        @test BT.tool_status(finished(Dict("jobs" => [job(status = "failed", exitcode = 1)]), action = "list")) == "completed"
    end

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    root = mktempdir()
    p = BT.ProjectInfo("pc1", "Card Test", "w1", root, root, BT.now(BT.UTC))
    state.projects[][p.id] = p
    model = BT.ChatModel(state, root; project_id = p.id, agent = BT.WorkerAgent(state, "w1", root))
    stored(id, raw, content) = open(BT.tool_file(model.chat_dir, id), "w") do io
        JSON.print(io, Dict("content" => Any[BT.tool_content_to_dict(c) for c in content], "rawInput" => raw))
    end

    @testset "the body never goes through markdown" begin
        render(m, content) = BT.render_tool_content(state, m, content, p.id)
        @test render(card(; action = "status", id = "x"), reply(job())) isa BT.ProcessJob
        @test render(card(; action = "list"), reply(Dict("jobs" => [job()]))) isa BT.ProcessJobList
        err = render(card("failed"; action = "status", id = "x"), Any[TC("```\nno_such_job --here\n```")])
        @test err isa BT.CodeView && err.text == "no_such_job --here" && err.language == "plaintext"
        cut = render(card(; action = "status", id = "x"), Any[TC("{\"truncated\": ")])
        @test cut isa BT.CodeView && cut.text == "{\"truncated\": "

        json(status) = BT.build_mcp_msg(BT.JsonToolMsg, BT.Message("j", "other", "", "x", status, "", time(), nothing, nothing), "btworker", "bt_dev_memory")
        @test BT.tool_key(json("completed")) == "bt_dev_memory"
        v = render(json("completed"), Any[TC("{\n  \"rss_bytes\": 1\n}")])
        @test v isa BT.CodeView && v.language == "json" && v.text == "{\n  \"rss_bytes\": 1\n}"
        @test render(json("failed"), Any[TC("unknown section")]).language == "plaintext"

        # A third-party tool has no contract: its text is still prose.
        other = BT.GenericMCPToolMsg(BT.Message("g", "other", "", "x", "completed", "", time(), nothing, nothing), "playwright", "click")
        @test !(render(other, Any[TC("some *prose*")]) isa BT.CodeView)
    end

    # A wait blocks for up to an hour, and its card said "(loading…)" the whole
    # time (2026-11-12). It shows the job as the chat's book has it, and every
    # update of the job redraws it, until the call returns.
    @testset "a call still running shows its job and follows it" begin
        events = Dict{String,Any}[]
        BT.Bonito.on(d -> d["type"] == "tool_update" && push!(events, copy(d)), model.comm)
        lock(() -> (state.chat_models[p.id] = model), state.lock)   # a live chat, as the server keeps it
        update(; kw...) = BT.managed_process_update!(state, "w1", merge(
            job(status = "running", exitcode = nothing, signal = nothing, finished = nothing,
                output = "copying\n", output_bytes = 8),
            Dict{String,Any}("project_id" => p.id, "revision" => 1, "epoch" => BT.managed_process_epoch(state, p.id)),
            Dict{String,Any}(string(k) => v for (k, v) in kw)))
        waiting = BT.send!(model, card("in_progress"; action = "wait", id = "build-1", seconds = 1500))
        waiting.message.chat = model
        @test BT.process_summary(waiting, Any[]) == "up to 25 min"
        @test !BT.renders_from_input(waiting)                  # no such job yet

        update()
        shown = BT.render_tool_content(state, waiting, Any[], p.id)
        @test shown isa BT.ProcessJob && shown.status == "running" && shown.output == "copying\n"
        @test shown.argv == ["make", "--jobs=4", "my_target"]
        @test BT.renders_from_input(waiting)
        @test any(e -> e["id"] == "t1" && get(e, "refresh_body", false) === true, events)

        empty!(events)
        update(revision = 2, output = "copying\ndone\n", output_bytes = 13)
        @test BT.render_tool_content(state, waiting, Any[], p.id).output == "copying\ndone\n"
        @test count(e -> e["id"] == "t1", events) == 1

        # Answered, the card is its result: later updates of the job leave it alone.
        BT.adopt_reply!(waiting, reply(job()))
        waiting.message.status = "completed"
        empty!(events)
        update(revision = 3, output_bytes = 14)
        @test !any(e -> e["id"] == "t1", events)
        @test BT.render_tool_content(state, waiting, reply(job()), p.id).status == "succeeded"
    end

    @testset "every agent's name for the tool reaches the card" begin
        @test BT.mcp_msg_type("bt_process") === BT.ProcessToolMsg
        @test BT.resolve_mcp_tool("mcp__btworker__bt_process") == ("btworker", "bt_process")
        @test BT.resolve_mcp_tool("btworker_bt_process") == ("btworker", "bt_process")
        for t in ("bt_progress", "bt_dev_inspect", "bt_dev_logs", "bt_dev_memory", "bt_dev_control", "bt_dev_timings", "bt_dev_console")
            @test BT.mcp_msg_type(t) === BT.JsonToolMsg
        end
    end

    @testset "a reopened chat looks the same" begin
        message(id, name, title, status, summary) = BT.Message(id, "other", name, title, status, summary, time(), time(), nothing)
        function reopened(id)
            for m in BT.load_history(model.chat_session)
                m isa BT.ToolMsg && BT.tool_id(m) == id && return m
            end
            error("no tool $id in chat.md")
        end

        # Written by this card: title, summary and pill are in chat.md.
        live = finished(job(status = "failed", exitcode = 3), action = "wait", id = "build-1")
        live.message.id = "fresh"
        live.message.title = BT.process_title(live)
        live.message.summary = BT.process_summary(live, Any[])
        BT.append_tool(model.chat_session, live)
        m = reopened("fresh")
        @test m isa BT.ProcessToolMsg
        @test BT.tool_title(m) == "Wait for Build docs"
        @test BT.tool_summary(m) == "failed · exit 3 · 2.5 s"
        @test BT.tool_status(m) == "failed"
        # Its files are gone (an old chat, a moved folder): what chat.md says stands.
        d = BT.tool_header_dict(m, model.chat_dir)
        @test d["title"] == "Wait for Build docs" && d["status"] == "failed" && d["tool"] == "bt_process"

        # Written before this card: a bare name and a byte count on a green pill. The
        # call and the result beside the chat give the real ones back.
        old = BT.GenericMCPToolMsg(message("old", "", "bt_process", "completed", "33 lines · 2639 bytes"), "btworker", "bt_process")
        BT.append_tool(model.chat_session, old)
        stored("old", Dict("action" => "status", "id" => "build-1"), reply(job(status = "failed", exitcode = 1)))
        m = reopened("old")
        @test m isa BT.ProcessToolMsg
        m.message.chat = model
        d = BT.tool_header_dict(m, model.chat_dir)
        @test d["title"] == "Check Build docs"
        @test d["summary"] == "failed · exit 1 · 2.5 s"
        @test d["status"] == "failed"

        BT.append_tool(model.chat_session, BT.JsonToolMsg(message("js", "", "bt_dev_memory", "completed", "3 lines"), "btworker", "bt_dev_memory"))
        @test reopened("js") isa BT.JsonToolMsg
        @test BT.tool_title(reopened("js")) == "bt_dev_memory"

        # A live result needs its worker: an eval still comes back generic.
        BT.append_tool(model.chat_session, BT.JuliaEvalToolMsg(message("ev", "", "bt_julia_eval", "completed", ""), "btworker"))
        @test reopened("ev") isa BT.GenericToolMsg
    end
end
