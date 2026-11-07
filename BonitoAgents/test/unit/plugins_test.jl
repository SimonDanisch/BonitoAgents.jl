# Which packages of the active environment load as plugins.
@testitem "unit:plugins" tags = [:unit] begin
    import BonitoAgents as BT

    builtin = BT.registered_apps()

    @testset "no active project, or one that isn't written yet: no plugins" begin
        @test BT.load_plugins!(nothing) == builtin
        # The desktop app's data-dir project on a first start (the app crashed here).
        @test BT.load_plugins!(joinpath(mktempdir(), "Project.toml")) == builtin
    end

    @testset "a dependency without the plugin marker isn't loaded" begin
        project = joinpath(mktempdir(), "Project.toml")
        write(project, """
            [deps]
            Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
            """)
        @test BT.load_plugins!(project) == builtin
        @test !BT.plugin_marker(joinpath(dirname(dirname(Base.locate_package(
            Base.PkgId(Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), "Dates")))), "Project.toml"))
    end
end
