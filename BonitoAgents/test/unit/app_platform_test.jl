# Apps as plugins: an app defined outside BonitoAgents, the way an app package
# defines one (its own module, BonitoAgents' public names only), started by a
# server that is given it. And the tool machinery it relies on: parameters
# checked and converted before the app sees them, scopes as types an app can
# add to.
@testitem "unit:app_platform" tags = [:unit] begin
    using BonitoAgents
    using Dates
    const BT = BonitoAgents

    # An app package, as small as one gets. Everything it touches is public.
    module NotesPkg
        import BonitoAgents
        using BonitoAgents: AgentApp, AppContext, AppTool, Param, ToolScope, AppCall, AppError,
                            ProjectInfo, atomic_write_json, load_json_tolerant
        using Bonito: Observable

        # A scope of its own: chats in folders whose path mentions "notes".
        struct NotesFolders <: ToolScope end
        BonitoAgents.in_scope(::NotesFolders, ::AgentApp, chat::ProjectInfo) =
            occursin("notes", chat.worker_path)

        struct NotesApp <: AgentApp
            ctx::AppContext
            notes::Observable{Vector{String}}
        end
        NotesApp(ctx::AppContext) =
            NotesApp(ctx, Observable(something(load_json_tolerant(joinpath(ctx.dir, "notes.json"),
                                                                  "notes.json", Vector{String}), String[])))
        BonitoAgents.app_id(::Type{NotesApp}) = "notes"
        BonitoAgents.app_tools(::NotesApp) = [
            AppTool(:notes_add, "Add a note.",
                    (text = Param(String, "The note."), times = Param(Int, "How often.", 1),
                     weight = Param(Float64, "How much.", 1.0), loud = Param(Bool, "Shout?", false))),
            AppTool(:notes_clear, "Clear them.", (;); scope = NotesFolders()),
        ]
        function BonitoAgents.call_tool(app::NotesApp, ::Val{:notes_add}, call::AppCall)
            (; text, times, weight, loud) = call.args
            isempty(text) && throw(AppError("an empty note"))
            note = (loud ? uppercase(text) : text) * " x$times w$weight by $(call.caller.id)"
            app.notes[] = vcat(app.notes[], note)
            atomic_write_json(joinpath(app.ctx.dir, "notes.json"), app.notes[])
            return "noted"
        end
        BonitoAgents.call_tool(app::NotesApp, ::Val{:notes_clear}, ::AppCall) =
            (app.notes[] = String[]; "cleared")
    end

    state_dir = mktempdir()
    server = BT.ServerState(; state_dir, working_dir = mktempdir(), apps = (NotesPkg.NotesApp,))
    server.workers[]["w"] = BT.WorkerInfo("w", "Desk", nothing, "h", "/home/u", "julia", String[],
                                          "/home/u/p", :online, now())
    plain = BT.add_project!(server, BT.ProjectInfo("c1", "Foo", "w", mktempdir(), "/home/u/p/Foo", now(UTC)))
    notes = BT.add_project!(server, BT.ProjectInfo("c2", "Mynotes", "w", mktempdir(), "/home/u/p/notes", now(UTC)))

    tools(caller) = [t["name"] for t in BT.dev_request(server, "app_tools", Dict{String,Any}(), caller)]
    call(caller, tool; args...) =
        BT.dev_request(server, "app_call", Dict{String,Any}("tool" => tool,
            "args" => Dict{String,Any}(String(k) => v for (k, v) in args)), caller)
    text(r) = r["result"]["content"][1]["text"]

    @testset "the server runs the apps it is given" begin
        @test collect(keys(server.apps)) == ["notes"]       # and not the built-in ones
        app = server.apps["notes"]
        @test app.ctx.server === server
        @test app.ctx.dir == joinpath(state_dir, "apps", "notes")
        @test BT.app_id(app) == "notes" == BT.app_title(app)   # the title defaults to the id
        # By default the built-in ones.
        @test BT.BonitoTodo.TodoApp in BT.BUILTIN_APPS
        @test haskey(BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir()).apps, "todo")
        # Two apps with one id is a mistake to say out loud.
        @test_throws ErrorException BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                                                     apps = (NotesPkg.NotesApp, NotesPkg.NotesApp))
    end

    @testset "a scope of the app's own" begin
        @test tools("c1") == ["notes_add"]
        @test tools("c2") == ["notes_add", "notes_clear"]
        @test call("c1", "notes_clear")["found"] == false
    end

    @testset "arguments arrive checked and converted" begin
        @test text(call("c1", "notes_add"; text = "a")) == "noted"
        # Whole numbers as floats or strings, an Int for a Float64, JSON null as absent.
        @test text(call("c1", "notes_add"; text = "b", times = 2.0, weight = 3, loud = true)) == "noted"
        @test text(call("c1", "notes_add"; text = "c", times = "4", weight = nothing)) == "noted"
        @test server.apps["notes"].notes[] == ["a x1 w1.0 by c1", "B x2 w3.0 by c1", "c x4 w1.0 by c1"]
        for (args, msg) in ((Dict(), "missing argument `text`"),
                            (Dict(:text => nothing), "missing argument `text`"),
                            (Dict(:text => 1), "argument `text` must be a string"),
                            (Dict(:text => "x", :times => 1.5), "argument `times` must be an integer"),
                            (Dict(:text => "x", :loud => "yes"), "argument `loud` must be true or false"),
                            (Dict(:text => ""), "an empty note"))
            r = call("c1", "notes_add"; args...)
            @test r["result"]["isError"] && text(r) == "error: " * msg
        end
        schema = BT.input_schema(first(BT.app_tools(server.apps["notes"])))
        @test schema["required"] == ["text"]
        @test [schema["properties"][k]["type"] for k in ("text", "times", "weight", "loud")] ==
              ["string", "integer", "number", "boolean"]
        @test text(call("c2", "notes_clear")) == "cleared"
    end

    @testset "its state is its own, and survives a restart" begin
        call("c1", "notes_add"; text = "kept")
        again = BT.ServerState(; state_dir, working_dir = mktempdir(), apps = (NotesPkg.NotesApp,))
        @test again.apps["notes"].notes[] == ["kept x1 w1.0 by c1"]
    end

    @testset "chat_pane: one node or several" begin
        @test BT.pane_nodes((1, 2)) == (1, 2)
        @test BT.pane_nodes([1, 2]) == [1, 2]
        @test BT.pane_nodes(1) == (1,)
    end

    # The built-in To-do app is written as a package would be: every name of
    # BonitoAgents it uses, imported or qualified, is public.
    @testset "BonitoTodo uses public names only" begin
        src = read(joinpath(pkgdir(BonitoAgents), "src", "apps", "BonitoTodo", "BonitoTodo.jl"), String)
        imported = only(match(r"using \.\.BonitoAgents:([^\n]*(?:\n    [^\n]*)*)", src).captures)
        used = vcat(strip.(split(imported, r"[,\s]+"; keepempty = false)),
                    [m.captures[1] for m in eachmatch(r"BonitoAgents\.([A-Za-z_!]+)", src)])
        @test !isempty(used)
        @test [n for n in unique(used) if !Base.ispublic(BonitoAgents, Symbol(n))] == String[]
    end
end
