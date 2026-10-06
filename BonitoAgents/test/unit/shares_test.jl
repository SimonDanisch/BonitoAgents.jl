# Shared links (shares.jl), the parts that need no worker: which files a page
# may serve, what the login gate lets through, passwords and the unlock cookie,
# and the records on disk. `e2e:shares` runs the whole thing behind a tunnel.

@testitem "unit:shares" tags = [:unit] begin
    import BonitoAgents, Bonito
    const BT = BonitoAgents
    using Test, HTTP, Dates

    @testset "a page serves only the files it references" begin
        refs = BT.markdown_references("""
            # Report
            ![plot](figs/plot.png) ![clip](media/clip.mp4?t=3#start) [data](data%20set.csv)
            [web](https://example.com) [abs](/etc/passwd) [up](../secret.txt) [anchor](#top)
            [sneaky](figs/../../secret.txt) [mail](mailto:a@b.c)
            <video src="v/a.webm" poster='v/p.jpg'></video>
            """)
        @test refs == Set(["figs/plot.png", "media/clip.mp4", "data set.csv", "v/a.webm", "v/p.jpg"])
    end

    @testset "the gate: the link's own paths, an open page's websocket and assets" begin
        reg = BT.ShareRegistry()
        token = "0123456789abcdef"^2
        @test BT.is_share_target(reg, "/s/$(token)/")
        @test BT.is_share_target(reg, "/s/$(token)")
        @test BT.is_share_target(reg, "/s/$(token)/figs/plot.png?v=1")
        for t in ("/s/$(token)/../acp-log", "/s/$(token)/%2e%2e/acp-log", "/s/$(token)/./x",
                  "/s/abc/", "/s/$(token)x/", "/", "/acp-log", "/assets/" * "0"^40 * "-x.js",
                  "/some-session-id", "/a/b")
            @test !BT.is_share_target(reg, t)
        end
        # An open app page: its root session's websocket, and what it registered.
        page = Bonito.Session(Bonito.NoConnection(); asset_server = Bonito.NoServer())
        lock(() -> (reg.pages[page.id] = page), reg.lock)
        @test BT.is_share_target(reg, "/$(page.id)")
        @test BT.is_share_target(reg, "/$(page.id)?low_latency")
        @test !BT.is_share_target(reg, "/$(page.id)/x")
        lock(() -> delete!(reg.pages, page.id), reg.lock)
        @test !BT.is_share_target(reg, "/$(page.id)")
    end

    @testset "passwords and the unlock cookie" begin
        dir = mktempdir()
        state = BT.ServerState(; state_dir = mkpath(joinpath(dir, "state")),
                                 working_dir = mkpath(joinpath(dir, "work")))
        salt, hash = BT.password_fields("open sesame")
        @test length(salt) == 32 && hash == BT.share_password_hash("open sesame", salt)
        @test hash != BT.share_password_hash("open sesame!", salt)
        @test BT.password_fields("") == ("", "")
        l = BT.ShareLink("ab"^16, "admin", "w1", "/p/app.jl", "/p", "app", salt, hash, now(UTC))
        cookie(v) = HTTP.Request("GET", "/", ["Cookie" => "other=1; $(BT.unlock_cookie_name(l))=$(v)"])
        @test BT.share_unlocked(state, l, cookie(BT.unlock_cookie_value(state, l)))
        @test !BT.share_unlocked(state, l, cookie("0"^64))
        @test !BT.share_unlocked(state, l, HTTP.Request("GET", "/"))
        # A new password ends what the old one opened.
        salt2, hash2 = BT.password_fields("other")
        l2 = BT.ShareLink(l.id, l.owner, l.worker_id, l.path, l.env_path, l.title, salt2, hash2, l.created)
        @test !BT.share_unlocked(state, l2, cookie(BT.unlock_cookie_value(state, l)))
        open_link = BT.ShareLink(l.id, l.owner, l.worker_id, l.path, l.env_path, l.title, "", "", l.created)
        @test BT.share_unlocked(state, open_link, HTTP.Request("GET", "/"))
    end

    @testset "records: saved, loaded, found by token, ended" begin
        dir = mktempdir()
        sd = mkpath(joinpath(dir, "state"))
        state = BT.ServerState(; state_dir = sd, working_dir = mkpath(joinpath(dir, "work")))
        l = BT.ShareLink("cd"^16, "admin", "w1", "/p/report.md", "", "report", "", "", DateTime(2026, 9, 30))
        lock(state.shares.lock) do
            state.shares.links[][l.id] = l
            BT.save_shares!(state)
        end
        # The file holds the id, never the token (which is derived from the url key).
        token = BT.share_token(state, l.id)
        @test !occursin(token, read(BT.shares_file(state), String))
        again = BT.ServerState(; state_dir = sd, working_dir = mkpath(joinpath(dir, "work")))
        @test again.shares.links[][l.id] == l
        @test BT.share_by_token(again, token) == l
        @test BT.share_by_token(again, "0"^32) === nothing
        @test BT.revoke_share!(again, l.id)
        @test BT.share_by_token(again, token) === nothing
        @test !BT.revoke_share!(again, l.id)
        @test isempty(BT.ServerState(; state_dir = sd, working_dir = mkpath(joinpath(dir, "work"))).shares.links[])
    end

    @testset "what can be shared" begin
        @test BT.share_kind("/a/b.md") isa BT.MarkdownShare
        @test BT.share_kind("/a/b.MARKDOWN") isa BT.MarkdownShare
        @test BT.share_kind("C:/a/app.jl") isa BT.AppShare
        @test BT.share_kind("/a/data.csv") isa BT.FileShare
        @test BT.share_kind("/a/image.png") isa BT.FileShare
        @test BT.worker_isabspath("/home/x") && BT.worker_isabspath("C:/x") && BT.worker_isabspath("C:\\x")
        @test !BT.worker_isabspath("report.md")
    end

    @testset "live result records survive password changes and reload" begin
        sd = mktempdir()
        state = BT.ServerState(; state_dir = sd, working_dir = mktempdir())
        l = BT.ShareLink("ef"^16, "admin", "w2", "", "", "Julia result", "", "",
                         now(UTC), "chat1", "prefix/holder")
        @test BT.share_kind(l) isa BT.AppShare
        state.shares.links[][l.id] = l
        BT.set_share_password!(state, l.id, "secret")
        again = BT.ServerState(; state_dir = sd, working_dir = mktempdir())
        saved = again.shares.links[][l.id]
        @test saved.project_id == l.project_id
        @test saved.result_ref == l.result_ref
        @test saved.worker_id == "w2"
        @test !isempty(saved.password_hash)
        @test_throws ErrorException BT.shared_result_bridge(again, l.project_id, l.result_ref)
        # Asset checks grant only the public page's assets, never a whole chat bridge.
        again.shares.asset_checks["page"] = path -> path == "/assets/public-image"
        @test BT.is_share_target(again.shares, "/assets/public-image")
        @test !BT.is_share_target(again.shares, "/assets/private-image")
        empty!(again.shares.asset_checks)
        @test !BT.is_share_target(again.shares, "/assets/public-image")
    end
end

# The live-render bridges of an eval host's sessions die with the host. They go
# when their channel is still down a grace after the host's control channel
# closed; one that came back (a dropped link) stays. For a chat's host that is
# its one bridge, for a worker's share host every bridge of that worker; the one
# teardown also takes a share bridge off the login gate's list.
@testitem "unit:host bridges" tags = [:unit] begin
    import BonitoAgents, Bonito
    const BT = BonitoAgents
    using Test

    state = BT.serve(; host = "127.0.0.1", port = 0, state_dir = mktempdir(), working_dir = mktempdir())
    try
        bridge(key, prefix; live) = begin
            eb = BT.make_eval_bridge(prefix, key, live ? :channel : nothing, Bonito.HTTPAssetServer(state.srv))
            lock(() -> (state.eval_workers[key] = eb), state.lock)
            eb
        end
        share(prefix, worker; live) = begin
            eb = bridge(BT.share_bridge_key(prefix), prefix; live)
            lock(() -> (state.shares.bridges[prefix] = BT.ShareBridge(worker, eb.asset_host)), state.shares.lock)
            eb
        end
        chat_dead  = bridge(BT.eval_bridge_key("chat1", "w1"), "p-chat1"; live = false)
        chat_live  = bridge(BT.eval_bridge_key("chat2", "w1"), "p-chat2"; live = true)
        own        = bridge("chat1", "p-own"; live = false)          # the chat's own worker's: not a host's
        share_dead = share("p-s1", "w1"; live = false)
        share_live = share("p-s2", "w1"; live = true)
        other_w    = share("p-s3", "w2"; live = false)

        BT.host_channel_closed!(state, "chat1", "w1"; grace = 0.1)
        BT.host_channel_closed!(state, "chat2", "w1"; grace = 0.1)
        BT.host_channel_closed!(state, BT.SHARES_PROJECT, "w1"; grace = 0.1)
        BT.host_channel_closed!(state, "chat1", ""; grace = 0.1)    # a chat's own MCP: nothing
        sleep(1.0)
        keys_left = Set(keys(state.eval_workers))
        @test !(BT.eval_bridge_key("chat1", "w1") in keys_left)
        @test BT.eval_bridge_key("chat2", "w1") in keys_left
        @test "chat1" in keys_left
        @test !(BT.share_bridge_key("p-s1") in keys_left)
        @test BT.share_bridge_key("p-s2") in keys_left
        @test BT.share_bridge_key("p-s3") in keys_left                 # another worker's
        @test Set(keys(state.shares.bridges)) == Set(["p-s2", "p-s3"])
    finally
        close(state.srv)
    end
end
