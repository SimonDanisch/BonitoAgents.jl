# Behind Caddy + Authelia the server takes the proxy's word for who a request is
# from, and owns the proxy's view of people (Authelia's users database) and
# machines (the Caddyfile's worker credentials). Everything here is pinned
# without the real proxy: fake `caddy`/`authelia` binaries and a recording
# stand-in for Caddy's admin API.
@testitem "unit:proxy_auth identities" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, HTTP, JSON, Dates

    req(headers::Pair...) = HTTP.Request("GET", "/", collect(headers))

    local_auth = BT.LocalAuth(BT.User("simon", "", "simon", ["admins"]))
    @test BT.request_user(local_auth, req()) === local_auth.user
    @test BT.worker_credential(local_auth, req(), Dict{String,BT.WorkerCredential}()) == ""
    @test BT.default_owner(local_auth) == "simon"

    dir = mktempdir()
    @test BT.auth_mode(dir) isa BT.LocalAuth
    write(joinpath(dir, "proxy.json"), JSON.json(Dict(
        "domain" => "team.example.com", "auth_domain" => "auth.team.example.com", "admin" => "bob",
        "caddyfile" => joinpath(dir, "Caddyfile"), "users_file" => joinpath(dir, "users.yml"),
        "written_by_a_newer_installer" => 1)))
    auth = BT.auth_mode(dir)
    @test auth isa BT.ProxyAuth
    @test auth.config.port == 8038 && auth.config.authelia_port == 9091 && !auth.config.smtp
    @test auth.config.tls == "acme" && auth.config.https_port == 443
    @test BT.default_owner(auth) == "bob"
    # The proxy key is made once, kept private, and the same after a restart.
    @test length(auth.key) == 64 && BT.auth_mode(dir).key == auth.key
    @test filemode(joinpath(dir, "proxy_key")) & 0o777 == 0o600
    @test_throws ErrorException BT.ProxyAuth(auth.config, "")
    # What Caddy forwards carries the key; anything else carries no identity.
    via_caddy(headers::Pair...) = req(BT.PROXY_KEY_HEADER => auth.key, headers...)
    @test BT.request_user(auth, req("Remote-User" => "root", "Remote-Groups" => "admins")) === nothing
    @test BT.request_user(auth, req(BT.PROXY_KEY_HEADER => "0"^64, "Remote-User" => "root")) === nothing

    # No identity means the request did not come through Authelia.
    @test BT.request_user(auth, via_caddy()) === nothing
    @test BT.request_user(auth, via_caddy("Remote-User" => "  ")) === nothing
    alice = BT.request_user(auth, via_caddy("Remote-User" => "alice", "Remote-Groups" => "admins, dev,",
                                            "Remote-Email" => "a@example.com", "Remote-Name" => "Alice A"))
    @test (alice.name, alice.email, alice.display_name, alice.groups) ==
          ("alice", "a@example.com", "Alice A", ["admins", "dev"])
    @test BT.is_admin(alice)
    carol = BT.request_user(auth, via_caddy("Remote-User" => "carol"))
    @test carol.display_name == "carol" && isempty(carol.groups) && !BT.is_admin(carol)

    # A worker is admitted by the credential Caddy checked, and only one the
    # server still knows: a revoked credential is refused even if Caddy lags.
    cred = BT.WorkerCredential("w-1", "\$2a\$14\$h", "bob", DateTime(2026, 9, 1))
    creds = Dict("w-1" => cred)
    @test BT.worker_credential(auth, via_caddy("Remote-User" => "w-1"), creds) == "w-1"
    @test BT.worker_credential(auth, via_caddy("Remote-User" => "w-2"), creds) === nothing
    @test BT.worker_credential(auth, via_caddy(), creds) === nothing
    @test BT.worker_credential(auth, req("Remote-User" => "w-1"), creds) === nothing   # not via Caddy
    back = BT.WorkerCredential(JSON.parse(JSON.json(Dict(cred))))
    @test (back.name, back.hash, back.owner, back.created) == (cred.name, cred.hash, cred.owner, cred.created)

    @test BT.is_loopback("127.0.0.1") && BT.is_loopback("localhost") && BT.is_loopback("::1")
    @test !BT.is_loopback("0.0.0.0")
    @test_throws ErrorException BT.serve(; host = "0.0.0.0", port = 0, state_dir = mktempdir(),
                                         working_dir = mktempdir())
end

@testitem "unit:proxy_auth rendering" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, Dates

    cfg = BT.ProxyConfig(; domain = "team.example.com", auth_domain = "auth.team.example.com",
                         admin = "bob", caddyfile = "/x/Caddyfile", users_file = "/x/users.yml")
    creds = [BT.WorkerCredential("w-b", "\$2a\$14\$hb", "bob", now()),
             BT.WorkerCredential("w-a", "\$2a\$14\$ha", "bob", now())]
    auth = BT.ProxyAuth(cfg, "k3y")
    cf = BT.render_caddyfile(auth, creds)
    # The admin API is off, and every way to the server adds the key.
    @test occursin("\tadmin off\n", cf)
    @test count("header_up X-BonitoAgents-Proxy k3y", cf) == 3
    # Clients cannot claim an identity: Caddy drops whatever they send.
    for h in ("Remote-User", "Remote-Groups", "Remote-Email", "Remote-Name")
        @test occursin("request_header -$h", cf)
    end
    @test occursin("basic_auth {\n\t\t\tw-a \$2a\$14\$ha\n\t\t\tw-b \$2a\$14\$hb\n\t\t}", cf)
    @test occursin("header_up Remote-User {http.auth.user.id}", cf)
    @test occursin("@public path /install /install.sh /install.ps1 /install.jl /invite/*", cf)
    @test occursin("forward_auth 127.0.0.1:9091 {\n\t\t\turi /api/authz/forward-auth", cf)
    @test occursin("reverse_proxy 127.0.0.1:8038 {", cf)
    @test occursin("\nauth.team.example.com {\n\treverse_proxy 127.0.0.1:9091\n}", cf)
    @test !occursin("\temail ", cf)
    @test occursin("\temail ops@example.com\n",
                   BT.render_caddyfile(BT.ProxyAuth(BT.ProxyConfig(; domain = "d", auth_domain = "a", admin = "b",
                       caddyfile = "c", users_file = "u", acme_email = "ops@example.com"), "k3y"), creds))
    # No credential issued yet: `/w` refuses everyone rather than admitting all.
    cf0 = BT.render_caddyfile(auth, BT.WorkerCredential[])
    @test !occursin("basic_auth", cf0)
    @test occursin("respond \"no worker credentials issued\" 403", cf0)

    y = BT.render_users_yaml([BT.Account("o'neil", "Bob O'Neil", "b@example.com", String[], true, "\$argon2id\$h"),
                              BT.Account("alice", "Alice", "", ["admins"], false, "\$argon2id\$a")])
    @test occursin("users:\n  'alice':\n    disabled: false\n    displayname: 'Alice'\n", y)
    @test occursin("  'o''neil':\n    disabled: true\n    displayname: 'Bob O''Neil'\n", y)
    @test occursin("    password: '\$argon2id\$h'\n", y)
    @test occursin("    groups: []\n", y)
    @test occursin("    groups:\n      - 'admins'\n", y)
    @test occursin("users: {}", BT.render_users_yaml(BT.Account[]))
    a = BT.Account("o'neil", "Bob", "b@x", ["members"], true, "\$argon2id\$h")
    b = BT.Account(Dict(a))
    @test (b.name, b.display_name, b.email, b.groups, b.disabled, b.password_hash) ==
          (a.name, a.display_name, a.email, a.groups, a.disabled, a.password_hash)
end

@testitem "unit:proxy_auth visibility" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, Dates

    admin  = BT.User("bob", "", "bob", ["admins"])
    member = BT.User("carol", "", "carol", ["members"])
    p = BT.ProjectInfo("p1", "proj", "w1", "/s", "/w", now())
    w = BT.WorkerInfo("w1", "Box", nothing, "box", "/home/c", "julia", String[], "/p", :online, now())
    @test p.owner == "" && w.owner == ""
    @test BT.visible(admin, p) && BT.visible(admin, w)
    @test !BT.visible(member, p) && !BT.visible(member, w)
    p.owner = "carol"; w.owner = "carol"
    @test BT.visible(member, p) && BT.visible(member, w)
    @test BT.visible(nothing, p)   # the server's own view

    # Records from before owners existed belong to the default owner.
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                          auth = BT.LocalAuth(admin))
    q = BT.ProjectInfo("p2", "proj2", "w1", "/s2", "/w2", now())
    st.projects[]["p2"] = q
    BT.save_projects!(st)
    st2 = BT.ServerState(; state_dir = st.state_dir, working_dir = st.working_dir,
                           auth = BT.LocalAuth(admin))
    @test st2.projects[]["p2"].owner == "bob"
end

@testitem "unit:proxy_auth accounts and credentials" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, HTTP, JSON

    if Sys.isunix()
        # Stand-ins for the two binaries: Authelia's generator prints a password
        # and its digest; Caddy's "hash" embeds the password, which proves it
        # arrived on stdin (and never on a command line).
        bin = mktempdir()
        write(joinpath(bin, "authelia"),
              "#!/bin/sh\n[ \"\$1\" = storage ] && exec $(joinpath(@__DIR__, "..", "fixtures", "fake_authelia_storage.sh")) \"\$@\"\necho 'Random Password: pw-123'\necho 'Digest: \$argon2id\$fake'\n")
        # `adapt` (the check before a Caddyfile is swapped in) rejects a file that
        # contains REJECT.
        write(joinpath(bin, "caddy"), """
            #!/bin/sh
            case "\$1" in
                hash-password) read pw; echo "\\\$2a\\\$14\\\$\$pw" ;;
                adapt) if grep -q REJECT "\$3"; then echo "Error: \$3:1: REJECT is no directive" >&2; exit 1; fi ;;
            esac
            """)
        chmod(joinpath(bin, "authelia"), 0o755); chmod(joinpath(bin, "caddy"), 0o755)
        dir = mktempdir()
        write(joinpath(dir, "proxy.json"), JSON.json(Dict(
            "domain" => "team.example.com", "auth_domain" => "auth.team.example.com", "admin" => "bob",
            "caddyfile" => joinpath(dir, "Caddyfile"), "users_file" => joinpath(dir, "users.yml"),
            "caddy_bin" => joinpath(bin, "caddy"), "authelia_bin" => joinpath(bin, "authelia"))))
        begin
            st = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.auth_mode(dir))
            bob = BT.add_account!(st, "bob"; groups = ["admins"])
            # A password and an authenticator, registered by the server: nobody
            # has to confirm who they are by mail to set one up.
            @test bob.password == "pw-123"
            @test startswith(bob.authenticator.uri, "otpauth://totp/team.example.com:bob?")
            @test bob.authenticator.qr[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]
            @test isfile(joinpath(dir, "Caddyfile")) && !isfile(joinpath(dir, "Caddyfile.new"))
            @test BT.add_account!(st, "alice"; display_name = "Alice", email = "a@x").password == "pw-123"
            @test_throws ErrorException BT.add_account!(st, "alice")
            @test_throws ErrorException BT.add_account!(st, "../evil")
            # An account whose authenticator could not be registered does not stay:
            # nobody could log in with it.
            broken = joinpath(bin, "authelia-broken")
            write(broken, "#!/bin/sh\n[ \"\$1\" = storage ] && { echo 'database is locked' >&2; exit 1; }\n" *
                          "echo 'Random Password: pw-123'\necho 'Digest: \$argon2id\$fake'\n")
            chmod(broken, 0o755)
            bdir = mktempdir()
            write(joinpath(bdir, "proxy.json"), JSON.json(Dict(
                "domain" => "team.example.com", "auth_domain" => "auth.team.example.com", "admin" => "bob",
                "caddyfile" => joinpath(bdir, "Caddyfile"), "users_file" => joinpath(bdir, "users.yml"),
                "caddy_bin" => joinpath(bin, "caddy"), "authelia_bin" => broken)))
            bst = BT.ServerState(; state_dir = bdir, working_dir = mktempdir(), auth = BT.auth_mode(bdir))
            failed = try BT.add_account!(bst, "zed"); nothing catch e; e end
            @test failed isa ErrorException && occursin("database is locked", failed.msg)   # Authelia's own word
            @test !haskey(bst.accounts[], "zed") && !occursin("zed", read(joinpath(bdir, "users.yml"), String))
            users = read(joinpath(dir, "users.yml"), String)
            @test occursin("'alice':", users) && occursin("'bob':", users)
            @test occursin("password: '\$argon2id\$fake'", users)
            @test filemode(joinpath(dir, "accounts.json")) & 0o777 == 0o600
            @test filemode(joinpath(dir, "users.yml")) & 0o777 == 0o600

            # The server keeps an admin who can log in.
            @test_throws ErrorException BT.set_account_admin!(st, "bob", false)
            @test_throws ErrorException BT.set_account_disabled!(st, "bob", true)
            @test_throws ErrorException BT.remove_account!(st, "bob")
            BT.set_account_admin!(st, "alice", true)
            BT.set_account_disabled!(st, "bob", true)
            @test occursin("'bob':\n    disabled: true", read(joinpath(dir, "users.yml"), String))
            @test_throws ErrorException BT.set_account_disabled!(st, "alice", true)
            BT.set_account_disabled!(st, "bob", false)
            BT.remove_account!(st, "alice")
            @test !occursin("'alice':", read(joinpath(dir, "users.yml"), String))

            cred = BT.add_worker_credential!(st, "bob")
            name, password = split(cred, ':')
            @test startswith(name, "w-") && length(password) == 48
            @test st.worker_credentials[][name].hash == "\$2a\$14\$" * password
            @test st.worker_credentials[][name].owner == "bob"
            @test occursin("\t\t\t$(name) \$2a\$14\$$(password)\n", read(joinpath(dir, "Caddyfile"), String))
            @test filemode(joinpath(dir, "worker_credentials.json")) & 0o777 == 0o600

            # A restart finds everything as it was.
            st2 = BT.ServerState(; state_dir = dir, working_dir = st.working_dir, auth = BT.auth_mode(dir))
            @test sort!(collect(keys(st2.accounts[]))) == ["bob"]
            @test haskey(st2.worker_credentials[], name)

            @test BT.revoke_worker_credential!(st, name)
            @test !BT.revoke_worker_credential!(st, name)
            @test occursin("no worker credentials issued", read(joinpath(dir, "Caddyfile"), String))

            # A Caddyfile Caddy would reject never replaces the one it serves, and
            # the error reaches whoever made the change.
            good = read(joinpath(dir, "Caddyfile"), String)
            bad_cfg = BT.ProxyConfig(; domain = "REJECT.example.com", auth_domain = "auth.REJECT.example.com",
                                     admin = "bob", caddyfile = joinpath(dir, "Caddyfile"),
                                     users_file = joinpath(dir, "users.yml"), caddy_bin = joinpath(bin, "caddy"))
            bad = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(bad_cfg, "k"))
            err = try BT.apply_proxy!(bad); "" catch e; sprint(showerror, e) end
            @test occursin("Caddy rejects the new configuration", err) && occursin("REJECT is no directive", err)
            @test read(joinpath(dir, "Caddyfile"), String) == good
            @test !isfile(joinpath(dir, "Caddyfile.new"))
        end
    end

    # Without the proxy there is nothing to manage.
    local_st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    @test_throws ErrorException BT.add_account!(local_st, "alice")
    @test_throws ErrorException BT.add_worker_credential!(local_st, "bob")
    @test BT.apply_proxy!(local_st) === nothing
end

@testitem "unit:harness spec" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test

    claude = "@agentclientprotocol/claude-agent-acp"
    codex = "@agentclientprotocol/codex-acp"
    spec = BT.default_harness_spec()
    @test spec["node"] == "lts"
    @test spec["packages"][claude] == "latest" && spec["packages"][codex] == "latest"
    @test BT.harness_spec_from_settings(nothing) == spec
    # A pinned version survives; a package the file predates starts at latest.
    pinned = BT.harness_spec_from_settings(Dict("harnesses" => Dict(
        "node" => "22", "packages" => Dict(claude => "0.5.0", codex => ""))))
    @test pinned["node"] == "22"
    @test pinned["packages"][claude] == "0.5.0" && pinned["packages"][codex] == "latest"

    # Only a server that manages adapters sends a spec; a change is persisted.
    dir = mktempdir()
    @test BT.ServerState(; state_dir = dir, working_dir = mktempdir()).harness_spec[] === nothing
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), manage_harnesses = true)
    @test st.harness_spec[] == spec
    BT.set_harness_spec!(st, Dict{String,Any}("node" => "22", "packages" => Dict{String,Any}(claude => "0.5.0")))
    again = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), manage_harnesses = true)
    @test again.harness_spec[]["node"] == "22"
    @test again.harness_spec[]["packages"][claude] == "0.5.0"
    @test again.harness_spec[]["packages"][codex] == "latest"

    # What the worker makes of the wire form.
    BW = BT.BonitoWorker
    h = BW.harness_spec_from_wire(Dict{String,Any}("node" => "lts", "packages" => Dict{String,Any}(claude => "latest")))
    @test h.node == "lts" && h.packages == Dict(claude => "latest")
    @test BW.harness_spec_from_wire(nothing) === nothing
    @test BW.harness_spec_from_wire(Dict{String,Any}("node" => "", "packages" => Dict{String,Any}())) === nothing
    @test BW.harness_spec_from_wire(Dict{String,Any}("node" => "lts", "packages" => Dict{String,Any}(claude => 1))) === nothing
end

@testitem "unit:managed adapters on the worker" tags = [:unit] begin
    import BonitoAgents
    using Test, JSON
    BW = BonitoAgents.BonitoWorker
    AP = BW.AgentProviders

    index = [Dict("version" => "v25.1.0", "lts" => false),
             Dict("version" => "v24.9.0", "lts" => "Krypton"),
             Dict("version" => "v22.20.0", "lts" => "Jod")]
    @test BW.resolve_node_version("lts"; index) == "24.9.0"
    @test BW.resolve_node_version("22"; index) == "22.20.0"
    @test BW.resolve_node_version("v22.1.0"; index) == "22.1.0"
    @test_throws ErrorException BW.resolve_node_version("18"; index)

    claude = AP.ClaudeCodeAgent()
    root = mktempdir()
    @test BW.installed_harnesses(root, [AP.npm_package(claude)]) == Dict{String,String}()
    @test BW.managed_agent(claude; root) === nothing
    # The layout sync_harnesses! leaves behind. A release already unpacked is
    # not downloaded again; switching to it drops the older one but keeps the
    # `node-version` marker (whose name starts like a release, and once went too).
    asset = BW.node_asset("24.9.0")
    nodedir = mkpath(joinpath(root, asset.name))
    old = mkpath(joinpath(root, BW.node_asset("22.1.0").name))
    @test BW.install_node!(root, "24.9.0") == nodedir
    @test !isdir(old)
    @test strip(read(joinpath(root, "node-version"), String)) == "24.9.0"
    @test BW.current_node_dir(root) == nodedir
    pkgdir = mkpath(BW.package_dir(root, AP.npm_package(claude)))
    write(joinpath(pkgdir, "package.json"), JSON.json(Dict("version" => "0.7.1")))
    bindir = mkpath(joinpath(root, "npm", "node_modules", ".bin"))
    write(joinpath(bindir, AP.npm_bin(claude) * (Sys.iswindows() ? ".cmd" : "")), "")
    @test BW.installed_harnesses(root, [AP.npm_package(claude), "@agentclientprotocol/codex-acp"]) ==
          Dict("node" => "24.9.0", AP.npm_package(claude) => "0.7.1")
    managed = BW.managed_agent(claude; root)
    @test managed.bin == joinpath(bindir, AP.npm_bin(claude) * (Sys.iswindows() ? ".cmd" : ""))
    @test managed.path == BW.node_bin_dir(nodedir)
    # Not managed: stays whatever its owner installed.
    @test BW.managed_agent(AP.KimiAgent(); root) === nothing
    # An explicit override wins over everything.
    withenv("CLAUDE_AGENT_ACP" => "/opt/pinned/claude-agent-acp") do
        @test BW.agent_command(claude) == (bin = "/opt/pinned/claude-agent-acp", path = "")
    end
end

@testitem "unit:worker credential on the wire" tags = [:unit] begin
    import BonitoAgents
    using Test, HTTP, Base64
    BW = BonitoAgents.BonitoWorker

    @test BW.credential_url("ws://h.example/w", "") == "ws://h.example/w"
    @test BW.credential_url("wss://h.example/w", "w-ab12:s3cr3t") == "wss://w-ab12:s3cr3t@h.example/w"
    # The userinfo becomes the Basic auth Caddy checks on `/w`.
    seen = Channel{String}(1)
    srv = HTTP.serve!("127.0.0.1", 0) do r
        put!(seen, HTTP.header(r, "Authorization", ""))
        HTTP.Response(403)
    end
    try
        url = BW.credential_url("ws://127.0.0.1:$(HTTP.port(srv))/w", "w-ab12:s3cr3t")
        @test_throws HTTP.WebSockets.WebSocketError HTTP.WebSockets.open(identity, url)
        @test take!(seen) == "Basic " * base64encode("w-ab12:s3cr3t")
    finally
        close(srv)
    end
end

# The dev server runs without the proxy and without managed adapters, so no e2e
# item draws these sections: render them here, for an admin and for a member.
@testitem "unit:proxy_auth dashboard sections" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, Bonito, Dates

    dir = mktempdir()
    cfg = BT.ProxyConfig(; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
                         caddyfile = joinpath(dir, "Caddyfile"), users_file = joinpath(dir, "users.yml"))
    root = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"),
                            manage_harnesses = true)
    root.base_url[] = "https://team.example.com"
    root.accounts[]["bob"] = BT.Account("bob", "Bob", "b@x", ["admins"], false, "\$argon2id\$b")
    root.accounts[]["carol"] = BT.Account("carol", "Carol", "", ["members"], true, "\$argon2id\$c")
    root.worker_credentials[]["w-1"] = BT.WorkerCredential("w-1", "\$2a\$14\$h", "bob", now())
    html(session, dom) = repr(MIME"text/html"(), Bonito.jsrender(session, dom))

    s1 = Bonito.Session()
    admin = copy(root, s1, BT.User("bob", "", "Bob", ["admins"]))
    block = html(s1, BT.worker_install_block(root.auth, s1, admin))
    @test occursin("Add worker", block) && occursin("w-1", block)
    sections = html(s1, BT.account_sections(s1, admin))
    @test occursin("Your account", sections) && occursin("Invites", sections)
    @test occursin("Accounts", sections) && occursin("carol", sections) && occursin("disabled", sections)
    @test occursin("this server sends no mail", sections)   # admins read what Authelia would have mailed
    @test occursin("Agent adapters", sections) && occursin("claude-agent-acp", sections)
    row = html(s1, BT.install_command_row("Linux / macOS", "curl -fsSL https://team.example.com/install.sh | sh"))
    @test occursin("install.sh", row)

    s2 = Bonito.Session()
    member = copy(root, s2, BT.User("carol", "", "Carol", ["members"]))
    block = html(s2, BT.worker_install_block(root.auth, s2, member))
    @test occursin("An admin adds workers", block) && !occursin("w-1", block)
    own = html(s2, BT.account_sections(s2, member))
    @test occursin("Your account", own) && occursin("Log out", own)
    @test !occursin("Accounts", own) && !occursin("Invites", own)

    # The whole dashboard, worker cards included: bob's worker, shared with a
    # group carol is in. She sees it and may start chats there; managing it
    # (renaming, removing, sharing, importing its sessions) stays with bob.
    w = BT.WorkerInfo("w1", "Box", nothing, "box", "/home/b", "julia", String[], "/p", :online, now())
    w.owner = "bob"; w.shared_with = ["lab"]
    root.workers[]["w1"] = w
    # The dashboard's worker list fills in after load, so the card is drawn here.
    function card_for(user)
        session = Bonito.Session()
        view = copy(root, session, user)
        html(session, BT.WorkerCard(view, "w1"; error_obs = Observable(""), picker_state = Observable(""),
             gh_state = Observable(""), discover_state = Observable(""),
             busy = Observable{Any}(BT.BUSY_IDLE), discover_busy = Observable(false),
             discover_results = Observable(Dict{String,Any}[]), do_import = (args...) -> nothing,
             do_github = (args...) -> nothing, trigger_scan = (args...) -> nothing))
    end
    bobs = card_for(BT.User("bob", "", "Bob", ["admins"]))
    @test occursin("Box", bobs) && occursin("bt-card-remove", bobs) && occursin("Shared with", bobs)
    @test occursin("bt-card-name-edit", bobs)
    carols = card_for(BT.User("carol", "", "Carol", ["lab"]))
    @test occursin("Box", carols) && occursin("Project", carols)   # may start chats there
    @test !occursin("bt-card-remove", carols) && !occursin("Shared with", carols) &&
          !occursin("bt-card-name-edit", carols)
    # Outside the group the dashboard does not list it at all.
    @test BT.visible(BT.User("carol", "", "Carol", ["lab"]), w)
    @test !BT.visible(BT.User("dave", "", "Dave", String[]), w)
end

# An agent must never have its adapter replaced underneath it: an install starts
# only with no session running or starting, and a session waits out an install.
@testitem "unit:adapter install vs agent sessions" tags = [:unit] begin
    import BonitoAgents
    using Test
    BW = BonitoAgents.BonitoWorker

    w = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:1", worker_id = "adapters",
        name = "adapters", mcp_command = "julia", mcp_arguments = String[], projects_root = mktempdir()))
    try
        @test BW.hold_adapters!(w)                 # a session starts
        @test !BW.begin_harness_sync!(w)           # … and holds the install off
        BW.release_adapters!(w)
        @test BW.begin_harness_sync!(w)            # nothing runs: the install may start
        @test !BW.hold_adapters!(w; timeout = 0.3) # a session gives up waiting on it
        @test w.harness.sessions == 0
        finished = Threads.@spawn (sleep(0.5); lock(() -> (w.harness.syncing = false), w.lock))
        @test BW.hold_adapters!(w; timeout = 10.0) # … or starts once it is done
        wait(finished)
        @test !BW.begin_harness_sync!(w)
        BW.release_adapters!(w)
    finally
        close(w)
    end
end

@testitem "unit:proxy_auth groups, invites and sharing" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, HTTP, JSON, Dates

    @test BT.parse_groups(" lab, gpu ,lab,, ") == ["lab", "gpu"]
    @test BT.parse_groups("") == String[]
    @test_throws ErrorException BT.parse_groups("lab, ../x")
    @test BT.form_fields("name=o%27neil&display_name=Bob+O%27Neil&email=") ==
          Dict("name" => "o'neil", "display_name" => "Bob O'Neil", "email" => "")

    # Sharing: a member sees a worker shared with one of their groups, and may
    # start chats on it, but managing it stays with its owner and admins.
    carol = BT.User("carol", "", "carol", ["lab"])
    w = BT.WorkerInfo("w1", "Box", nothing, "box", "/home/b", "julia", String[], "/p", :online, now())
    w.owner = "bob"
    @test !BT.visible(carol, w)
    w.shared_with = ["lab"]
    @test BT.visible(carol, w) && !BT.can_manage(carol, w)
    @test BT.can_manage(BT.User("bob", "", "bob", String[]), w)
    @test BT.can_manage(BT.User("root", "", "root", ["admins"]), w)

    Sys.isunix() || return
    bin = mktempdir()
    write(joinpath(bin, "authelia"),
          "#!/bin/sh\n[ \"\$1\" = storage ] && exec $(joinpath(@__DIR__, "..", "fixtures", "fake_authelia_storage.sh")) \"\$@\"\necho 'Random Password: pw-123'\necho 'Digest: \$argon2id\$fake'\n")
    write(joinpath(bin, "caddy"), "#!/bin/sh\nexit 0\n")   # `adapt`: every Caddyfile is fine
    chmod(joinpath(bin, "authelia"), 0o755); chmod(joinpath(bin, "caddy"), 0o755)
    dir = mktempdir()
    cfg = BT.ProxyConfig(; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
                         caddyfile = joinpath(dir, "Caddyfile"), users_file = joinpath(dir, "users.yml"),
                         caddy_bin = joinpath(bin, "caddy"), authelia_bin = joinpath(bin, "authelia"))
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    st.base_url[] = "https://team.example.com"
    BT.add_account!(st, "bob"; groups = ["admins"])

    # Groups: "admins" stays guarded; the others are free.
    BT.set_account_groups!(st, "bob", ["admins", "lab"])
    @test st.accounts[]["bob"].groups == ["admins", "lab"]
    @test_throws ErrorException BT.set_account_groups!(st, "bob", ["lab"])   # the last admin
    @test BT.all_groups(st) == ["admins", "lab"]

    # An invite: one account, once, before it expires.
    url = BT.create_invite!(st, ["lab"])
    @test startswith(url, "https://team.example.com/invite/")
    token = last(split(url, '/'))
    @test length(token) == 64
    @test !occursin(token, read(joinpath(dir, "invites.json"), String))   # only its hash is kept
    @test filemode(joinpath(dir, "invites.json")) & 0o777 == 0o600
    @test BT.open_invite(st, token) !== nothing
    @test BT.open_invite(st, "0"^64) === nothing
    @test_throws ErrorException BT.redeem_invite!(st, token, "bob")   # name taken …
    @test BT.open_invite(st, token) !== nothing                        # … the link stays good
    @test BT.redeem_invite!(st, token, "dave"; display_name = "Dave").password == "pw-123"
    @test st.accounts[]["dave"].groups == ["lab"]
    @test BT.open_invite(st, token) === nothing
    @test_throws ErrorException BT.redeem_invite!(st, token, "eve")    # used up
    old = BT.create_invite!(st, String[]; valid_for = Millisecond(1))
    sleep(0.01)
    @test BT.open_invite(st, last(split(old, '/'))) === nothing
    @test_throws ErrorException BT.redeem_invite!(st, last(split(old, '/')), "eve")
    @test !haskey(st.accounts[], "eve")
    again = BT.create_invite!(st, String[])
    id = BT.invite_id(last(split(again, '/')))
    @test BT.revoke_invite!(st, id) && !BT.revoke_invite!(st, id)

    # A setup link, the installer's for the first admin: the server files the
    # one the installer leaves (only its hash), and it sets up the account's
    # login once: a new password and authenticator, for the page that shows them.
    setup_token = bytes2hex(rand(UInt8, 32))
    write(joinpath(dir, "setup_link.json"), JSON.json(Dict("account" => "bob",
        "token_sha256" => BT.invite_id(setup_token), "expires" => string(now(UTC) + Day(7)))))
    BT.import_setup_link!(st)
    @test !isfile(joinpath(dir, "setup_link.json"))
    @test st.invites[][BT.invite_id(setup_token)].account == "bob"
    @test !occursin(setup_token, read(joinpath(dir, "invites.json"), String))
    setup_page(method) = BT.invite_response(st.auth, st, HTTP.Request(method, "/invite/$(setup_token)", [], ""), setup_token)
    @test occursin("Set up my login", String(setup_page("GET").body)) && occursin("<b>bob</b>", String(setup_page("GET").body))
    ready = setup_page("POST")
    @test ready.status == 200
    @test occursin("<code class=\"pw\">pw-123</code>", String(ready.body))
    @test occursin("otpauth://totp/team.example.com:bob?", String(ready.body))
    @test setup_page("GET").status == 404                       # once
    @test_throws ErrorException BT.redeem_setup!(st, setup_token)
    # An invite for a new account is not a setup link.
    fresh = last(split(BT.create_invite!(st, String[]), '/'))
    @test_throws ErrorException BT.redeem_setup!(st, fresh)
    reloaded = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    @test isempty(reloaded.invites[])

    # The invite page: a form, then the account and its password, then nothing.
    link = last(split(BT.create_invite!(st, String[]), '/'))
    req(method, body = "") = HTTP.Request(method, "/invite/$link", [], body)
    page = BT.invite_response(st.auth, st, req("GET"), link)
    @test page.status == 200 && occursin("<form method=\"post\">", String(page.body))
    @test HTTP.header(page, "Referrer-Policy") == "no-referrer"
    bad = BT.invite_response(st.auth, st, req("POST", "name=..%2Fx"), link)
    @test bad.status == 400 && occursin("letters, digits", String(bad.body))
    made = BT.invite_response(st.auth, st, req("POST", "name=erin&display_name=Erin+E&email=e%40x.org"), link)
    @test made.status == 200 && occursin("pw-123", String(made.body))
    @test st.accounts[]["erin"].display_name == "Erin E" && st.accounts[]["erin"].email == "e@x.org"
    @test BT.invite_response(st.auth, st, req("GET"), link).status == 404
    @test BT.invite_response(BT.LocalAuth(), st, req("GET"), link).status == 404

    # Sharing a worker is persisted.
    st.workers[]["w1"] = w
    w.shared_with = String[]
    BT.share_worker!(st, "w1", ["lab"])
    @test BT.ServerState(; state_dir = dir, working_dir = mktempdir(),
                           auth = BT.ProxyAuth(cfg, "k")).workers[]["w1"].shared_with == ["lab"]
end

@testitem "unit:proxy_auth chat routes answer only who sees the chat" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, HTTP, Dates

    cfg = BT.ProxyConfig(; domain = "d.example.com", auth_domain = "auth.d.example.com", admin = "bob",
                         caddyfile = "/x/C", users_file = "/x/u")
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    p = BT.ProjectInfo("p1", "proj", "w1", "/s", "/w", now())
    p.owner = "carol"
    st.projects[]["p1"] = p
    as(user, groups = "") = HTTP.Request("GET", "/acp-log/p1",
        isempty(user) ? [BT.PROXY_KEY_HEADER => "k"] :
                        [BT.PROXY_KEY_HEADER => "k", "Remote-User" => user, "Remote-Groups" => groups])
    @test BT.request_sees_chat(st, as("carol"), "p1")
    @test BT.request_sees_chat(st, as("root", "admins"), "p1")
    @test !BT.request_sees_chat(st, as("dave"), "p1")
    @test !BT.request_sees_chat(st, as(""), "p1")
    # Not through Caddy (no key): an admin's name alone gets nothing.
    @test !BT.request_sees_chat(st, HTTP.Request("GET", "/acp-log/p1",
        ["Remote-User" => "root", "Remote-Groups" => "admins"]), "p1")
    # A log with no chat on record any more: admins only.
    @test BT.request_sees_chat(st, as("root", "admins"), "gone")
    @test !BT.request_sees_chat(st, as("carol"), "gone")
    @test BT.unknown_chat("p1").status == 404
end

@testitem "unit:proxy_auth tls modes and Authelia's configuration" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, JSON, Dates

    base = (; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
            caddyfile = "/p/Caddyfile", users_file = "/p/authelia/users.yml")
    acme = BT.ProxyConfig(; base...)
    @test_throws ErrorException BT.ProxyConfig(; base..., tls = "self-signed")
    @test BT.public_origin(acme, acme.domain) == "https://team.example.com"
    cred = [BT.WorkerCredential("w-a", "\$2a\$14\$ha", "bob", now())]

    # Let's Encrypt on the standard ports: none of the local-CA settings.
    cf = BT.render_caddyfile(BT.ProxyAuth(acme, "k"), cred)
    @test !occursin("tls internal", cf) && !occursin("https_port", cf) && !occursin("skip_install_trust", cf)
    @test !occursin("acme_ca", cf)
    # A reload (every credential change) keeps the WebSockets it carries.
    @test count("stream_close_delay 24h", cf) == 3
    staging = BT.ProxyConfig(; base..., acme_ca = "https://acme-staging-v02.api.letsencrypt.org/directory")
    @test occursin("\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory\n",
                   BT.render_caddyfile(BT.ProxyAuth(staging, "k"), cred))

    # Caddy's own CA, other ports, and a worker address: what `dev_server(proxy = …)` runs.
    local_ca = BT.ProxyConfig(; base..., domain = "bonito.localhost", auth_domain = "auth.bonito.localhost",
                              tls = "internal", https_port = 8443, http_port = 8080, worker_address = "127.0.0.1")
    @test BT.public_origin(local_ca, "auth.bonito.localhost") == "https://auth.bonito.localhost:8443"
    cf = BT.render_caddyfile(BT.ProxyAuth(local_ca, "k"), cred)
    @test occursin("\thttps_port 8443\n\thttp_port 8080\n\tskip_install_trust\n", cf)
    @test count("\ttls internal\n", cf) == 3            # dashboard, portal, worker address
    workers = cf[findfirst("\n127.0.0.1 {", cf)[1]:end]
    @test occursin("handle /w {", workers) && occursin("@public path", workers)
    @test !occursin("forward_auth", workers)          # people never come in that way
    @test occursin("respond 404", workers)

    secrets = (jwt = "j"^64, session = "s"^64, storage = "t"^64)
    y = BT.render_authelia_config(BT.ProxyAuth(local_ca, "k"), secrets, nothing)
    @test occursin("address: 'tcp://127.0.0.1:9091/'", y)
    @test occursin("- domain: 'bonito.localhost'\n      authelia_url: 'https://auth.bonito.localhost:8443'", y)
    @test occursin("default_redirection_url: 'https://bonito.localhost:8443'", y)
    @test occursin("- domain: 'bonito.localhost'\n      policy: 'two_factor'", y)
    @test occursin("password_reset:\n    disable: true\n  password_change:\n    disable: true", y)
    @test occursin("refresh_interval: 'always'", y)
    @test occursin("path: '/p/authelia/users.yml'", y) && occursin("path: '/p/authelia/db.sqlite3'", y)
    @test occursin("filesystem:\n    filename: '/p/authelia/notifications.txt'", y)
    @test occursin("encryption_key: '$("t"^64)'", y)
    smtp = Dict("host" => "smtp.example.com", "port" => 587, "username" => "u", "password" => "it's", "sender" => "bot@example.com")
    y = BT.render_authelia_config(BT.ProxyAuth(acme, "k"), secrets, smtp)
    @test occursin("address: 'submission://smtp.example.com:587'", y) && occursin("password: 'it''s'", y)
    @test !occursin("filesystem:", y)
    # A mail outage must not keep Authelia from starting (proxy_stack_test.jl runs it).
    @test occursin("notifier:\n  disable_startup_check: true\n  smtp:", y)
    @test occursin("- domain: 'team.example.com'\n      authelia_url: 'https://auth.team.example.com'", y)

    # Behind a tunnel: no Caddy, and Authelia under the dashboard's own name, so
    # the tunnel carries one host name (tunnel.jl).
    tunnel = BT.TunnelAuth(BT.ProxyConfig(; domain = "team.example.com", admin = "bob", tls = "tunnel",
                                          users_file = "/p/authelia/users.yml"))
    @test BT.dashboard_url(tunnel) == "https://team.example.com"
    @test BT.portal_url(tunnel) == "https://team.example.com/authelia"
    y = BT.render_authelia_config(tunnel, secrets, nothing)
    @test occursin("address: 'tcp://127.0.0.1:9091/authelia'", y)
    @test occursin("- domain: 'team.example.com'\n      authelia_url: 'https://team.example.com/authelia'\n" *
                   "      default_redirection_url: 'https://team.example.com'", y)
    @test occursin("- domain: 'team.example.com'\n      policy: 'two_factor'", y)
    # What a tunnel is not: Caddy's settings, or a proxy config said to be one.
    @test_throws ErrorException BT.TunnelAuth(acme)
    @test_throws ErrorException BT.ProxyAuth(tunnel.config, "k")
    @test_throws ErrorException BT.TunnelAuth(BT.ProxyConfig(; tunnel.config.domain, admin = "bob", tls = "tunnel",
                                                              users_file = "/u", worker_address = "10.0.0.2"))
    # Behind the proxy the portal and the Caddyfile are required.
    @test_throws ErrorException BT.ProxyAuth(BT.ProxyConfig(; domain = "d", admin = "a", users_file = "/u"), "k")
    tdir = mktempdir()
    write(joinpath(tdir, "proxy.json"), JSON.json(Dict("domain" => "team.example.com", "admin" => "bob",
                                                       "tls" => "tunnel", "users_file" => "/p/u.yml")))
    @test BT.auth_mode(tdir) isa BT.TunnelAuth
    # Listening beyond localhost is still the trusted network's way, tunnel or not.
    @test BT.auth_mode(tdir; host = "0.0.0.0") isa BT.NetworkAuth

    # Mail is on exactly when the installer left settings for it.
    dir = mktempdir()
    write(joinpath(dir, "proxy.json"), JSON.json(Dict(pairs(base))))
    @test !BT.auth_mode(dir).config.smtp
    write(joinpath(dir, "smtp.json"), JSON.json(smtp))
    @test BT.auth_mode(dir).config.smtp

    # Authelia's secrets are made once: a restart must not log everyone out or
    # lose its database.
    s1 = BT.authelia_secrets(dir)
    @test BT.authelia_secrets(dir) == s1 && length(s1.storage) == 64 && s1.jwt != s1.session
end

@testitem "unit:proxy_auth accounts: races, odd input, your own account, open tabs" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, HTTP, JSON, Bonito, Logging
    Sys.isunix() || return

    bin = mktempdir()
    # As slow as a real argon2 hash, so two requests overlap while it runs.
    write(joinpath(bin, "authelia"),
          "#!/bin/sh\n[ \"\$1\" = storage ] && exec $(joinpath(@__DIR__, "..", "fixtures", "fake_authelia_storage.sh")) \"\$@\"\nsleep 0.3\necho \"Random Password: pw-\$\$\"\necho 'Digest: \$argon2id\$fake'\n")
    write(joinpath(bin, "caddy"), "#!/bin/sh\nexit 0\n")
    chmod(joinpath(bin, "authelia"), 0o755); chmod(joinpath(bin, "caddy"), 0o755)
    dir = mktempdir()
    cfg = BT.ProxyConfig(; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
                         caddyfile = joinpath(dir, "Caddyfile"), users_file = joinpath(dir, "users.yml"),
                         caddy_bin = joinpath(bin, "caddy"), authelia_bin = joinpath(bin, "authelia"))
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    st.base_url[] = "https://team.example.com"
    BT.add_account!(st, "bob"; groups = ["admins"])
    outcome(f) = try f() catch e; e isa ErrorException || rethrow(); e end

    # One invite link submitted twice at once makes one account.
    token = last(split(BT.create_invite!(st, ["lab"]), '/'))
    both = asyncmap(name -> outcome(() -> BT.redeem_invite!(st, token, name)), ["carol", "dave"])
    @test count(r -> r isa NamedTuple, both) == 1
    @test count(r -> r isa ErrorException && occursin("used already", r.msg), both) == 1
    @test length(st.accounts[]) == 2
    member = only(n for n in keys(st.accounts[]) if n != "bob")
    # Two admins adding one name at once make one account.
    both = asyncmap(_ -> outcome(() -> BT.add_account!(st, "erin")), 1:2)
    @test count(r -> r isa NamedTuple, both) == 1
    @test count(r -> r isa ErrorException && occursin("already", r.msg), both) == 1

    # What someone types into the invite form comes back escaped, never as markup.
    link = last(split(BT.create_invite!(st, String[]), '/'))
    post(body) = BT.invite_response(st.auth, st, HTTP.Request("POST", "/invite/$(link)", [], body), link)
    r = post("name=%3Cscript%3Ealert(1)%3C%2Fscript%3E&display_name=%3Cimg+src%3Dx+onerror%3Dalert(1)%3E")
    page = String(r.body)
    @test r.status == 400
    @test !occursin("<script>", page) && !occursin("<img", page)
    @test occursin("&lt;script&gt;alert(1)&lt;/script&gt;", page) && occursin("&lt;img src=x", page)
    @test BT.open_invite(st, link) !== nothing   # the link stays good for another try
    # The account, then: its password and its authenticator, shown once.
    r = post("name=frank&display_name=Frank+F")
    page = String(r.body)
    @test r.status == 200 && occursin("<code class=\"pw\">", page)
    @test occursin("<img class=\"qr\" src=\"data:image/png;base64,", page)
    @test occursin("otpauth://totp/team.example.com:frank?", page)

    # A damaged record on disk is skipped with a warning; the rest load.
    dir2 = mktempdir()
    write(joinpath(dir2, "accounts.json"), JSON.json([
        Dict("name" => "ok", "display_name" => "Ok", "email" => "", "groups" => ["admins"],
             "disabled" => false, "password_hash" => "h"),
        Dict("name" => "broken")]))
    st2 = @test_logs (:warn, r"skipping malformed entry") match_mode = :any BT.ServerState(;
        state_dir = dir2, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    @test collect(keys(st2.accounts[])) == ["ok"]

    # Nobody locks themselves out, even with another admin around.
    BT.set_account_admin!(st, member, true)
    me = copy(st, Bonito.Session(), BT.User("bob", "", "bob", ["admins"]))
    for f in (() -> BT.set_account_disabled!(me, "bob", true), () -> BT.set_account_admin!(me, "bob", false),
              () -> BT.remove_account!(me, "bob"))
        @test occursin("your own account", outcome(f).msg)
    end
    @test !st.accounts[]["bob"].disabled && BT.is_admin(st.accounts[]["bob"])
    BT.set_account_admin!(st, member, false)

    # Open tabs: disabling, regrouping and removing an account close its tabs
    # (an open websocket is never checked again), and nobody else's.
    function open_tab(name)
        s = Bonito.Session()
        BT.register_user_session!(st, s, BT.User(name, "", name, String[]))
        return s
    end
    closed(s) = s.status == Bonito.CLOSED
    a, b, bobs = open_tab(member), open_tab(member), open_tab("bob")
    BT.set_account_disabled!(st, member, true)
    @test closed(a) && closed(b) && !closed(bobs)
    c = open_tab(member)
    BT.set_account_disabled!(st, member, false)
    @test !closed(c)                                # enabling closes nothing
    BT.set_account_groups!(st, member, ["lab", "gpu"])
    @test closed(c)                                 # the new groups come with the next load
    d = open_tab(member)
    BT.remove_account!(st, member)
    @test closed(d) && !closed(bobs)
    # A tab that closes on its own is forgotten.
    close(bobs)
    @test all(s -> s !== bobs, get(st.user_sessions, "bob", Bonito.Session[]))
end

@testitem "unit:worker retries quietly, and belongs to whoever issued its credential" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    const BW = BT.BonitoWorker
    using Test, HTTP, Logging, Dates

    # A revoked worker: the proxy turns every attempt away. It keeps trying every
    # few seconds (so it is back as soon as it may be) but says so once.
    attempts = Threads.Atomic{Int}(0)
    srv = HTTP.serve!("127.0.0.1", 0) do _
        Threads.atomic_add!(attempts, 1)
        HTTP.Response(403)
    end
    w = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(HTTP.port(srv))", credential = "w-x:revoked",
        worker_id = "quiet", name = "quiet", mcp_command = "julia", mcp_arguments = String[],
        projects_root = mktempdir()))
    logger = Test.TestLogger(; min_level = Logging.Info)
    task = with_logger(() -> @async(BW.serve(w; retry_delay = 0.05, repeat_log_interval = 3600.0)), logger)
    try
        @test timedwait(() -> attempts[] >= 10, 30.0) === :ok
    finally
        close(w)
        wait(task)
        close(srv)
    end
    errors = [r for r in logger.logs if r.level == Logging.Error]
    @test length(errors) == 1
    @test occursin("401 or 403 means this worker's credential is wrong or was revoked", only(errors).message)
    @test count(r -> startswith(r.message, "BonitoWorker: connecting"), logger.logs) == 1
    @test count(r -> startswith(r.message, "BonitoWorker: reconnecting every"), logger.logs) == 1
    @test !any(r -> occursin("revoked'", string(r.message, r.kwargs)) && occursin("w-x:", string(r.message, r.kwargs)),
               logger.logs)   # the credential itself is never logged

    # The worker belongs to whoever issued the credential it came in with, and
    # keeps who it is shared with across reconnects.
    cfg = BT.ProxyConfig(; domain = "d", auth_domain = "auth.d", admin = "root", caddyfile = "/x/C", users_file = "/x/u")
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    st.worker_credentials[]["w-1"] = BT.WorkerCredential("w-1", "h", "alice", now(UTC))
    link = BT.WorkerLink.Link(:server)
    hello = Dict{String,Any}("hostname" => "box", "harnesses" => Dict("node" => "24.9.0", "x" => 1))
    w1 = BT.register_worker!(st, "wid", "box", hello, link, "w-1")
    @test (w1.owner, w1.credential) == ("alice", "w-1")
    @test w1.harnesses == Dict("node" => "24.9.0")   # what the worker reports, versions only
    BT.share_worker!(st, "wid", ["lab"])
    w2 = BT.register_worker!(st, "wid", "box", hello, link, "w-1")
    @test w2.shared_with == ["lab"]
    # A credential the server no longer knows: the records' default owner.
    @test BT.register_worker!(st, "wid2", "box2", hello, BT.WorkerLink.Link(:server), "w-gone").owner == "root"
    # What the worker reports after an install shows on its card.
    @test BT.apply_harness_status!(st, "wid", Dict("installed" => Dict("node" => "25.1.0"), "error" => "npm failed"))
    @test st.workers[]["wid"].harnesses == Dict("node" => "25.1.0") && st.workers[]["wid"].harness_error == "npm failed"
    @test !BT.apply_harness_status!(st, "nope", Dict("installed" => Dict()))
end

# Authelia ignores a change to its users file within half a second of its last
# reread (and keeps the state before it). The server keeps its writes apart,
# does not rewrite an unchanged file, and ends on the latest state.
@testitem "unit:proxy_auth the users file keeps Authelia's pace" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test
    Sys.isunix() || return

    bin = mktempdir()
    write(joinpath(bin, "authelia"),
          "#!/bin/sh\n[ \"\$1\" = storage ] && exec $(joinpath(@__DIR__, "..", "fixtures", "fake_authelia_storage.sh")) \"\$@\"\necho \"Random Password: pw-\$\$\"\necho 'Digest: \$argon2id\$fake'\n")
    write(joinpath(bin, "caddy"), """
        #!/bin/sh
        case "\$1" in hash-password) read pw; echo "\\\$2a\\\$14\\\$\$pw" ;; esac
        """)
    chmod(joinpath(bin, "authelia"), 0o755); chmod(joinpath(bin, "caddy"), 0o755)
    dir = mktempdir()
    cfg = BT.ProxyConfig(; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
                         caddyfile = joinpath(dir, "Caddyfile"), users_file = joinpath(dir, "users.yml"),
                         caddy_bin = joinpath(bin, "caddy"), authelia_bin = joinpath(bin, "authelia"))
    st = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    writer = st.proxy_writer
    @test writer.spacing >= 1.0

    BT.add_account!(st, "bob"; groups = ["admins"])
    written = writer.users_written
    # A worker credential changes the Caddyfile only: the users file stays as it
    # is, so Authelia starts no reread (and no half second of ignoring changes).
    BT.add_worker_credential!(st, "bob")
    @test writer.users_written == written
    # Changes one right after the other keep the spacing.
    BT.add_account!(st, "alice")
    first = writer.users_written
    BT.set_account_admin!(st, "alice", true)
    @test writer.users_written - first >= writer.spacing
    # Changes at the same time: one writer at a time, and the file ends with all.
    @sync for name in ("c1", "c2", "c3")
        @async BT.add_account!(st, name)
    end
    users = read(cfg.users_file, String)
    @test all(n -> occursin("'$(n)':", users), ("bob", "alice", "c1", "c2", "c3"))
    @test occursin("'alice':\n    disabled: false\n    displayname: 'alice'\n    password: '\$argon2id\$fake'\n    email: ''\n    groups:\n      - 'admins'", users)
end
