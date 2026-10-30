# "Export as Markdown" for a chat reopened from disk. `load_history` brings a
# tool call back by its built-in kind only, with empty typed fields: a Bash or a
# bt_julia_eval call returns as a generic message, an edit without its old and
# new text. Their arguments and bodies are stored beside the chat. The export
# must still write the command, the edit's diff and the eval as a BonitoBook
# cell, and the file must open in BonitoBook with the agent's code as cells.
@testitem "unit:chat_export" tags = [:unit] begin
    using BonitoAgents, BonitoBook
    import JSON
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    root = mktempdir()
    p = BT.ProjectInfo("ex1", "Export Test", "w1", root, root, BT.now(BT.UTC))
    state.projects[][p.id] = p
    model = BT.ChatModel(state, root; project_id = p.id, agent = BT.WorkerAgent(state, "w1", root))

    # A call as `persist_tool_content!` stores it and `load_history` rebuilds it.
    function restored(id, kind, name, title, raw, content)
        open(BT.tool_file(model.chat_dir, id), "w") do io
            JSON.print(io, Dict("content" => Any[BT.tool_content_to_dict(c) for c in content],
                                "rawInput" => raw))
        end
        m = BT.builtin_msg_type(kind, name)(
            BT.Message(id, kind, name, title, "completed", "", time(), time(), nothing))
        m.message.chat = model
        return m
    end

    file = joinpath(root, "hello.jl")
    # Code with a fence of its own: the cell's fence has to grow past it.
    code = "doc = \"\"\"\n```\nnot the end\n```\n\"\"\"\nlength(doc)"
    bash = restored("toolu_bash", "execute", "Bash", "cat hello.jl",
        Dict("command" => "cat hello.jl", "description" => "Show the file"),
        [ACP.TextContent("println(\"hi\")\n")])
    # claude-agent-acp folds an edit's diff into its text result.
    edit = restored("toolu_edit", "edit", "Edit", "Edit hello.jl",
        Dict("file_path" => file, "old_string" => "println(\"hi\")", "new_string" => "println(\"hello\")"),
        [ACP.TextContent("The file $(file) has been updated successfully.")])
    # What it printed, then the value's handle with its repr; this worker
    # predates `repr_mime`, so the repr is text.
    eval1 = restored("toolu_eval1", "other", "bt_julia_eval", "bt_julia_eval",
        Dict("code" => code, "env_path" => "/w/proj", "worker" => "Laptop"),
        [ACP.TextContent("\e[36m\e[1m[ \e[22m\e[39m\e[36m\e[1mInfo: \e[22m\e[39mcounting"),
         ACP.TextContent("{\"remote_ref\":\"pre/abc\",\"errored\":false,\"repr\":\"27\"}")])
    # A plot: its repr is the display's markup, for the agent.
    eval2 = restored("toolu_eval2", "other", "bt_julia_eval", "bt_julia_eval",
        Dict("code" => "plot = heatmap(rand(4, 4))\n"),
        [ACP.TextContent("{\"remote_ref\":\"pre/def\",\"errored\":false," *
                         "\"repr\":\"<div class=\\\"fig\\\">heatmap</div>\",\"repr_mime\":\"text/html\"}")])
    # An image: the PNG it was saved to, and a text repr.
    eval3 = restored("toolu_eval3", "other", "bt_julia_eval", "bt_julia_eval",
        Dict("code" => "rand(RGB, 4, 4)"),
        [ACP.TextContent("shown: /w/proj/img.png (image/png, 1 KB)"),
         ACP.TextContent("{\"remote_ref\":\"pre/ghi\",\"errored\":false," *
                         "\"repr\":\"4×4 Matrix{RGB{Float64}}\",\"repr_mime\":\"text/plain\"}")])
    shown = restored("toolu_show", "other", "bt_show", "bt_show",
        Dict("path" => "/w/proj/loss.png", "title" => "Loss after 200 epochs"),
        [ACP.TextContent("shown: /w/proj/loss.png (image/png, 48.2KB)")])
    @test eval1 isa BT.GenericToolMsg && bash isa BT.GenericToolMsg   # what chat.md gives back
    @test edit isa BT.EditToolMsg && isempty(edit.old_string)

    append!(model.msgs_store, BT.ChatMsg[
        BT.UserMsg("please patch the greeting"),
        BT.ThoughtMsg("t1", "Look at the file first.\n\nThen patch it."),
        BT.AgentMsg("a1", "Patching **hello.jl**."),
        bash, edit, eval1, eval2, eval3, shown,
        BT.TodoListMsg("todo1", [ACP.PlanEntry("Patch hello.jl", "", "completed"),
                                 ACP.PlanEntry("Run the tests", "", "pending")], time(), time(), nothing),
    ])
    md = BT.export_chat_markdown(model)

    @testset "the header" begin
        @test startswith(md, "# Export Test\n")
        @test occursin("Files are linked by path, not captured as snapshots", md)
        @test occursin("This file is a BonitoBook notebook", md)
        @test occursin("each of its 3 Julia evals", md)
    end

    @testset "messages" begin
        @test occursin("## 🧑 User\n\nplease patch the greeting\n", md)
        @test occursin("### 💭 Reasoning\n\n> Look at the file first.\n>\n> Then patch it.\n", md)
        @test occursin("## 🤖 Assistant\n\nPatching **hello.jl**.\n", md)
        @test occursin("- [x] Patch hello.jl\n- [ ] Run the tests\n", md)
    end

    @testset "a restored Bash call writes its command" begin
        @test occursin("### 🔧 Bash · completed", md)
        @test occursin("_Show the file_\n\n```sh\ncat hello.jl\n```\n", md)
        @test occursin("```text\nprintln(\"hi\")\n```", md)
    end

    @testset "a restored edit writes its diff, not the result text" begin
        @test occursin("Edited `$(file)` ⚠️", md)
        @test occursin("```diff\n-println(\"hi\")\n+println(\"hello\")\n```", md)
        @test !occursin("has been updated successfully", md)
    end

    @testset "a restored eval writes a BonitoBook cell and its output" begin
        @test occursin("Ran in env `/w/proj` on worker `Laptop`", md)
        @test occursin("````julia (editor=true, logging=false, output=true, id=1)\n$(code)\n````", md)
        # The output with its ANSI codes stripped, then the value.
        @test occursin("```text\n[ Info: counting\n```\n\n```text\n27\n```", md)
        @test !occursin("remote_ref", md)                            # the live handle stays out
        @test occursin("an app or plot, was shown live in the chat", md)
        @test !occursin("<div", md)                                  # never its markup
        @test occursin("Shown: `/w/proj/img.png` ⚠️\n\n```text\n4×4 Matrix{RGB{Float64}}\n```", md)
        # The stored messages stay as `load_history` made them.
        @test eval1 isa BT.GenericToolMsg && BT.tool_title(eval1) == "bt_julia_eval"
    end

    @testset "a shown file with the agent's title" begin
        @test occursin("### 🔧 bt_show · completed\n\n_Loss after 200 epochs_\n\nFile: `/w/proj/loss.png` ⚠️\n", md)
        @test !occursin("Shown: `/w/proj/loss.png`", md)          # named once, by the input
    end

    @testset "BonitoBook opens the export with the evals as cells" begin
        cells = BonitoBook.markdown2book(BonitoBook.Markdown.parse(md))
        julia = [c for c in cells if c.language == "julia"]
        @test [c.source for c in julia] == [code, "plot = heatmap(rand(4, 4))", "rand(RGB, 4, 4)"]
        @test allunique(c.id for c in cells)
        @test any(c -> c.language == "markdown" && occursin("please patch the greeting", c.source), cells)
    end

    @testset "a chat without evals is no notebook" begin
        empty!(model.msgs_store)
        push!(model.msgs_store, BT.UserMsg("hi"))
        @test !occursin("BonitoBook", BT.export_chat_markdown(model))
    end

    @testset "current plans survive the taskbar-to-history transfer" begin
        s = BT.shared(model)
        plan = BT.TodoListMsg([ACP.PlanEntry("Export the current plan", "", "pending")])
        s.live_todo[] = plan
        @test occursin("- [ ] Export the current plan", BT.export_chat_markdown(model))
        @test plan.finished_at === nothing # exporting must not finish active work
        @test !(plan in s.msgs_store)

        bar = BT.chat_taskbar(model)
        bar.items[] = Any[plan]
        s.live_todo[] = nothing # finalize! cleared the live pointer, before send!
        @test occursin("- [ ] Export the current plan", BT.export_chat_markdown(model))
        push!(s.msgs_store, plan) # history append, before removal from the bar
        @test count("- [ ] Export the current plan", BT.export_chat_markdown(model)) == 1
        bar.items[] = Any[]
        @test count("- [ ] Export the current plan", BT.export_chat_markdown(model)) == 1
    end
end
