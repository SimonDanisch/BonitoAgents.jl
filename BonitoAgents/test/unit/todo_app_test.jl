# The To-do app without a browser: its list (and that the list survives a
# restart with its numbers), and its tools as a chat's MCP reaches them, through
# `dev_request`, the entry point of the control channel. Who sees which tool is
# a correctness property: `todo_start_chat` creates chats, so only the app's own
# chat gets it.
@testitem "unit:todo_app" tags = [:unit] begin
    using BonitoAgents
    using Dates
    const BT = BonitoAgents
    const Todo = BT.BonitoTodo

    root = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    root.workers[]["wid-a"] = BT.WorkerInfo("wid-a", "Desktop", nothing,
                                            "Desktop-host", "/home/u", "julia", String[],
                                            "/home/u/projects", :online, now())
    chat = BT.add_project!(root, BT.ProjectInfo("c1", "Foo", "wid-a", joinpath(root.working_dir, "Foo"),
                                                "/home/u/projects/Foo", now(UTC)))
    chat.title[] = "Fix the parser"
    other = BT.add_project!(root, BT.ProjectInfo("c2", "Foo", "wid-a", joinpath(root.working_dir, "Foo2"),
                                                 "/home/u/projects/Foo", now(UTC)))
    bar = BT.add_project!(root, BT.ProjectInfo("c3", "Bar", "wid-a", joinpath(root.working_dir, "Bar"),
                                               "/home/u/projects/Bar", now(UTC)))
    appchat = BT.ProjectInfo("t1", "todo", "wid-a", joinpath(root.working_dir, "todo"),
                             "/home/u/projects/bonitoagents-apps/todo", now(UTC))
    appchat.app = "todo"
    BT.add_project!(root, appchat)

    app = root.apps["todo"]
    @test app isa Todo.TodoApp
    @test BT.app_chat(root, app) === appchat
    @test BT.app_of(root, appchat) === app
    @test BT.app_of(root, chat) === nothing

    tools(caller) = [t["name"] for t in BT.dev_request(root, "app_tools", Dict{String,Any}(), caller)]
    call(caller, tool; args...) =
        BT.dev_request(root, "app_call", Dict{String,Any}("tool" => tool,
            "args" => Dict{String,Any}(String(k) => v for (k, v) in args)), caller)
    text(r) = r["result"]["content"][1]["text"]

    @testset "who sees which tool" begin
        everyone = ["todo_list", "todo_add", "todo_done"]
        @test tools("c1") == everyone
        # A channel that names no chat, or a chat of someone with no account
        # (an app's state is the admins'): nothing.
        @test isempty(tools(""))
        stranger = BT.add_project!(root, BT.ProjectInfo("c9", "Baz", "wid-a", joinpath(root.working_dir, "Baz"),
                                                        "/home/u/projects/Foo", now(UTC)))
        stranger.owner = "nobody"
        @test isempty(tools("c9"))
        @test call("c9", "todo_list")["found"] == false
        @test tools("t1") == vcat(everyone, ["todo_remove", "todo_projects", "todo_start_chat"])
        # Calling an app-chat tool by name from elsewhere finds nothing, the same
        # as a name no app has.
        @test call("c1", "todo_start_chat"; todo_id = 1)["found"] == false
        @test call("c1", "no_such_tool")["found"] == false
        @test call("t1", "todo_projects")["found"] == true
    end

    @testset "chats add, list and check off" begin
        r = call("c1", "todo_add"; text = "  Write the docs  ")
        @test r["found"] && !r["result"]["isError"]
        @test text(r) == "Added to-do #1."
        t = only(app.todos[])
        @test (t.id, t.text, t.added_by) == (1, "Write the docs", "c1")
        Todo.add_todo!(app, "Ship it")                     # the user, in the pane
        @test last(app.todos[]).added_by == ""

        @test text(call("c2", "todo_list")) == "#1 [ ] Write the docs\n#2 [ ] Ship it"
        # Numbers come as floats or strings as often as integers.
        @test text(call("c2", "todo_done"; todo_id = 1.0, note = "wrote them")) == "Checked off to-do #1."
        @test text(call("c2", "todo_done"; todo_id = "1")) == "To-do #1 was already checked off."
        t1 = first(app.todos[])
        @test Todo.isdone(t1) && t1.done_by == "c2" && t1.note == "wrote them"
        @test text(call("c1", "todo_list")) == "#2 [ ] Ship it"
        full = text(call("c1", "todo_list"; include_done = true))
        @test occursin("#1 [x] Write the docs", full)
        @test occursin("by chat \"Foo\" (c2): wrote them", full)
    end

    @testset "a call it cannot do is the agent's error, with the reason" begin
        for (args, msg) in ((Dict(:todo_id => 99), "there is no to-do #99"),
                            (Dict(:todo_id => 1.5), "argument `todo_id` must be an integer"),
                            (Dict(), "missing argument `todo_id`"))
            r = call("c1", "todo_done"; args...)
            @test r["found"] && r["result"]["isError"]
            @test text(r) == "error: " * msg
        end
        r = call("c1", "todo_add"; text = "   ")
        @test r["result"]["isError"] && text(r) == "error: a to-do needs a text"
    end

    @testset "the app chat finds the folders and removes items" begin
        out = text(call("t1", "todo_projects"))
        lines = filter(l -> startswith(l, "- "), split(out, '\n'))
        # Two folders: the app's own is not a project of the user's.
        @test length(lines) == 2
        @test any(l -> occursin("path: /home/u/projects/Foo", l), lines)
        @test any(l -> occursin("path: /home/u/projects/Bar", l), lines)
        @test !occursin("bonitoagents-apps", out)
        @test occursin("worker: Desktop (online)", out)
        @test occursin("\"Fix the parser\"", out)
        @test text(call("t1", "todo_remove"; todo_id = 2)) == "Removed to-do #2."
        @test [t.id for t in app.todos[]] == [1]
    end

    @testset "the list and its numbers survive a restart" begin
        Todo.add_todo!(app, "After the removal")
        @test last(app.todos[]).id == 3                    # #2 is not handed out again
        Todo.link_chat!(app, 3, "c3")
        Todo.check_todo!(app, 1, false)                      # opened again
        again = BT.ServerState(; state_dir = root.state_dir, working_dir = root.working_dir)
        app2 = again.apps["todo"]
        @test [(t.id, t.text, Todo.isdone(t), t.chats) for t in app2.todos[]] ==
              [(1, "Write the docs", false, String[]), (3, "After the removal", false, ["c3"])]
        @test Todo.add_todo!(app2, "Next").id == 4
        # The app chat is still the app's chat.
        @test BT.app_chat(again, app2).id == "t1"
    end

    @testset "the app chat's agent is briefed, an ordinary chat's is not" begin
        @test occursin("# The To-do app", BT.agents_prompt_appendix(root, "t1"))
        @test !occursin("To-do app", BT.agents_prompt_appendix(root, "c1"))
    end

    @testset "tool declarations" begin
        names = [String(t.name) for a in values(root.apps) for t in BT.app_tools(a)]
        @test allunique(names)
        # None shadows one of BonitoMCP's own.
        @test isempty(intersect(names, [t.name for t in BT.BonitoMCP.TOOLS]))
        # The schema comes from the parameters: types, descriptions, required.
        done = only(t for t in BT.app_tools(app) if t.name === :todo_done)
        schema = BT.input_schema(done)
        @test schema["required"] == ["todo_id"]
        @test schema["properties"]["todo_id"]["type"] == "integer"
        @test schema["properties"]["note"]["type"] == "string"
    end
end
