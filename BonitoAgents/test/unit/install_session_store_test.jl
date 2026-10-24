@testitem "unit:install_session_store" tags = [:unit] begin
    using BonitoAgents, SHA
    Sys.islinux() || return
    src = read(joinpath(BonitoAgents.ASSETS_DIR, "install_server.sh"), String)
    a = first(findfirst("# Valkey's official binaries", src))
    b = first(findnext("# ── Port 80", src, a))
    block = src[a:prevind(src, b)]
    dir = mktempdir()
    tools = mkpath(joinpath(dir, "tools"))
    fixtures = mkpath(joinpath(dir, "fixtures"))
    binaries = mkpath(joinpath(dir, "installed"))
    archive_root = "valkey-9.1.2-jammy-x86_64"
    package = mkpath(joinpath(dir, "package", archive_root, "bin"))
    server = "#!/bin/sh\nprintf 'Valkey server v=9.1.2\\n'\n"
    write(joinpath(package, "valkey-server"), server)
    chmod(joinpath(package, "valkey-server"), 0o755)
    archive = joinpath(fixtures, archive_root * ".tar.gz")
    run(`tar -czf $archive -C $(joinpath(dir, "package")) $archive_root`)
    sums = archive * ".sha256"
    write(sums, bytes2hex(sha256(read(archive))) * "  " * basename(archive) * "\n")
    write(joinpath(tools, "sudo"), "#!/bin/sh\nexec \"\$@\"\n")
    write(joinpath(tools, "curl"), "#!/bin/sh\nexec cp \"\$STORE_FIXTURES/\$(basename \"\$4\")\" \"\$3\"\n")
    chmod(joinpath(tools, "sudo"), 0o755)
    chmod(joinpath(tools, "curl"), 0o755)
    script = """
        set -eu
        step() { :; }
        ok() { :; }
        fail() { printf '%s\\n' "\$*" >&2; exit 1; }
        """ * block
    env = ("PATH" => tools * ":" * ENV["PATH"], "STORE_FIXTURES" => fixtures,
           "VALKEY_VERSION" => "9.1.2", "ARCH" => "amd64", "BIN_DIR" => binaries,
           "SESSION_BIN" => joinpath(binaries, "valkey-server"), "TMP" => mkpath(joinpath(dir, "tmp")))
    function install()
        output = IOBuffer()
        proc = run(pipeline(addenv(ignorestatus(`bash -s`), env...);
                            stdin = IOBuffer(script), stdout = output, stderr = output))
        return (; ok = success(proc), output = String(take!(output)))
    end
    @test install().ok
    installed = joinpath(binaries, "valkey-server")
    @test read(installed, String) == server
    @test occursin("v=9.1.2", read(`$installed --version`, String))
    rm(archive)
    @test install().ok                  # an unchanged binary needs no download
    run(`tar -czf $archive -C $(joinpath(dir, "package")) $archive_root`)
    write(sums, "0"^64 * "  " * basename(archive) * "\n")
    old = replace(server, "9.1.2" => "9.1.1")
    write(installed, old)
    rejected = install()
    @test !rejected.ok
    @test occursin("does not match its published checksum", rejected.output)
    @test read(installed, String) == old # a bad upgrade keeps the old executable
end
