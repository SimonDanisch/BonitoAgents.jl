@testitem "unit:refresh_broken_titles" tags = [:unit] begin

# Regression test for the Rescan "repair broken titles" sweep.
#
# Backstory: project titles are backfilled exactly once from the first user
# message (gated by `p.title === nothing`). When the wrapper-stripping
# regex in `meaningful_title` had bugs (no support for `<tag attr="x">` or
# `<tag/>`), the broken title got saved and pinned forever — Rescan didn't
# touch it. The Rescan button now sweeps projects on the just-scanned
# worker, finds the leaked titles, and re-derives them from chat.md.

using Test
import BonitoAgents
const BT = BonitoAgents

# Helpers — build a chat.md with a given first-user prompt, set a project
# with a leaked title pointing at that chat_dir, then exercise the sweep.

function build_chat_md!(chat_dir::String, prompt::String)
    mkpath(chat_dir)
    open(joinpath(chat_dir, "chat.md"), "w") do io
        println(io, "+++")
        println(io, "session_id = \"test\"")
        println(io, "cwd = \"/tmp\"")
        println(io, "created = \"2026-06-09T00:00:00\"")
        println(io, "+++")
        println(io)
        println(io, "!!! user \"2026-06-09T00:00:00\"")
        for line in split(prompt, '\n')
            println(io, "    ", line)
        end
        println(io)
    end
end

function fresh_state()
    state_dir   = mktempdir()
    working_dir = mktempdir()
    BT.ServerState(; state_dir = state_dir,
                     working_dir = working_dir,
                     worker_secret = "x")
end

# Synthesize a project with a known-broken title + write chat.md with a
# REAL prompt. Returns the project + the chat_dir we wrote.
function add_project!(state::BT.ServerState, worker_id::String;
                     pid::String, name::String, title::String, prompt::String)
    chat_dir = BT.chat_storage_dir(state, pid, mktempdir())
    build_chat_md!(chat_dir, prompt)
    p = BT.ProjectInfo(pid, name, worker_id, "", chat_dir, BT.now(BT.UTC))
    p.title = title
    # chat_storage_dir keys off project_id + server_path. We need
    # `chat_storage_dir(state, pid, p.server_path)` (the same call the
    # sweep makes) to return the SAME path we just wrote chat.md into. So
    # use the new_dir layout: state_dir/chats/<pid>/.
    @assert chat_dir == joinpath(state.state_dir, "chats", pid)  "chat_storage_dir layout drift; test setup invalid"
    state.projects[][pid] = p
    return p, chat_dir
end

@testset "refresh_broken_titles! repairs leaked-wrapper titles" begin

    @testset "leaked attribute-style title → cleaned from prompt" begin
        state = fresh_state()
        wid   = "wA"
        p, _  = add_project!(state, wid;
            pid    = "p-attr-1",
            name   = "ClaudeExperiments",
            title  = "<command-args foo=\"bar\"></command-args> the real prompt",
            prompt = "<command-args foo=\"bar\"></command-args>\nthe real prompt")
        n = BT.refresh_broken_titles!(state, wid)
        @test n == 1
        @test p.title == "the real prompt"
    end

    @testset "leaked self-closing title → cleaned" begin
        state = fresh_state()
        wid   = "wA"
        p, _  = add_project!(state, wid;
            pid    = "p-self-1",
            name   = "X",
            title  = "<command-args/> the rest",
            prompt = "<command-args/>\nthe rest")
        n = BT.refresh_broken_titles!(state, wid)
        @test n == 1
        @test p.title == "the rest"
    end

    @testset "leaked ide_selection (no closer) → title cleared if prompt also unparseable" begin
        # The exact 2026-06-09 screenshot case: `<ide_selection>The user
        # selected the lines 1 to 264 from foo.jl …` has no closer, so
        # the new regex returns nothing on both the saved title AND the
        # original prompt. The sweep MUST clear `p.title` so the next
        # real user message can backfill cleanly.
        state = fresh_state()
        wid   = "wA"
        leaked = "<ide_selection>The user selected the lines 1 to 264 from /sim/foo.jl: incl…"
        p, _   = add_project!(state, wid;
            pid    = "p-ide-1",
            name   = "RayDemo",
            title  = leaked,
            prompt = "<ide_selection>The user selected the lines 1 to 264 from /sim/foo.jl: include(\"foo\")")
        n = BT.refresh_broken_titles!(state, wid)
        @test n == 1
        @test p.title === nothing
    end

    @testset "leaked title + real prompt after the wrapper → cleaned" begin
        state = fresh_state()
        wid   = "wA"
        p, _  = add_project!(state, wid;
            pid    = "p-mix-1",
            name   = "Foo",
            title  = "<local-command-caveat>Caveat: blah</local-command-caveat>",
            prompt = "<local-command-caveat>Caveat: blah</local-command-caveat>\nDoes Lava run all examples?")
        n = BT.refresh_broken_titles!(state, wid)
        @test n == 1
        @test p.title == "Does Lava run all examples?"
    end

    @testset "clean title is left alone (no chat.md read, no churn)" begin
        state = fresh_state()
        wid   = "wA"
        # Don't even write chat.md — confirms we never touch a clean title.
        p = BT.ProjectInfo("p-ok-1", "Y", wid, "", "", BT.now(BT.UTC))
        p.title = "An actual, clean title"
        state.projects[][p.id] = p
        n = BT.refresh_broken_titles!(state, wid)
        @test n == 0
        @test p.title == "An actual, clean title"
    end

    @testset "nil title is left alone (no chat history yet)" begin
        state = fresh_state()
        wid   = "wA"
        p = BT.ProjectInfo("p-nil-1", "Z", wid, "", "", BT.now(BT.UTC))
        state.projects[][p.id] = p
        n = BT.refresh_broken_titles!(state, wid)
        @test n == 0
        @test p.title === nothing
    end

    @testset "only touches projects on the scanned worker" begin
        state = fresh_state()
        add_project!(state, "wA"; pid="pA", name="A",
                     title="<command-args/> a",
                     prompt="<command-args/>\nprompt A")
        pB, _ = add_project!(state, "wB"; pid="pB", name="B",
                              title="<command-args/> b",
                              prompt="<command-args/>\nprompt B")
        # Rescan only wA; B stays broken.
        n = BT.refresh_broken_titles!(state, "wA")
        @test n == 1
        @test state.projects[]["pA"].title == "prompt A"
        @test state.projects[]["pB"].title == "<command-args/> b"
    end

    @testset "saved to projects.json so the fix survives a restart" begin
        state = fresh_state()
        wid   = "wA"
        p, _  = add_project!(state, wid;
            pid    = "p-persist-1",
            name   = "Bar",
            title  = "<command-args/> survived",
            prompt = "<command-args/>\nsurvived restart")
        BT.refresh_broken_titles!(state, wid)
        @test p.title == "survived restart"

        # Re-load state from disk → title still clean.
        state2 = BT.ServerState(; state_dir = state.state_dir,
                                  working_dir = state.working_dir,
                                  worker_secret = "x")
        BT.load_projects!(state2)
        @test state2.projects[]["p-persist-1"].title == "survived restart"
    end
end

end
