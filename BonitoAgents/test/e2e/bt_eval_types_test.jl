# bt_julia_eval render-type coverage: real dev_server + electron, asserting the
# rendered DOM for 20+ output types, colored stdout, huge-output safety, and error
# rendering. See test/test_bt_eval_types_e2e.jl.
@testitem "e2e:bt_eval_types" setup = [SharedServer] tags = [:e2e] begin
    # Run against the ONE per-worker shared dev_server (like the rest of the e2e
    # suite) instead of a throwaway server — so opening a chat per run soaks the
    # server's cleanup/leak paths. The included file uses SharedServer.server()
    # + swaps agent_fn[]; it shares this TestKit so the dispatcher/SERVER_CONTEXT
    # is the live one.
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    include(joinpath(@__DIR__, "..", "test_bt_eval_types_e2e.jl"))
end
