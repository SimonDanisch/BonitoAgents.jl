@testitem "unit:login_store" tags = [:unit] begin
    using BonitoAgents
    BT = BonitoAgents
    socket = "/private/login sessions/store.sock"
    cfg = BT.ProxyConfig(; domain = "team.example.com", admin = "admin", tls = "tunnel",
                         users_file = "/private/users.yml", session_socket = socket)
    auth = BT.TunnelAuth(cfg)
    secrets = (jwt = "j"^64, session = "s"^64, storage = "t"^64)
    y = BT.render_authelia_config(auth, secrets, nothing)
    @test occursin("  redis:\n    host: '$socket'\n    port: 0\n", y)
    @test BT.ProxyConfig(Dict("domain" => cfg.domain, "admin" => cfg.admin,
                             "users_file" => cfg.users_file, "session_socket" => socket)).session_socket == socket
    conf = BT.render_session_store_config(socket)
    @test occursin("port 0\n", conf)
    @test occursin("unixsocket \"$socket\"\n", conf)
    @test occursin("unixsocketperm 600\n", conf)
    @test occursin("appendonly yes\n", conf)
    @test occursin("dir \"/private/login sessions\"\n", conf)
end
