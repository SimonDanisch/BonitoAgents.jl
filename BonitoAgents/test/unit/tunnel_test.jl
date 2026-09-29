# A server behind a tunnel (`TunnelAuth`, tunnel.jl): no Caddy in front, the
# server asks Authelia about every request itself and serves Authelia's login
# under its own name. Against the real Authelia, over plain HTTP to 127.0.0.1 the
# way cloudflared delivers requests. `e2e:tunnel_login` logs in from a browser.

@testitem "unit:tunnel the login gate against the real Authelia" tags = [:unit] begin
    import BonitoAgents, Bonito
    const BT = BonitoAgents
    const BW = BT.BonitoWorker
    using Test, HTTP, JSON, Dates, SHA
    Sys.islinux() || return

    # An authenticator app's one-time code (RFC 6238: 30 s steps, 6 digits, SHA-1),
    # from the secret in the `otpauth://` link the server hands out.
    B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    function unbase32(text)
        bits = join(string(findfirst(==(c), B32) - 1; base = 2, pad = 5) for c in text)
        return [parse(UInt8, bits[i:i+7]; base = 2) for i in 1:8:(length(bits) - 7)]
    end
    secret_of(a) = unbase32(match(r"[?&]secret=([A-Z2-7]+)", a.uri)[1])
    function totp(secret::Vector{UInt8}, step::Integer)
        h = SHA.hmac_sha1(secret, reverse(reinterpret(UInt8, [UInt64(step)])))
        o = h[end] & 0x0f
        code = (UInt32(h[o+1] & 0x7f) << 24) | (UInt32(h[o+2]) << 16) | (UInt32(h[o+3]) << 8) | UInt32(h[o+4])
        return lpad(string(code % UInt32(1_000_000)), 6, '0')
    end

    bins = BT.fetch_proxy_binaries(joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                                            "bonitoagents-test", "proxy-bin"))
    dir = mktempdir()
    users_file = joinpath(mkpath(joinpath(dir, "authelia")), "users.yml")
    port, aport = BT.free_port(), BT.free_port()
    write(joinpath(dir, "proxy.json"), JSON.json(Dict(
        "domain" => "team.example.com", "admin" => "bob", "port" => port, "authelia_port" => aport,
        "tls" => "tunnel", "authelia_bin" => bins.authelia, "users_file" => users_file)))
    auth = BT.auth_mode(dir)
    @test auth isa BT.TunnelAuth
    # bob, an admin, with the password Authelia made and an authenticator app.
    pw = BT.authelia_random_password(auth.config)
    BT.atomic_write_json(joinpath(dir, "accounts.json"),
                         [Dict(BT.Account("bob", "Bob B", "bob@example.com", ["admins"], false, pw.hash))])

    state = BT.serve(; port, auth, state_dir = dir, working_dir = mktempdir(), scan_on_connect = false)
    config = BT.authelia_config_file(auth.config)
    # The server registers bob's authenticator, as the installer has it do for the
    # first admin: before Authelia ever ran.
    bobs = BT.register_authenticator!(state, "bob")
    @test startswith(bobs.uri, "otpauth://totp/team.example.com:bob?") && occursin("issuer=team.example.com", bobs.uri)
    @test bobs.qr[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]     # a PNG
    secret = secret_of(bobs)
    log = joinpath(dir, "authelia.log")
    authelia = run(pipeline(`$(bins.authelia) --config $(config)`; stdout = log, stderr = log); wait = false)
    url = "http://127.0.0.1:$(port)"
    try
        up() = try
            HTTP.get("$(url)/authelia/api/health"; retry = false, status_exception = false).status == 200
        catch e
            e isa HTTP.ConnectError || rethrow()
            false
        end
        @test timedwait(up, 30.0; pollint = 0.5) === :ok

        # What the installer's answers make: the address people use, Authelia's
        # login under it, and no Caddy.
        @test state.base_url[] == "https://team.example.com"
        @test BT.portal_url(auth) == "https://team.example.com/authelia"
        @test !isfile(joinpath(dir, "Caddyfile"))
        cfg_text = read(config, String)
        @test occursin("address: 'tcp://127.0.0.1:$(aport)/authelia'", cfg_text)
        @test occursin("- domain: 'team.example.com'", cfg_text)

        get_(target, headers = Pair{String,String}[]) =
            HTTP.get(url * target, ["Accept" => "text/html", headers...];
                     status_exception = false, retry = false, redirect = false, cookies = false)
        login_first(r) = r.status == 302 &&
            startswith(HTTP.header(r, "Location"), "https://team.example.com/authelia/?rd=") &&
            HTTP.header(r, "Cache-Control") == "no-store"

        @testset "logged out: every route is the login first" begin
            for target in ("/", "/acp-log", "/acp-log/p1", "/download/p1?path=x", "/attachment/p1?file=a.png",
                           "/assets/anything.js", "/no-such-route")
                @test login_first(get_(target))
            end
            # Whatever a client claims to be.
            @test login_first(get_("/", ["Remote-User" => "bob", "Remote-Groups" => "admins"]))
            @test login_first(get_("/", ["X-Forwarded-User" => "bob", "X-Forwarded-Host" => "team.example.com"]))
            # Nothing rides on the open routes: only their exact targets are open.
            for target in ("/install.sh?/acp-log", "/install.sh/../acp-log", "/invite/$("0"^64)?/acp-log",
                           "/invite/$("0"^64)/x", "/w?x", "/install.shx")
                @test login_first(get_(target))
            end
            # A websocket (a dashboard tab's connection) is refused before it opens.
            @test_throws Exception HTTP.WebSockets.open(ws -> nothing, "ws://127.0.0.1:$(port)/some-session")
        end

        @testset "open to anyone: the installer, invites, Authelia's login page" begin
            script = get_("/install.sh")
            @test script.status == 200 && occursin("https://team.example.com", String(script.body))
            @test get_("/invite/" * "0"^64).status == 404           # the invite page's own answer
            portal = get_("/authelia/")
            @test portal.status == 200 && occursin("text/html", HTTP.header(portal, "Content-Type"))
        end

        @testset "workers: only with a credential, which the server checks" begin
            worker(id, credential) = BW.Worker(BW.WorkerConfig(; server_url = url, credential, worker_id = id,
                name = id, mcp_command = "julia", mcp_arguments = String[], projects_root = mktempdir()))
            stranger = worker("stranger", "")
            refused = try BW.connect_once!(stranger); nothing catch e; e end
            close(stranger)
            @test refused isa BW.WorkerLink.LinkRefused && occursin("no valid worker credential", refused.reason)
            issued = BT.add_worker_credential!(state, "bob")
            @test isempty(state.worker_credentials[][first(split(issued, ':'))].hash)   # no Caddy to check a hash
            admitted = worker("admitted", issued)
            task = @async BW.serve(admitted; retry_delay = 0.2)
            try
                @test timedwait(() -> BT.worker_connected(state, "admitted"), 30.0) === :ok
                @test BT.revoke_worker_credential!(state, first(split(issued, ':')))
                @test timedwait(() -> !BT.worker_connected(state, "admitted"), 30.0) === :ok
            finally
                close(admitted)
                wait(task)
            end
        end

        # Logging in through Authelia's API, as its login page does: its cookie
        # is for the dashboard's name, so it is carried by hand.
        post_(target, body, cookie = "") = HTTP.post(url * target,
            ["Content-Type" => "application/json", "Accept" => "application/json",
             (isempty(cookie) ? () : ("Cookie" => cookie,))...], JSON.json(body);
            status_exception = false, retry = false, redirect = false, cookies = false)
        session_cookie(r) = (m = match(r"authelia_session=([^;]+)", HTTP.header(r, "Set-Cookie", ""));
                             m === nothing ? "" : "authelia_session=" * m[1])

        @testset "logged in: the dashboard, as Authelia says who" begin
            wrong = post_("/authelia/api/firstfactor", Dict("username" => "bob", "password" => pw.password * "x",
                                                          "keepMeLoggedIn" => false))
            @test wrong.status == 401
            first_ = post_("/authelia/api/firstfactor", Dict("username" => "bob", "password" => pw.password,
                                                           "keepMeLoggedIn" => false,
                                                           "targetURL" => "https://team.example.com/"))
            @test first_.status == 200
            cookie = session_cookie(first_)
            @test !isempty(cookie)
            # One factor is not enough.
            @test login_first(get_("/", ["Cookie" => cookie]))
            second = post_("/authelia/api/secondfactor/totp",
                           Dict("token" => totp(secret, floor(Int, time() / 30)),
                                "targetURL" => "https://team.example.com/"), cookie)
            @test second.status == 200
            cookie = something(let c = session_cookie(second); isempty(c) ? nothing : c end, cookie)
            # Signed in with the authenticator the server registered, adding a
            # passkey needs nothing more: no code by mail first.
            json_(r) = JSON.parse(String(copy(r.body)))["data"]
            elevation = HTTP.get(url * "/authelia/api/user/session/elevation", ["Cookie" => cookie];
                                 status_exception = false, retry = false, cookies = false)
            @test elevation.status == 200 && json_(elevation)["skip_second_factor"] == true
            passkey = HTTP.request("PUT", url * "/authelia/api/secondfactor/webauthn/credential/register",
                                   ["Cookie" => cookie, "Content-Type" => "application/json"],
                                   JSON.json(Dict("description" => "Proton Pass"));
                                   status_exception = false, retry = false, cookies = false)
            @test passkey.status == 200
            options = json_(passkey)["publicKey"]
            @test options["rp"]["id"] == "team.example.com" && options["user"]["name"] == "bob"

            page = get_("/", ["Cookie" => cookie])
            html = String(page.body)
            @test page.status == 200
            @test !occursin("answers only through its login proxy", html)
            # Only the browser keeps what is behind the login.
            @test HTTP.header(page, "Cache-Control") == "no-store"
            asset = match(r"\"(/assets/[^\"?]+\.js(?:\?[^\"]*)?)\"", html)
            @test asset !== nothing
            js = get_(asset[1], ["Cookie" => cookie])
            @test js.status == 200 && startswith(HTTP.header(js, "Cache-Control"), "private")
            @test !occursin("public", HTTP.header(js, "Cache-Control"))

            # Who the request is from is Authelia's word, whatever the client sent.
            gate = BT.TunnelGate(auth)
            req = HTTP.Request("GET", "/acp-log", ["Cookie" => cookie, "Accept" => "text/html",
                                                   "Remote-User" => "carol", "Remote-Groups" => "nobody"])
            @test Bonito.HTTPServer.gate_request(gate, req) === nothing
            user = BT.request_user(auth, req)
            @test user.name == "bob" && user.groups == ["admins"] && user.display_name == "Bob B"
            forged = HTTP.Request("GET", "/acp-log", ["Remote-User" => "bob", "Remote-Groups" => "admins"])
            @test Bonito.HTTPServer.gate_request(gate, forged) isa HTTP.Response
            @test BT.request_user(auth, forged) === nothing

            # Logged out, it is the login first again.
            @test post_("/authelia/api/logout", Dict{String,Any}(), cookie).status == 200
            @test login_first(get_("/", ["Cookie" => cookie]))
        end

        @testset "an account made while Authelia runs, and a new authenticator" begin
            code_login(name, password, a) = begin
                first_ = post_("/authelia/api/firstfactor", Dict("username" => name, "password" => password,
                                                               "keepMeLoggedIn" => false))
                first_.status == 200 || return first_.status
                post_("/authelia/api/secondfactor/totp", Dict("token" => totp(secret_of(a), floor(Int, time() / 30))),
                      session_cookie(first_)).status
            end
            dave = BT.add_account!(state, "dave")
            # Authelia rereads its users database when it changes; give it that moment.
            @test timedwait(() -> code_login("dave", dave.password, dave.authenticator) == 200, 10.0; pollint = 1.0) === :ok
            # "New authenticator": the old one's codes stop working. (Authelia takes
            # one code per account and 30 s step, so this is an account that has
            # not logged in yet.)
            erin = BT.add_account!(state, "erin")
            renewed = BT.register_authenticator!(state, "erin")
            @test secret_of(renewed) != secret_of(erin.authenticator)
            @test timedwait(() -> code_login("erin", erin.password, erin.authenticator) == 403, 10.0; pollint = 1.0) === :ok
            @test code_login("erin", erin.password, renewed) == 200
        end

        @testset "without Authelia nothing behind the login answers" begin
            kill(authelia); wait(authelia)
            down = get_("/")
            @test down.status == 502 && occursin("login service", String(down.body))
            @test HTTP.header(down, "Cache-Control") == "no-store"
            @test get_("/install.sh").status == 200
        end
    finally
        process_running(authelia) && kill(authelia)
        close(state.srv)
    end

    # What a shared cache may keep: nothing, whatever a route said.
    @test BT.private_cache("") == "private"
    @test BT.private_cache("public, max-age=31536000, immutable") == "private, max-age=31536000, immutable"
    @test BT.private_cache("no-store") == "no-store"
    @test BT.private_cache("private, max-age=60") == "private, max-age=60"
    @test BT.private_cache("no-cache") == "private, no-cache"
end
