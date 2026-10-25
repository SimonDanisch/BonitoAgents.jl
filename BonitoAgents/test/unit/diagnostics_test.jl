# What the dev tools read beyond the server's tables (diagnostics.jl): timings of
# the server's work, the browser tabs it serves, and what their consoles said.
# A desktop waited 14 s for the page and a phone minutes, and none of it was
# visible: the time went where no line was written, and tabs that had gone away
# kept being served unseen.
@testitem "unit:diagnostics" tags = [:unit] begin
    using BonitoAgents, Bonito, Test
    import HTTP, JSON
    const BT = BonitoAgents

    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())

    @testset "timings" begin
        # The last `keep` of a kind, newest last.
        for i in 1:7
            BT.record_timing!(st, :probe, i / 10; keep = 5, n = i)
        end
        @test [e.detail["n"] for e in st.timings.kinds[:probe]] == 3:7
        # `timed` returns the value, and records a call that threw as not ok.
        @test BT.timed(() -> 42, st, :work; what = "fine") == 42
        @test_throws ErrorException BT.timed(() -> error("broke"), st, :work; what = "broken")
        @test [e.detail["ok"] for e in st.timings.kinds[:work]] == [true, false]

        got = BT.dev_request(st, "timings", Dict{String,Any}("kind" => "probe", "limit" => 2))
        @test got["kinds"] == ["probe", "work"]
        probe = got["timings"]["probe"]
        @test probe["summary"]["count"] == 5 && probe["summary"]["max_s"] == 0.7
        @test probe["summary"]["p50_s"] == 0.5
        @test [r["n"] for r in probe["recent"]] == [7, 6]          # newest first
        @test first(probe["slowest"])["seconds"] == 0.7
        @test !haskey(got["timings"], "work")                       # one kind asked
        slow = BT.dev_request(st, "timings", Dict{String,Any}("kind" => "probe", "min_seconds" => 0.65))
        @test [r["n"] for r in slow["timings"]["probe"]["recent"]] == [7]
        err = try BT.dev_request(st, "timings", Dict{String,Any}("kind" => "nope")); "" catch e; sprint(showerror, e) end
        @test occursin("no timings of kind 'nope'", err) && occursin("probe", err)
    end

    @testset "tabs" begin
        user(name) = BT.User(name, "", name, String[])
        view = Observable("p1")
        s = Bonito.Session()
        rec = BT.register_tab!(st, s, user("ann"), "10.0.0.1 Phone", view)
        other = BT.register_tab!(st, Bonito.Session(), user("bob"), "10.0.0.2 Desktop", Observable(""))
        report = BT.tab_report(rec)
        @test report["tab"] == first(s.id, 8) && report["user"] == "ann" && report["view"] == "p1"
        @test report["queued_messages"] == 0 && report["status"] == string(s.status)
        listed = BT.dev_request(st, "inspect", Dict{String,Any}("section" => "tabs", "tab" => first(s.id, 8)))
        @test [t["session"] for t in listed["open"]] == [s.id]
        @test BT.find_tab(st, first(s.id, 6)) === rec
        @test_throws ErrorException BT.find_tab(st, "zzzz-no-such")

        # A closed tab keeps its record without the session, and what it showed.
        view[] = "p2"
        close(s)
        @test !haskey(st.tabs.open, s.id)
        @test rec.session === nothing && rec.last_view == "p2"
        closed = only(BT.dev_request(st, "inspect", Dict{String,Any}("section" => "tabs"))["recently_closed"])
        @test closed["status"] == "CLOSED" && closed["view"] == "p2"

        # Closing an account's tabs closes its tabs only.
        @test BT.close_user_sessions!(st, "nobody") == 0
        @test BT.close_user_sessions!(st, "bob") == 1
        @test other.session === nothing

        # Only the newest closed tabs are kept.
        for _ in 1:4
            BT.register_tab!(st, Bonito.Session(), user("cy"), "c", Observable(""); keep_closed = 3)
        end
        BT.close_user_sessions!(st, "cy")
        @test length(st.tabs.closed) == 3
    end

    @testset "console beacons" begin
        rec = BT.register_tab!(st, Bonito.Session(), BT.User("dee", "", "dee", String[]), "phone", Observable(""))
        post(msg) = HTTP.Request("POST", BT.CONSOLE_ROUTE, [], Vector{UInt8}(JSON.json(msg)))
        entries = [Dict("t" => 1.0e9 + i, "level" => lvl, "text" => "line $i")
                   for (i, lvl) in enumerate(["log", "warn", "error", "WARN", "loud"])]
        r = BT.console_beacon_response(st, post(Dict("tab" => rec.id, "state" => "hidden", "entries" => entries)))
        @test r.status == 204
        @test [e.level for e in rec.console] == ["log", "warn", "error", "warn", "log"]  # known levels only
        @test rec.visibility == "hidden"
        # The tab keeps its last `keep`.
        BT.console_beacon_response(st, post(Dict("tab" => rec.id, "state" => "visible", "entries" => entries)); keep = 6)
        @test length(rec.console) == 6 && rec.visibility == "visible"
        @test BT.console_beacon_response(st, post(Dict("tab" => "gone", "entries" => []))).status == 404
        @test BT.console_beacon_response(st, HTTP.Request("GET", BT.CONSOLE_ROUTE)).status == 405
        @test BT.console_beacon_response(st, HTTP.Request("POST", BT.CONSOLE_ROUTE, [], zeros(UInt8, 300_000))).status == 413
        @test BT.console_beacon_response(st, HTTP.Request("POST", BT.CONSOLE_ROUTE, [], Vector{UInt8}("[1]"))).status == 400

        # A tab that can't be asked (never connected) answers with its beacons.
        got = BT.dev_request(st, "console", Dict{String,Any}("tab" => first(rec.id, 8), "level" => "warn",
                                                             "contains" => "LINE", "limit" => 2))
        @test got["source"] == "beacons" && got["total"] == 6
        @test got["matched"] == 3                     # the warns and the error of the six kept
        @test [e["text"] for e in got["entries"]] == ["line 3", "line 4"]   # the newest two
        # Closed, it still has them: a phone's last words arrive as it is left.
        close(rec.session)
        @test BT.console_beacon_response(st, post(Dict("tab" => rec.id, "state" => "pagehide",
                                                       "entries" => [Dict("t" => 2.0e9, "level" => "error", "text" => "last")]))).status == 204
        @test last(rec.console).text == "last" && rec.visibility == "pagehide"
        listing = BT.dev_request(st, "console", Dict{String,Any}())
        @test any(t -> t["tab"] == first(rec.id, 8) && t["console_from_beacons"] == 7, listing["tabs"])
    end
end
