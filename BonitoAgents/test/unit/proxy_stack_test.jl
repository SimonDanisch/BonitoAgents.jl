# The login stack's pieces against the real Caddy and Authelia (the pinned,
# checksum-verified builds `dev_server(proxy = true)` runs, cached across runs):
# every configuration the server renders is one they accept, and the server's own
# routes answer only who the proxy says may ask. The browser side (Authelia's
# form, the second factor, what each account sees) is the `e2e:proxy_*` items'.

@testitem "unit:proxy_auth the real Caddy and Authelia accept every rendered configuration" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test, HTTP, Sockets, Dates
    Sys.islinux() || return

    bins = BT.fetch_proxy_binaries(joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                                            "bonitoagents-test", "proxy-bin"))
    dir = mktempdir()
    mkpath(joinpath(dir, "authelia"))
    base = (; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
            caddyfile = joinpath(dir, "Caddyfile"), users_file = joinpath(dir, "authelia", "users.yml"),
            caddy_bin = bins.caddy, authelia_bin = bins.authelia)
    cred = [BT.WorkerCredential("w-a", BT.caddy_hash(BT.ProxyConfig(; base...), "s3cret"), "bob", now())]

    function caddy_accepts(cfg, creds)
        f = tempname()
        write(f, BT.render_caddyfile(BT.ProxyAuth(cfg, "k"^64), creds))
        err = IOBuffer()
        ok = success(pipeline(`$(bins.caddy) validate --config $f --adapter caddyfile`; stdout = devnull, stderr = err))
        ok || @error "caddy rejects" config = read(f, String) err = String(take!(err))
        return ok
    end
    @test caddy_accepts(BT.ProxyConfig(; base...), cred)
    @test caddy_accepts(BT.ProxyConfig(; base...), BT.WorkerCredential[])
    @test caddy_accepts(BT.ProxyConfig(; base..., acme_email = "ops@example.com",
                                       acme_ca = "https://acme-staging-v02.api.letsencrypt.org/directory"), cred)
    @test caddy_accepts(BT.ProxyConfig(; base..., tls = "internal", https_port = 8443, http_port = 8080,
                                       worker_address = "192.168.1.5"), cred)

    # A password Authelia generated is one its digest accepts, and only that one.
    pw = BT.authelia_random_password(BT.ProxyConfig(; base...))
    verdict(p) = read(`$(bins.authelia) crypto hash validate --password $p -- $(pw.hash)`, String)
    @test occursin("matches", verdict(pw.password)) && !occursin("does not match", verdict(pw.password))
    @test occursin("does not match", verdict(pw.password * "x"))

    secrets = BT.authelia_secrets(dir)
    write(base.users_file, BT.render_users_yaml([BT.Account("bob", "Bob", "b@example.com", ["admins"], false, pw.hash)]))
    config = joinpath(dir, "authelia", "configuration.yml")
    function authelia_accepts(auth, smtp)
        write(config, BT.render_authelia_config(auth, secrets, smtp))
        out = IOBuffer()
        ok = success(pipeline(`$(bins.authelia) validate-config --config $config`; stdout = out, stderr = out))
        ok || @error "authelia rejects" out = String(take!(out))
        return ok
    end
    smtp = Dict("host" => "127.0.0.1", "port" => 1, "username" => "u", "password" => "it's", "sender" => "bot@example.com")
    proxied(cfg) = BT.ProxyAuth(cfg, "k"^64)
    @test authelia_accepts(proxied(BT.ProxyConfig(; base...)), nothing)
    @test authelia_accepts(proxied(BT.ProxyConfig(; base...)), smtp)
    # Behind a tunnel: the portal under the dashboard's own name.
    @test authelia_accepts(BT.TunnelAuth(BT.ProxyConfig(; domain = base.domain, admin = "bob", tls = "tunnel",
                                                        users_file = base.users_file)), nothing)

    # With mail configured, Authelia starts even while the mail server is out
    # (here: nothing listens on its port). It used to exit instead, which left
    # nobody able to log in over a mail outage.
    sock = listen(Sockets.IPv4(0x7f000001), 0)
    port = Int(Sockets.getsockname(sock)[2])
    close(sock)
    write(config, BT.render_authelia_config(proxied(BT.ProxyConfig(; base..., authelia_port = port)), secrets, smtp))
    log = joinpath(dir, "authelia.log")
    proc = run(pipeline(`$(bins.authelia) --config $config`; stdout = log, stderr = log); wait = false)
    try
        healthy() = process_running(proc) &&
            (try HTTP.get("http://127.0.0.1:$(port)/api/health"; retry = false, request_timeout = 2).status == 200
             catch e; e isa HTTP.Exceptions.ConnectError || rethrow(); false end)
        up = timedwait(healthy, 30.0; pollint = 0.5) === :ok
        up || @error "authelia did not come up" log = read(log, String)
        @test up
    finally
        process_running(proc) && kill(proc)
    end
end

@testitem "unit:proxy_auth the server's routes behind the proxy" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    const BW = BT.BonitoWorker
    using Test, HTTP, JSON, Dates
    Sys.islinux() || return

    bins = BT.fetch_proxy_binaries(joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                                            "bonitoagents-test", "proxy-bin"))
    dir = mktempdir()
    authelia = mkpath(joinpath(dir, "authelia"))
    write(joinpath(dir, "proxy.json"), JSON.json(Dict(
        "domain" => "team.example.com", "auth_domain" => "auth.team.example.com", "admin" => "bob",
        "caddyfile" => joinpath(dir, "Caddyfile"), "users_file" => joinpath(authelia, "users.yml"),
        "caddy_bin" => bins.caddy, "authelia_bin" => bins.authelia)))
    auth = BT.auth_mode(dir)
    state = BT.serve(; port = 0, auth, state_dir = dir, working_dir = mktempdir())
    url = "http://127.0.0.1:$(state.srv.port)"
    try
        # Starting behind the proxy renders what Caddy and Authelia read.
        @test isfile(auth.config.caddyfile) && isfile(auth.config.users_file)
        @test isfile(BT.authelia_config_file(auth.config))
        @test state.base_url[] == "https://team.example.com"

        # What Caddy sends: its key, and who Authelia logged in.
        as(user, groups = "") = [BT.PROXY_KEY_HEADER => auth.key, "Remote-User" => user, "Remote-Groups" => groups]
        get_(path, headers = Pair{String,String}[]) =
            HTTP.get(url * path, headers; status_exception = false, retry = false)
        refusal = "This server answers only through its login proxy"

        # The dashboard: nothing for a request that did not come through Caddy,
        # whatever it claims, nor for one Authelia did not log in.
        @test occursin(refusal, String(get_("/").body))
        @test occursin(refusal, String(get_("/", ["Remote-User" => "bob", "Remote-Groups" => "admins"]).body))
        @test occursin(refusal, String(get_("/", [BT.PROXY_KEY_HEADER => "0"^64, "Remote-User" => "bob"]).body))
        @test occursin(refusal, String(get_("/", [BT.PROXY_KEY_HEADER => auth.key]).body))
        page = get_("/", as("bob", "admins"))
        @test page.status == 200 && !occursin(refusal, String(page.body))

        # Chat-keyed routes: bob's chat and carol's, each with an ACP log.
        for (id, owner) in ("pbob" => "bob", "pcarol" => "carol")
            p = BT.ProjectInfo(id, id, "w1", mkpath(joinpath(dir, "srv", id)), "/w/$(id)", now(UTC))
            p.owner = owner
            state.projects[][id] = p
            mkpath(joinpath(dir, "chats", id))
            write(joinpath(dir, "chats", id, "acp.jsonl"), "{\"direction\":\"in\"}\n")
        end
        unknown(r) = r.status == 404 && occursin("unknown project", String(r.body))
        index = String(get_("/acp-log", as("carol")).body)
        @test occursin("pcarol", index) && !occursin("pbob", index)
        admin_index = String(get_("/acp-log", as("bob", "admins")).body)
        @test occursin("pcarol", admin_index) && occursin("pbob", admin_index)
        @test get_("/acp-log/pcarol", as("carol")).status == 200
        @test get_("/acp-log/pcarol", as("bob", "admins")).status == 200
        @test unknown(get_("/acp-log/pbob", as("carol")))
        @test unknown(get_("/acp-log/pcarol", as("dave")))
        @test unknown(get_("/acp-log/pcarol", ["Remote-User" => "carol"]))       # not through Caddy
        @test unknown(get_("/download/pbob?path=x.txt", as("carol")))
        @test !unknown(get_("/download/pcarol?path=x.txt", as("carol")))
        @test unknown(get_("/attachment/pbob?file=a.png", as("carol")))
        @test !unknown(get_("/attachment/pcarol?file=a.png", as("carol")))

        # The worker installer is open to anyone, and holds no secret.
        script = String(get_("/install.sh").body)
        @test occursin("https://team.example.com", script) && !occursin(auth.key, script)
        installer = String(get_("/install.jl").body)
        @test occursin("const SERVER = \"https://team.example.com\"", installer)
        @test occursin("const CREDENTIAL = isempty(ARGS)", installer)
        @test !occursin(auth.key, installer)

        # A worker that did not come through Caddy with a credential is refused
        # before it gets anywhere, with a reason it logs.
        w = BW.Worker(BW.WorkerConfig(; server_url = url, worker_id = "stray", name = "stray",
            mcp_command = "julia", mcp_arguments = String[], projects_root = mktempdir()))
        err = try BW.connect_once!(w); nothing catch e; e end
        close(w)
        @test err isa BW.WorkerLink.LinkRefused && occursin("no valid worker credential", err.reason)
        @test isempty(state.workers[])

        # An invite link: the form, then the account with a password Authelia
        # accepts for it, then nothing.
        link = BT.create_invite!(state, ["lab"])
        @test startswith(link, "https://team.example.com/invite/")
        path = "/invite/" * last(split(link, '/'))
        @test occursin("<form method=\"post\">", String(get_(path).body))
        made = HTTP.post(url * path, ["Content-Type" => "application/x-www-form-urlencoded"],
                         "name=erin&display_name=Erin+E&email=erin%40example.com"; status_exception = false)
        @test made.status == 200
        password = match(r"<code class=\"pw\">([^<]+)</code>", String(made.body))[1]
        users = read(auth.config.users_file, String)
        hash = match(r"'erin':\n(?:    .*\n)*?    password: '([^']+)'", users)[1]
        @test occursin("The password matches",
                       read(`$(bins.authelia) crypto hash validate --password $password -- $hash`, String))
        @test state.accounts[]["erin"].groups == ["lab"]
        @test get_(path).status == 404
        @test get_("/invite/" * "0"^64).status == 404
        @test get_("/invite/not-a-token").status == 404
    finally
        close(state.srv)
    end
end
