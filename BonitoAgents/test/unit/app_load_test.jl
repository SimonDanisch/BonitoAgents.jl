# Loading an app package into a running server (`load_app!`, what `bt_load_app`
# asks for): it starts the package's apps next to the ones the server booted
# with, their tools reach the chats, the dashboards hear of it, and only an
# admin's chat may ask. Nothing loads before a person approves it on the chat's
# card, from an admin's tab. The package is fixtures/HelloApp, a dependency of
# this test environment, so loading it never changes the environment.
@testitem "unit:app_load" tags = [:unit] begin
    import BonitoAgents as BT
    import Bonito
    using Dates

    fixture = abspath(joinpath(@__DIR__, "..", "fixtures", "HelloApp"))
    hello = Base.PkgId(Base.UUID("564b8dfd-92fb-49f9-a20f-8b12c6435fc7"), "HelloApp")
    # Before anything loads: a fixture outside the environment would make the
    # load `Pkg.develop` it into this test environment.
    BT.in_server_env(hello, fixture) ||
        error("HelloApp is not a dependency of the test environment at $fixture")

    @testset "where the package is" begin
        @test BT.in_server_env(hello, fixture)
        # Another checkout of it isn't the one in the environment.
        @test !BT.in_server_env(hello, mktempdir())
        @test_throws "no package at" BT.load_app!(BT.ServerState(; state_dir = mktempdir(),
            working_dir = mktempdir()), mktempdir())
        nameless = mktempdir()
        write(joinpath(nameless, "Project.toml"), "[deps]\n")
        @test_throws "names no package" BT.load_app!(BT.ServerState(; state_dir = mktempdir(),
            working_dir = mktempdir()), nameless)
    end

    dir = mktempdir()
    cfg = BT.ProxyConfig(; domain = "team.example.com", auth_domain = "auth.team.example.com", admin = "bob",
                         caddyfile = joinpath(dir, "Caddyfile"), users_file = joinpath(dir, "users.yml"),
                         session_socket = joinpath(dir, "sessions", "store.sock"))
    server = BT.ServerState(; state_dir = dir, working_dir = mktempdir(), auth = BT.ProxyAuth(cfg, "k"))
    server.accounts[]["bob"] = BT.Account("bob", "Bob", "b@x", ["admins"], false, "\$argon2id\$b")
    server.accounts[]["carol"] = BT.Account("carol", "Carol", "c@x", ["members"], false, "\$argon2id\$c")
    chat(id, owner) = (p = BT.ProjectInfo(id, id, "w", mktempdir(), "/home/u/p/$id", now(UTC));
                       p.owner = owner; BT.add_project!(server, p))
    bobs, carols = chat("c-bob", "bob"), chat("c-carol", "carol")
    load(caller) = BT.dev_request(server, "app_load", Dict{String,Any}("path" => fixture), caller.id)
    tools(caller) = [t["name"] for t in BT.dev_request(server, "app_tools", Dict{String,Any}(), caller.id)]
    # A tab of the person, as the chat's card command sees it.
    tab(name, groups) = copy(server, Bonito.Session(), BT.User(name, "$name@x", name, groups))
    admin, member = tab("bob", ["admins"]), tab("carol", ["members"])
    # The load a chat asked for, on its own task (it waits for the answer), and
    # its card once it shows.
    function ask(caller)
        t = Threads.@spawn load(caller)
        timedwait(() -> !isempty(BT.app_load_cards(server, caller.id)) || istaskdone(t), 30.0)
        istaskdone(t) && fetch(t)       # it ended without asking: show why
        return t, only(BT.app_load_cards(server, caller.id))
    end

    @testset "only an admin's chat loads an app" begin
        @test_throws "only an admin's chat" load(carols)
        @test !haskey(server.apps, "hello")
    end

    @testset "nothing loads without a person's yes" begin
        t, card = ask(bobs)
        @test card["kind"] == "app_load"
        @test card["job"] == "HelloApp"
        @test occursin(fixture, card["text"])
        @test !haskey(server.apps, "hello")               # waiting, not loaded
        # A member's tab may not approve it, and the agent has no way to: only
        # this command answers, and no MCP op leads to it.
        @test_throws "only an admin can approve" BT.answer_app_load!(member, bobs.id, card["key"], true)
        @test_throws "already answered" BT.answer_app_load!(admin, carols.id, card["key"], true)
        @test !any(op -> occursin("answer", string(op)), BT.DEV_OPS)
        # Declined: the agent hears so, nothing loads, the card goes.
        @test BT.answer_app_load!(admin, bobs.id, card["key"], false)
        @test_throws "declined" fetch(t)
        @test !haskey(server.apps, "hello")
        @test isempty(BT.app_load_cards(server, bobs.id))
        @test_throws "already answered" BT.answer_app_load!(admin, bobs.id, card["key"], true)
        # Unanswered: it expires.
        @test BT.await_load_approval(server, bobs, fixture; timeout = 0.2) === :expired
        @test isempty(BT.app_load_cards(server, bobs.id))
        @test !haskey(server.apps, "hello")
    end

    @testset "the package's app starts next to the booted ones" begin
        changed = server.apps.changed[]
        t, card = ask(bobs)
        @test BT.answer_app_load!(admin, bobs.id, card["key"], true)
        r = fetch(t)
        @test [a["id"] for a in r["apps"]] == ["hello"]
        @test only(r["apps"])["tools"] == ["hello_greet"]
        @test r["added"] == false            # already in the environment
        @test r["marked"] == false           # so it won't come back after a restart
        @test sort(keys(server.apps)) == ["hello", "todo"]
        @test server.apps.changed[] == changed + 1
        # An admin's chat gets its tool right away; a member's doesn't (admins only by default).
        @test "hello_greet" in tools(bobs)
        @test !("hello_greet" in tools(carols))
        reply = BT.dev_request(server, "app_call", Dict{String,Any}("tool" => "hello_greet",
            "args" => Dict{String,Any}("name" => "Ada")), bobs.id)
        @test reply["result"]["content"][1]["text"] == "Hello, Ada!"
    end

    @testset "once per server" begin
        @test_throws "already runs on this server" BT.load_app!(server, fixture)
        # The package is loaded once per process; another server starts its own app.
        other = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
        @test [BT.app_id(a) for a in BT.load_app!(other, fixture).apps] == ["hello"]
        @test other.apps["hello"] !== server.apps["hello"]
    end
end
