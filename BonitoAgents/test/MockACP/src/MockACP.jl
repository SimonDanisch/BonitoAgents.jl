module MockACP

# Test-only mock ACP agent, run as an application: `julia -m MockACP`. A drop-in
# for the real claude-agent-acp binary — same JSON-RPC-over-stdio dialect — so the
# whole real spawn/transport/wire path is exercised with only the agent swapped.
# It is selected like any other provider via the AgentProviders `MockAgent`
# descriptor; no bash wrapper, no special test-only code path. The behaviour
# (scenarios + the dispatcher dial-back to the test process) lives in
# mock_logic.jl.

include("mock_logic.jl")

# Application entry point for `julia -m MockACP`. Read the spawner's env (scenario
# / dispatcher coords), then run the JSON-RPC dispatcher loop until stdin EOFs
# (the parent closing our stdin is the signal to exit cleanly).
function (@main)(args)
    _configure!()
    dispatch_loop()
    return 0
end

end # module
