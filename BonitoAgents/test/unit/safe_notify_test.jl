# `safe_notify!` fans a server-side state change out to every UI listener. Its
# callers are worker registration and worker teardown, so one listener's bug
# must cost that listener one notification, not the worker its registration:
# with the error rethrown, the websocket layer closed the socket silently and
# the worker redialed forever (Laptop, 2026-09-15).
@testitem "unit:safe_notify" tags = [:unit] begin
    import BonitoAgents
    import Bonito
    const BT = BonitoAgents
    using Test

    obs = Bonito.Observable(1)
    seen = Int[]
    Bonito.on(v -> push!(seen, 10v), obs)
    Bonito.on(_ -> error("a UI listener with a bug"), obs)
    Bonito.on(v -> push!(seen, 100v), obs)

    @test_logs (:error, r"a listener failed") match_mode=:any BT.safe_notify!(obs)
    @test seen == [10, 100]          # both healthy listeners ran, in order
    @test length(obs.listeners) == 3 # a real error does not deregister anything

    # A dead browser tab is still dropped, quietly, and the others keep running.
    empty!(seen)
    Bonito.on(_ -> error("Updating the session dom for a closed session"), obs)
    @test_logs (:warn, r"stale browser-session") (:error, r"a listener failed") match_mode=:any BT.safe_notify!(obs)
    @test seen == [10, 100]
    @test length(obs.listeners) == 3
end

# `safe_set!` sets a value the browser shows. It caught every error at `@debug`,
# so a file tab whose body failed to arrive stayed on "loading…" with nothing in
# the log. It now runs the listeners like `safe_notify!`.
@testitem "unit:safe_set" tags = [:unit] begin
    import BonitoAgents
    import Bonito
    const BT = BonitoAgents
    using Test

    obs = Bonito.Observable{Any}("loading…")
    seen = Any[]
    Bonito.on(v -> push!(seen, v), obs)
    Bonito.on(_ -> error("rendering the body failed"), obs)
    Bonito.on(v -> push!(seen, (:after, v)), obs)
    @test_logs (:error, r"a listener failed") match_mode=:any BT.safe_set!(obs, "body")
    @test obs[] == "body"
    @test seen == ["body", (:after, "body")]   # the failure cost only its own listener

    # Equal values notify nobody when the Observable asks for it, as `obs[] = val`.
    eq = Bonito.Observable(1; ignore_equal_values = true)
    hits = Ref(0)
    Bonito.on(_ -> hits[] += 1, eq)
    BT.safe_set!(eq, 1)
    @test hits[] == 0
    BT.safe_set!(eq, 2)
    @test hits[] == 1 && eq[] == 2
end
