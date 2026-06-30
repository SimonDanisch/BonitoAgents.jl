# bt_julia_eval render-type coverage: real dev_server + electron, asserting the
# rendered DOM for 20+ output types, colored stdout, huge-output safety, and error
# rendering. See test/test_bt_eval_types_e2e.jl.
@testitem "e2e:bt_eval_types" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "test_bt_eval_types_e2e.jl"))
end
