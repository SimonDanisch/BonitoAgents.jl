# A server on a network it trusts, without the login proxy (`NetworkAuth`,
# `bonito-agents server --host 0.0.0.0`): no login, as on one machine, but a worker
# comes in only with a credential "Add worker" issued, which the server checks
# itself. `e2e:network_mode` drives the same from the dashboard.

@testitem "unit:network mode" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    const BW = BT.BonitoWorker
    using Test, HTTP, JSON, Base64, Dates

    # Which way a server runs: where it listens, and what the installer left.
    dir = mktempdir()
    @test BT.auth_mode(dir) isa BT.LocalAuth
    @test BT.auth_mode(dir; host = "0.0.0.0") isa BT.NetworkAuth
    @test BT.auth_mode(dir; host = "192.168.1.5") isa BT.NetworkAuth
    proxied = mktempdir()
    write(joinpath(proxied, "proxy.json"), JSON.json(Dict(
        "domain" => "team.example.com", "auth_domain" => "auth.team.example.com", "admin" => "bob",
        "caddyfile" => joinpath(proxied, "Caddyfile"), "users_file" => joinpath(proxied, "users.yml"))))
    @test BT.auth_mode(proxied) isa BT.ProxyAuth
    # Started for the network, the proxy's settings wait unused (and nothing has
    # to be moved to go back and forth).
    @test (@test_logs (:info, r"login proxy's settings .* are not used") BT.auth_mode(proxied; host = "0.0.0.0")) isa BT.NetworkAuth
    @test isfile(joinpath(proxied, "proxy.json"))
    # And where each may listen: only a trusted network's beyond localhost.
    @test_throws ErrorException BT.serve(; host = "0.0.0.0", port = 0, auth = BT.LocalAuth(),
                                         state_dir = mktempdir(), working_dir = mktempdir())
    @test_throws ErrorException BT.serve(; host = "0.0.0.0", port = 0, auth = BT.auth_mode(proxied),
                                         state_dir = mktempdir(), working_dir = mktempdir())

    # No login: whoever reaches it is the one account, an admin.
    net = BT.NetworkAuth()
    @test BT.request_user(net, HTTP.Request("GET", "/")) === net.user
    @test BT.is_admin(net.user) && BT.default_owner(net) == net.user.name

    # Credentials without Caddy: the server keeps a digest and checks it itself.
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), auth = net)
    issued = BT.add_worker_credential!(st, net.user.name)
    name, password = split(issued, ':')
    c = st.worker_credentials[][name]
    @test isempty(c.hash) && c.digest == BT.credential_digest(password) && c.owner == net.user.name
    @test !occursin(password, read(joinpath(st.state_dir, "worker_credentials.json"), String))
    creds = st.worker_credentials[]
    basic(user, pw) = HTTP.Request("GET", "/w", ["Authorization" => "Basic " * base64encode("$(user):$(pw)")])
    @test BT.worker_credential(net, basic(name, password), creds) == name
    @test BT.worker_credential(net, basic(name, password * "0"), creds) === nothing
    @test BT.worker_credential(net, basic(name, ""), creds) === nothing
    @test BT.worker_credential(net, basic("w-other", password), creds) === nothing
    @test BT.worker_credential(net, HTTP.Request("GET", "/w"), creds) === nothing
    @test BT.worker_credential(net, HTTP.Request("GET", "/w", ["Authorization" => "Basic !!not base64"]), creds) === nothing
    @test BT.worker_credential(net, HTTP.Request("GET", "/w", ["Authorization" => "Basic " * base64encode("no colon")]), creds) === nothing
    @test BT.worker_credential(net, HTTP.Request("GET", "/w", ["Authorization" => "Bearer $(password)"]), creds) === nothing
    # One issued behind the proxy before digests existed: only Caddy could check it.
    old = Dict("w-old" => BT.WorkerCredential("w-old", "\$2a\$14\$h", "bob", now()))
    @test BT.worker_credential(net, basic("w-old", "anything"), old) === nothing
    # A restart finds it; a Caddyfile leaves it out (Caddy has no hash to check).
    again = BT.ServerState(; state_dir = st.state_dir, working_dir = st.working_dir, auth = net)
    @test again.worker_credentials[][name].digest == c.digest
    cfg = BT.ProxyConfig(; domain = "d", auth_domain = "auth.d", admin = "a", caddyfile = "/x/C", users_file = "/x/u")
    @test !occursin(name, BT.render_caddyfile(BT.ProxyAuth(cfg, "k"), values(creds)))
    # On one machine no worker needs one.
    local_st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), auth = BT.LocalAuth())
    @test_throws ErrorException BT.add_worker_credential!(local_st, "x")

    # For real: the server on the network address, a worker with its credential,
    # one without, and the credential revoked under a connected worker.
    server = BT.serve(; host = "0.0.0.0", port = 0, auth = net, state_dir = mktempdir(),
                      working_dir = mktempdir(), scan_on_connect = false)
    try
        # Other machines are told this machine's address, not localhost.
        @test !occursin("localhost", server.base_url[]) && !occursin("0.0.0.0", server.base_url[])
        @test endswith(server.base_url[], ":$(server.srv.port)")
        issued = BT.add_worker_credential!(server, net.user.name)
        name = first(split(issued, ':'))
        url = "http://127.0.0.1:$(server.srv.port)"
        worker(id, credential) = BW.Worker(BW.WorkerConfig(; server_url = url, credential, worker_id = id,
            name = id, mcp_command = "julia", mcp_arguments = String[], projects_root = mktempdir()))

        stranger = worker("stranger", "")
        refused = try BW.connect_once!(stranger); nothing catch e; e end
        close(stranger)
        @test refused isa BW.WorkerLink.LinkRefused && occursin("no valid worker credential", refused.reason)
        guesser = worker("guesser", name * ":" * "0"^48)
        refused = try BW.connect_once!(guesser); nothing catch e; e end
        close(guesser)
        @test refused isa BW.WorkerLink.LinkRefused

        admitted = worker("admitted", issued)
        task = @async BW.serve(admitted; retry_delay = 0.2)
        try
            @test timedwait(() -> BT.worker_connected(server, "admitted"), 30.0) === :ok
            w = server.workers[]["admitted"]
            @test (w.credential, w.owner) == (name, net.user.name)
            # Revoked: disconnected, and its reconnects are refused.
            @test BT.revoke_worker_credential!(server, name)
            @test timedwait(() -> !BT.worker_connected(server, "admitted"), 30.0) === :ok
            sleep(1.5)
            @test !BT.worker_connected(server, "admitted")
        finally
            close(admitted)
            wait(task)
        end

        # A machine installed again with a new credential keeps its worker entry,
        # and the credential it came with before is retired. One that another
        # machine still uses stays.
        cred_name(c) = first(split(c, ':'))
        function connect_as(id, credential)
            wk = worker(id, credential)
            t = @async BW.serve(wk; retry_delay = 0.2)
            try
                @test timedwait(() -> BT.worker_connected(server, id) &&
                                      server.workers[][id].credential == cred_name(credential), 30.0) === :ok
            finally
                close(wk)
                wait(t)
            end
        end
        first_cred, second_cred = (BT.add_worker_credential!(server, net.user.name) for _ in 1:2)
        connect_as("laptop", first_cred)
        connect_as("laptop", second_cred)
        @test timedwait(() -> !haskey(server.worker_credentials[], cred_name(first_cred)), 10.0) === :ok
        @test haskey(server.worker_credentials[], cred_name(second_cred))
        @test count(==("laptop"), keys(server.workers[])) == 1

        shared, own = (BT.add_worker_credential!(server, net.user.name) for _ in 1:2)
        connect_as("desk-a", shared)
        connect_as("desk-b", shared)
        connect_as("desk-a", own)
        sleep(1.0)
        @test haskey(server.worker_credentials[], cred_name(shared))   # desk-b still uses it
    finally
        close(server.srv)
    end
end

# Installed again without a credential (to update it, or from another folder),
# a worker keeps the one it has for that server: an empty one locked it out, so
# every reinstall needed a new credential and left the old one lying around.
@testitem "unit:worker config keeps its credential" tags = [:unit] begin
    import BonitoAgents
    const BW = BonitoAgents.BonitoWorker
    using Test, JSON
    dir = mktempdir()
    withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
        stored() = JSON.parsefile(BW.config_path())["credential"]
        BW.write_config!(; server_url = "https://a.example", credential = "w-1:secret", projects_root = dir)
        @test stored() == "w-1:secret"
        BW.write_config!(; server_url = "https://a.example", projects_root = dir)
        @test stored() == "w-1:secret"
        # A new one replaces it.
        BW.write_config!(; server_url = "https://a.example", credential = "w-2:other", projects_root = dir)
        @test stored() == "w-2:other"
        # Another server's credential is no use here.
        BW.write_config!(; server_url = "https://b.example", projects_root = dir)
        @test stored() == ""
    end
end
