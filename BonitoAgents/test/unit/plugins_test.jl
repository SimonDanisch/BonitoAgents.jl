# Which packages of the active environment load as plugins.
@testitem "unit:plugins" tags = [:unit] begin
    import BonitoAgents as BT

    @testset "no active project, or one that isn't written yet: no plugins" begin
        @test BT.load_plugins!(nothing) == ()
        # The desktop app's data-dir project on a first start (the app crashed here).
        @test BT.load_plugins!(joinpath(mktempdir(), "Project.toml")) == ()
    end

    @testset "a dependency without the plugin marker isn't loaded" begin
        project = joinpath(mktempdir(), "Project.toml")
        write(project, """
            [deps]
            Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
            """)
        @test BT.load_plugins!(project) == ()
        @test !BT.plugin_marker(joinpath(dirname(dirname(Base.locate_package(
            Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates")))), "Project.toml"))
    end

    @testset "a registered app of a package that is no plugin doesn't start with a server" begin
        # fixtures/HelloApp registers its app when it loads, as a chat's
        # `bt_load_app` would load it, but has no marker. A server started in
        # the same process afterwards must not run it.
        hello = Base.require(Base.PkgId(Base.UUID("564b8dfd-92fb-49f9-a20f-8b12c6435fc7"), "HelloApp"))
        @test hello.Hello in BT.registered_apps()
        @test BT.apps_of((hello,)) == (hello.Hello,)
        # The test environment, where HelloApp is a direct dependency.
        @test !(hello.Hello in BT.load_plugins!(Base.active_project()))
    end
end
