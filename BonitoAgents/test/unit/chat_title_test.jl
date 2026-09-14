# ONE source of truth for a chat's title: `ProjectInfo.title`, an Observable
# that always holds exactly what is shown (the folder name until a prompt or
# the user names it), that every view binds to (header input, homebar row,
# overview card, discovered row), and that persists itself. What this pins
# down: a write from anywhere reaches a child bound in ANY tab, lands in
# projects.json without the writer saving, and comes back identical after a
# restart — with the hook re-armed.
# The mess it replaces: each view kept its own copy, synced by whichever
# `state` a writer happened to notify, so a header could read "HOTS" (the
# folder) while the homebar of the same page showed the first-prompt title.
@testitem "unit:chat_title" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    using Dates
    const BT = BonitoAgents

    reload(root) = BT.ServerState(; state_dir = root.state_dir,
                                    working_dir = root.working_dir, worker_secret = "x")

    root = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                            worker_secret = "x")
    root.workers[]["wid-a"] = BT.WorkerInfo("wid-a", "Desktop", "ws://x", "x", nothing,
                                            "Desktop-host", "/home/u", "julia", String[],
                                            "/home/u/projects/Desktop", :online, now())
    p = BT.ProjectInfo("p1", "HOTS", "wid-a", joinpath(root.working_dir, "HOTS"),
                       "/home/u/projects/Desktop/HOTS", now(UTC))
    BT.add_project!(root, p)

    sa, sb = Bonito.Session(), Bonito.Session()
    tab_a, tab_b = copy(root, sa), copy(root, sb)   # the opening tab; the page after a reload
    shown_a = map(identity, sa, p.title)             # what each tab's header input binds to
    shown_b = map(identity, sb, p.title)
    tables_b = Ref(0)                                # tab_b's structural readers (homebar, cards)
    on(_ -> tables_b[] += 1, tab_b.projects)

    @testset "untitled: the folder name everywhere, and not in the homebar" begin
        @test p.title[] == "HOTS"
        @test !BT.titled(p)
        @test shown_a[] == "HOTS"
        @test shown_b[] == "HOTS"
        @test !BT.chat_in_sidebar(p)
        @test reload(root).projects[]["p1"].title[] == "HOTS"
        @test !BT.titled(reload(root).projects[]["p1"])
    end

    @testset "the first prompt titles it: every bound view, the table, the disk" begin
        model = BT.ChatModel(tab_a, p.server_path; project_id = "p1",
                             agent = BT.WorkerAgent(tab_a, "wid-a", "/p"))
        BT.backfill_project_title!(model, "Wie bekomme ich die ganzen player daten aus dem replay")
        @test startswith(p.title[], "Wie bekomme")
        @test BT.titled(p)
        @test shown_a[] == p.title[]
        @test shown_b[] == p.title[]
        @test tables_b[] == 1
        @test BT.chat_in_sidebar(p)
        @test reload(root).projects[]["p1"].title[] == p.title[]
        # A later prompt never retitles.
        BT.backfill_project_title!(model, "und jetzt was ganz anderes")
        @test startswith(p.title[], "Wie bekomme")
        @test tables_b[] == 1
    end

    @testset "a rename from the other tab" begin
        BT.set_project_title!(tab_b, "p1", "  HOTS renamed  ")
        @test p.title[] == "HOTS renamed"
        @test shown_a[] == "HOTS renamed"
        @test shown_b[] == "HOTS renamed"
        @test tables_b[] == 2
        @test reload(root).projects[]["p1"].title[] == "HOTS renamed"
        # Committing the same value is a no-op: no rebuild, no rewrite.
        BT.set_project_title!(tab_b, "p1", "HOTS renamed")
        @test tables_b[] == 2
        @test_throws ErrorException BT.set_project_title!(root, "no-such-project", "x")
    end

    @testset "a bare write is a complete write" begin
        p.title[] = "direct"
        @test shown_a[] == "direct"
        @test shown_b[] == "direct"
        @test tables_b[] == 3
        again = reload(root)
        @test again.projects[]["p1"].title[] == "direct"
        # …and a project loaded back from disk is hooked the same way.
        again.projects[]["p1"].title[] = "after restart"
        @test reload(again).projects[]["p1"].title[] == "after restart"
    end

    @testset "a blank edit puts the default back: folder name, out of the homebar" begin
        BT.set_project_title!(p, "   ")
        @test p.title[] == "HOTS"
        @test !BT.titled(p)
        @test shown_a[] == "HOTS"
        @test shown_b[] == "HOTS"
        @test !BT.chat_in_sidebar(p)
        @test reload(root).projects[]["p1"].title[] == "HOTS"
    end

    @testset "a closed tab's child is gone; the other tab still follows" begin
        close(sa)
        p.title[] = "after tab close"
        @test shown_a[] == "HOTS"
        @test shown_b[] == "after tab close"
    end
end
