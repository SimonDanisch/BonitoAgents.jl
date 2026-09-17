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
