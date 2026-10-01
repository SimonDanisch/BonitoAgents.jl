# "Add worker" shows `curl -fsSL <server>/install.sh | sh -s <credential>`: the
# credential is the script's argument, and it has to reach the Julia installer
# as that one's argument. Older commands set BONITOAGENTS_WORKER_CREDENTIAL,
# which the installer still reads when no argument comes.
@testitem "unit:install_credential_arg" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    spec = Dict{String,Any}("repo" => "r", "rev" => "main", "source_id" => "abc",
                            "bonito_url" => "u", "bonito_rev" => "master")
    if !Sys.iswindows()
        script = BT.render_install_script(read(joinpath(BT.ASSETS_DIR, "install.sh"), String),
                                          "https://team.example.com", spec)
        # Stand-ins: `curl` serves nothing, `julia` says what it was started with.
        bin = mktempdir()
        write(joinpath(bin, "curl"), "#!/bin/sh\nexit 0\n")
        write(joinpath(bin, "julia"), "#!/bin/sh\necho \"julia \$*\"\n")
        chmod(joinpath(bin, "curl"), 0o755); chmod(joinpath(bin, "julia"), 0o755)
        env = ("PATH" => bin * ":" * ENV["PATH"],)
        run_script(args...) = strip(read(pipeline(addenv(`sh -s $args`, env...); stdin = IOBuffer(script)), String))
        @test run_script("w-1a:2b") == "julia - w-1a:2b"
        @test run_script() == "julia -"          # a server on this machine: no credential
    end

    # The installer takes its first argument, else the variable older commands set.
    jl = BT.render_install_script(read(joinpath(BT.ASSETS_DIR, "install.jl"), String),
                                  "https://team.example.com", spec)
    line = only(filter(l -> startswith(l, "const CREDENTIAL"), split(jl, '\n')))
    credential(args, env) = withenv("BONITOAGENTS_WORKER_CREDENTIAL" => env) do
        m = Module()
        Core.eval(m, :(const ARGS = $args))
        Core.eval(m, Meta.parse(line))
        Core.eval(m, :CREDENTIAL)
    end
    @test credential(["w-1a:2b"], nothing) == "w-1a:2b"
    @test credential(String[], "w-old:env") == "w-old:env"
    @test credential(String[], nothing) == ""
end
