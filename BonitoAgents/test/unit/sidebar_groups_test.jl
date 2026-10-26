# The sidebar names its groups on their first rows (the apps' chats, the active
# ones, the rest), and only when there is more than the rest to set apart.
@testitem "unit:sidebar_groups" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    @test isempty(BT.sidebar_groups(Pair{String,Symbol}[]))
    @test isempty(BT.sidebar_groups(["a" => :other, "b" => :other]))
    @test BT.sidebar_groups(["x" => :active, "y" => :active, "a" => :other, "b" => :other]) ==
          Dict("x" => "Active", "a" => "Other chats")
    @test BT.sidebar_groups(["x" => :active]) == Dict("x" => "Active")
    @test BT.sidebar_groups(["t" => :app, "x" => :active, "a" => :other]) ==
          Dict("t" => "Apps", "x" => "Active", "a" => "Other chats")
    @test BT.sidebar_groups(["t" => :app, "a" => :other]) == Dict("t" => "Apps", "a" => "Other chats")

    # An app's chat is pinned under Apps even while its turn runs.
    p = BT.ProjectInfo("p1", "todo", "w", "/s", "/w", BT.now(BT.UTC))
    @test BT.sidebar_group(p, :active) === :active
    p.app = "todo"
    @test BT.sidebar_group(p, :active) === :app
    @test BT.sidebar_group(p, :online) === :app

    # Among the other chats, the one whose turn ended last comes first: a chat
    # that just went quiet stays next to the active ones instead of dropping to
    # its name's place. Chats without a recorded turn follow by
    # name.
    q(name) = BT.ProjectInfo(name, name, "w", "/s", "/w", BT.now(BT.UTC))
    chats = [q("alpha"), q("beta"), q("gamma"), q("delta")]
    ended = Dict("gamma" => 200.0, "beta" => 100.0)
    order = sort(chats; by = c -> BT.sidebar_rank(:other, get(ended, c.id, 0.0), c))
    @test [c.name for c in order] == ["gamma", "beta", "alpha", "delta"]
    # The groups still come first.
    @test BT.sidebar_rank(:active, 0.0, q("zeta")) < BT.sidebar_rank(:other, 300.0, q("aaa"))
    @test BT.sidebar_rank(:app, 0.0, q("zeta")) < BT.sidebar_rank(:active, 300.0, q("aaa"))

    # A turn's end is recorded when the chat goes from busy to idle.
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    cwd = mktempdir()
    st.projects[]["proj"] = BT.ProjectInfo("proj", "name", "w1", cwd, cwd, BT.now(BT.UTC))
    model = BT.ChatModel(st, cwd; project_id = "proj", agent = BT.WorkerAgent(st, "w1", "/p"))
    model.busy_active[] = true
    @test !haskey(st.turns_ended, "proj")
    model.busy_active[] = false
    @test 0 <= time() - st.turns_ended["proj"] < 5

    # Idle re-broadcasts and tab reloads must not count as new activity.
    last_ended = st.turns_ended["proj"]
    restarted = BT.ServerState(; state_dir = st.state_dir, working_dir = st.working_dir)
    @test restarted.turns_ended["proj"] == last_ended
    model.busy_active[] = false
    @test st.turns_ended["proj"] == last_ended

    # Restarting restores the hot list, including the exact completion times.
    # Entries from before this feature have no timestamp and still load.
    for c in chats
        st.projects[][c.id] = c
    end
    merge!(st.turns_ended, ended)
    BT.save_projects!(st)
    restored = BT.ServerState(; state_dir = st.state_dir, working_dir = st.working_dir)
    @test restored.turns_ended == st.turns_ended
    order = sort(collect(values(restored.projects[]));
        by = c -> BT.sidebar_rank(:other, get(restored.turns_ended, c.id, 0.0), c))
    @test [c.id for c in order] == ["proj", "gamma", "beta", "alpha", "delta"]

    # Older projects.json files remain compatible.
    import JSON
    entries = JSON.parsefile(BT.projects_file(st))
    for entry in entries
        delete!(entry, "last_turn_ended")
    end
    BT.atomic_write_json(BT.projects_file(st), entries)
    legacy = BT.ServerState(; state_dir = st.state_dir, working_dir = st.working_dir)
    @test Set(keys(legacy.projects[])) == Set(keys(st.projects[]))
    @test isempty(legacy.turns_ended)
end
