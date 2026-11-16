# The sidebar's search (2026-11-16): chats by title or folder, the open ones
# first, then the others: closed, never used, and sessions a worker's scan found
# that no chat resumes. It reads what the server persisted, so a server started
# again on the same state folder finds the same chats under the same titles.
@testitem "unit:sidebar_search" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    dir = mktempdir()
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir())
    wid = "unit-search-worker"
    function chat!(id, title; dismissed = false, sid = nothing)
        p = BT.ProjectInfo(id, "folder-$id", wid, mktempdir(), "/w/folder-$id", BT.now(BT.UTC))
        BT.add_project!(st, p)
        p.title[] = title
        p.dismissed = dismissed
        p.resume_session_id = sid
        return p
    end
    chat!("open1", "Release notes draft"; sid = "resumed-1")
    chat!("closed1", "Release blog post"; dismissed = true)
    chat!("fresh1", "folder-fresh1")                       # never used: the folder's name
    BT.save_projects!(st)
    session(sid, prompt, kind = "session") = Dict{String,Any}("session_id" => sid, "path" => "/w/old-$sid",
        "first_prompt" => prompt, "last_used" => 1.0e9, "kind" => kind)
    st.discovered[][wid] = [session("found-1", "Release checklist"),
                            session("resumed-1", "Release notes draft, first prompt"),
                            session("sub-1", "Release subagent", "subagent"),
                            Dict{String,Any}("error" => "scan failed")]
    BT.save_discovered!(st)

    # A restart: a new state from the same folder.
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir())
    titles(hits) = [h.title for h in hits]
    r = BT.sidebar_search(st, "release")
    @test titles(r.open) == ["Release notes draft"]
    # The found session's worker isn't connected: nothing could open it now.
    @test titles(r.other) == ["Release blog post"]
    @test r.more == 0
    # Every word counts, in any case, in the title or the folder.
    @test titles(BT.sidebar_search(st, "BLOG release").other) == ["Release blog post"]
    @test isempty(BT.sidebar_search(st, "release missing").other)
    @test titles(BT.sidebar_search(st, "fresh1").other) == ["folder-fresh1"]
    @test titles(BT.sidebar_search(st, "folder-open1").open) == ["Release notes draft"]

    # The scan's sessions as results: a subagent, a scan error and a session a
    # chat resumes are none (the last is found as that chat).
    hits = filter(!isnothing, [BT.SearchHit(wid, r) for r in st.discovered[][wid]])
    @test [h.session_id for h in hits] == ["found-1", "resumed-1"]
    @test only(filter(h -> h.session_id == "found-1", hits)).title == "Release checklist"
end
