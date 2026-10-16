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
end
