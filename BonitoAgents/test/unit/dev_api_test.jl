@testitem "unit:dev_api" tags = [:unit] begin

# The inspection API behind the "Debug BonitoAgents" chat. Headless: a real
# `dev_server` (so the reports describe a real worker, real registries and a real
# log stream), driven through `dev_request` — the same entry point the MCP
# control channel calls, so nothing here tests a shape the tools won't see.
#
# The assertions that matter are the ACCESS ones. The dev tools can read the
# whole server and drive it, so "only a dev_mode project gets them" is a
# correctness property, not a preference.

using Test
import BonitoAgents, BonitoMCP
const BT = BonitoAgents

# A value whose `show` throws — the case that must not be able to take the
# process down from inside the logger. Defined at the testitem's top level
# because Julia has no local `struct`.
struct Unprintable end
Base.show(::IO, ::Unprintable) = error("this show method always throws")

# The allow-lists exist so an unknown op is a sentence the agent can act on
# ("unknown control op 'foo' — expected one of …") instead of a raw MethodError.
# That only holds while the list and the methods agree: a name in the list with
# no method dispatches straight into a MethodError, which is exactly the ugly
# failure the lists were introduced to prevent. Cheap to assert, easy to drift.
@testset "every advertised op is actually implemented" begin
    for op in BT.DEV_OPS
        @test hasmethod(BT.dev_op, Tuple{BT.ServerState, Val{op}, Dict{String,Any}})
    end
    for op in BT.DEV_CONTROL_OPS
        @test hasmethod(BT.dev_control, Tuple{BT.ServerState, Val{op}, Dict{String,Any}})
    end
    for sec in BT.DEV_SECTIONS
        # Sections take the narrowing target (a project or worker id), not args.
        @test hasmethod(BT.dev_section, Tuple{BT.ServerState, Val{sec}, String})
    end
    # And the rejection path still reads like a sentence.
    err = try; BT.known_or_throw(:nope, BT.DEV_CONTROL_OPS, "control op"); catch e; sprint(showerror, e); end
    @test occursin("unknown control op", err)
    @test occursin("open_chat", err)          # it lists what IS valid
end

@testset "log ring" begin
    BT.install_log_ring!()      # idempotent; serve() already did it if it ran
    marker = "unit-dev-api-probe-$(rand(UInt32))"
    @info marker answer = 42 who = "tester"
    @warn "$(marker)-warning"

    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                          worker_secret = "x")
    got = BT.dev_request(st, "logs", Dict("limit" => 500, "contains" => marker))
    @test got["matched"] >= 2
    recs = got["records"]
    info_rec = only(filter(r -> r["msg"] == marker, recs))
    # The message is the message — not `show`n into escaped quotes.
    @test info_rec["level"] == "Info"
    # The emitting module, as a string. Under ReTestItems that's the item's
    # generated module (`Main.var"##unit:dev_api#…"`), so only the prefix is
    # stable — what matters is that the field identifies where it came from.
    @test startswith(info_rec["mod"], "Main")
    @test info_rec["kv"]["answer"] == "42"
    @test info_rec["kv"]["who"] == "tester"      # a String value, unquoted
    @test occursin("dev_api_test.jl:", info_rec["at"])
    @test info_rec["ago_s"] < 60

    # Level filter: `warn` drops the Info record but keeps the warning.
    warned = BT.dev_request(st, "logs", Dict("limit" => 500, "level" => "warn",
                                             "contains" => marker))
    @test warned["matched"] == 1
    @test only(warned["records"])["level"] == "Warn"

    # The ring is bounded and says how much it has thrown away.
    @test got["capacity"] > 0
    @test got["evicted_total"] >= 0
    @test got["returned"] <= got["matched"]

    # An unprintable value must not lose the record.
    @info "$(marker)-unprintable" bad = Unprintable()
    bad = BT.dev_request(st, "logs", Dict("limit" => 500, "contains" => "$(marker)-unprintable"))
    @test bad["matched"] == 1
    @test occursin("unprintable", only(bad["records"])["kv"]["bad"])
end

@testset "inspect / memory / control against a live server" begin
    h = BT.dev_server(; port = 0)
    try
        registered = false
        for _ in 1:60
            isempty(h.state.workers[]) || (registered = true; break)
            sleep(0.5)
        end
        @test registered
        st = h.state
        wid = first(keys(st.workers[]))

        @testset "overview describes this process" begin
            o = BT.dev_request(st, "inspect", Dict("section" => "overview"))
            @test o["pid"] == getpid()
            @test o["uptime_s"] >= 0
            @test o["counts"]["workers"] == 1
            @test o["counts"]["workers_online"] == 1
            @test startswith(o["base_url"], "http")
            @test o["state_dir"] == st.state_dir
        end

        @testset "workers report their real connection state" begin
            ws = BT.dev_request(st, "inspect", Dict("section" => "workers"))
            w = only(ws)
            @test w["worker_id"] == wid
            @test w["online"] === true
            @test w["control_ws"] === true      # the actual socket, not the flag
            @test !isempty(w["projects_root"])
        end

        @testset "the worker reports on ITSELF" begin
            # The other half of the picture: `workers` is what the server
            # believes, this is what the worker process actually has. A "chat
            # looks alive but nothing happens" bug is the two disagreeing.
            w = BT.dev_request(st, "inspect", Dict("section" => "worker", "worker_id" => wid))
            @test w["worker_id"] == wid
            @test w["pid"] > 0 && w["pid"] != getpid()      # a separate process
            @test w["uptime_s"] >= 0
            @test w["rss_bytes"] > 0
            @test w["session_count"] == 0                    # no agent bound yet
            @test w["sessions"] isa AbstractVector
            @test !isempty(w["worker_package"])

            # Omitting the id reports every worker; an unknown one is an error.
            @test length(BT.dev_request(st, "inspect", Dict("section" => "worker"))) == 1
            @test_throws Exception BT.dev_request(st, "inspect",
                Dict("section" => "worker", "worker_id" => "no-such-worker"))
        end

        @testset "every section is JSON-encodable" begin
            # The reports cross a JSON wire to the MCP process, so a live object
            # leaking into one is a runtime failure in the tool, not here.
            for section in ("overview", "workers", "worker", "projects", "chats",
                            "evals", "settings")
                v = BT.dev_request(st, "inspect", Dict("section" => section))
                @test BonitoAgents.JSON.json(v) isa String
            end
            @test_throws Exception BT.dev_request(st, "inspect", Dict("section" => "nonsense"))
            @test_throws Exception BT.dev_request(st, "totally-unknown-op", Dict())
        end

        @testset "memory reports the leak-hunting counters" begin
            m = BT.dev_request(st, "memory", Dict("gc" => true))
            @test m["gc_ran"] === true
            @test m["live_bytes_after"] > 0
            @test m["rss_bytes"] > 0
            r = m["registries"]
            # The registries that have historically grown without bound are all
            # present — that list IS the point of the tool.
            for k in ("chat_models", "messages_total", "eval_bridges", "eval_parked_bytes",
                      "pending_rpcs", "worker_control_ws", "show_mirror_stamps",
                      "bound_lru", "log_records")
                @test haskey(r, k)
            end
            @test r["worker_control_ws"] == 1
            @test BonitoAgents.JSON.json(m) isa String

            deep = BT.dev_request(st, "memory", Dict("deep" => true))
            @test haskey(deep, "deep_sizes")
            @test deep["deep_sizes"]["projects"] > 0
        end

        @testset "control ops resolve their target, or say what's wrong" begin
            # A project to drive. (Not a chat: bringing an agent up needs a real
            # provider; the ops that don't touch one are what's tested here.)
            pid = "dev-api-proj"
            st.projects[][pid] = BT.ProjectInfo(pid, "Proj", wid, mktempdir(), mktempdir(),
                                                BT.now(BT.UTC))

            r = BT.dev_request(st, "control", Dict("op" => "set_title", "project_id" => pid,
                                                   "title" => "Renamed By Dev API"))
            @test r["ok"] === true
            @test st.projects[][pid].title == "Renamed By Dev API"

            r2 = BT.dev_request(st, "control", Dict("op" => "close_chat", "project_id" => pid))
            @test r2["dismissed"] === true
            @test st.projects[][pid].dismissed

            r3 = BT.dev_request(st, "control", Dict("op" => "rescan_worker", "worker_id" => wid))
            @test r3["ok"] === true
            @test r3["sessions_found"] >= 0

            # Wrong / missing targets are errors that NAME the target, not silent
            # no-ops — an agent driving the server blind has nothing else to go on.
            @test_throws Exception BT.dev_request(st, "control",
                Dict("op" => "set_title", "project_id" => "no-such-project"))
            @test_throws Exception BT.dev_request(st, "control", Dict("op" => "set_title"))
            @test_throws Exception BT.dev_request(st, "control",
                Dict("op" => "rescan_worker", "worker_id" => "no-such-worker"))
            @test_throws Exception BT.dev_request(st, "control", Dict("op" => "not_an_op"))
            @test_throws Exception BT.dev_request(st, "control",
                Dict("op" => "send_message", "project_id" => pid, "text" => "   "))
            # move_project refuses a same-worker move rather than doing something
            # surprising.
            @test_throws Exception BT.dev_request(st, "control",
                Dict("op" => "move_project", "project_id" => pid, "worker_id" => wid))
        end

        @testset "the debug project is created once and gated correctly" begin
            root = BT.bonitoagents_repo_root()
            if root === nothing
                @info "not a git checkout — skipping the debug-project cases"
            else
                p = BT.ensure_debug_project!(st)
                @test p.dev_mode
                @test p.worker_path == root
                @test p.title == BT.DEBUG_PROJECT_TITLE
                # Idempotent: clicking the button twice reuses the chat.
                @test BT.ensure_debug_project!(st).id == p.id

                # `dev_mode` is the ONLY thing that hands out the tools…
                @test haskey(BT.eval_dialback_env(st, p.id), "BONITOAGENTS_DEV_TOOLS")
                @test occursin("Debugging BonitoAgents itself",
                               BT.agents_prompt_appendix(st, p.id))

                # …and a project sitting at the very same path without the flag
                # gets neither. (Pointing an ordinary chat at the checkout must
                # not silently grant it the server's controls.)
                other = BT.ProjectInfo("plain-at-root", "BonitoAgents", wid,
                                       mktempdir(), root, BT.now(BT.UTC))
                st.projects[]["plain-at-root"] = other
                @test !haskey(BT.eval_dialback_env(st, "plain-at-root"), "BONITOAGENTS_DEV_TOOLS")
                @test !occursin("Debugging BonitoAgents itself",
                                BT.agents_prompt_appendix(st, "plain-at-root"))
            end
        end

        @testset "dev_mode survives a save/load round trip" begin
            # The flag is what keeps the tools attached across a restart, so it
            # has to persist — and must default to OFF for entries that predate it.
            BT.save_projects!(st)
            fresh = BT.ServerState(; state_dir = st.state_dir,
                                     working_dir = mktempdir(), worker_secret = "x")
            devs = [p for p in values(fresh.projects[]) if p.dev_mode]
            plain = [p for p in values(fresh.projects[]) if !p.dev_mode]
            @test BT.bonitoagents_repo_root() === nothing || length(devs) == 1
            @test !isempty(plain)

            # The case that actually ships: a projects.json written BEFORE this
            # flag existed — i.e. every install that upgrades into it. The key is
            # simply absent, and reading it must default to OFF rather than throw
            # (which would take the whole project list down on first launch).
            old_dir = mktempdir()
            write(joinpath(old_dir, "projects.json"), """
            [{"id": "legacy01", "name": "legacy", "worker_id": "w1",
              "server_path": "/tmp/legacy", "worker_path": "/tmp/legacy",
              "created": "2026-01-01T00:00:00"}]
            """)
            legacy = BT.ServerState(; state_dir = old_dir,
                                      working_dir = mktempdir(), worker_secret = "x")
            lp = get(legacy.projects[], "legacy01", nothing)
            @test lp !== nothing            # the entry loaded at all
            @test lp.dev_mode === false     # …and defaulted OFF, not to a throw
        end
    finally
        close(h)
    end
end

@testset "the MCP side only offers the tools when the server enabled them" begin
    names() = [t.name for t in BonitoMCP.available_tools()]
    dev = ("bt_dev_inspect", "bt_dev_logs", "bt_dev_memory", "bt_dev_control")
    had = get(ENV, "BONITOAGENTS_DEV_TOOLS", nothing)
    try
        delete!(ENV, "BONITOAGENTS_DEV_TOOLS")
        @test !any(in(names()), dev)
        # They're still REGISTERED — the registry is baked at precompile time, so
        # the gate has to be a runtime check.
        @test all(d -> any(t -> t.name == d, BonitoMCP.TOOLS), dev)
        # The normal tools are unaffected either way.
        @test "bt_julia_eval" in names()

        ENV["BONITOAGENTS_DEV_TOOLS"] = "1"
        @test all(in(names()), dev)
        @test "bt_julia_eval" in names()

        # Only an exact "1" opens the gate.
        ENV["BONITOAGENTS_DEV_TOOLS"] = "0"
        @test !any(in(names()), dev)
    finally
        had === nothing ? delete!(ENV, "BONITOAGENTS_DEV_TOOLS") :
                          (ENV["BONITOAGENTS_DEV_TOOLS"] = had)
    end
end

end
