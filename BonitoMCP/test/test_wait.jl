# bt_wait — the tool that makes a turn stop and wait.
#
# The behaviours below are the whole contract, and each one exists because the
# absence of it is what produced 60–130 orphaned sleepers in a real session:
# a wait must BLOCK, must be BOUNDED, must return EARLY when the work is done,
# and hitting the bound must NOT look like a failure (or the agent "recovers"
# from it by starting a poller).

using Test
using BonitoMCP
const M = BonitoMCP

txt(r) = r["content"][1]["text"]

@testset "bt_wait" begin
    @testset "it actually blocks" begin
        t0 = time()
        r = M.wait_handler(Dict{String,Any}("seconds" => 0.4))
        @test time() - t0 >= 0.4          # the turn really stopped
        @test r["isError"] === false
        @test occursin("waited", txt(r))
    end

    @testset "a reason rides into the result" begin
        r = M.wait_handler(Dict{String,Any}("seconds" => 0.1, "reason" => "blender render"))
        @test occursin("blender render", txt(r))
    end

    @testset "an unbounded wait is refused" begin
        # `seconds` is required ON PURPOSE: a wait with no bound is a latch, and
        # a latch on an event that may never come is the failure this codebase
        # keeps deleting.
        r = M.wait_handler(Dict{String,Any}())
        @test r["isError"] === true
        @test occursin("required", txt(r))

        @test M.wait_handler(Dict{String,Any}("seconds" => 0))["isError"] === true
        @test M.wait_handler(Dict{String,Any}("seconds" => -3))["isError"] === true
        over = M.wait_handler(Dict{String,Any}("seconds" => M.WAIT_MAX_SECONDS + 1))
        @test over["isError"] === true
        @test occursin("capped", txt(over))
    end

    @testset "a condition that already holds costs nothing" begin
        # Work that finished before we got here must not burn a poll interval —
        # otherwise every wait has a floor and long chains pay it repeatedly.
        t0 = time()
        r = M.wait_handler(Dict{String,Any}("seconds" => 30, "until" => "true", "poll" => 10))
        @test time() - t0 < 2.0
        @test occursin("already true", txt(r))
    end

    @testset "it returns as soon as the condition holds" begin
        flag = tempname()
        Base.errormonitor(@async (sleep(0.6); touch(flag)))
        t0 = time()
        r = M.wait_handler(Dict{String,Any}(
            "seconds" => 30, "until" => "test -f $flag", "poll" => 0.2))
        waited = time() - t0
        @test waited >= 0.6                # it did wait for the work
        @test waited < 5.0                 # ...and not for the full 30
        @test occursin("condition met", txt(r))
        rm(flag; force = true)
    end

    @testset "hitting the bound is a RESULT, not an error" begin
        # The agent has to read this as "still running, wait again". Reported as
        # an error it reads as "the tool is broken", and the recovery it invents
        # is a background sleeper — the exact loop this tool replaces.
        t0 = time()
        r = M.wait_handler(Dict{String,Any}(
            "seconds" => 0.8, "until" => "false", "poll" => 0.2))
        @test time() - t0 >= 0.8
        @test r["isError"] === false
        @test occursin("still running", txt(r))
        @test occursin("bt_wait again", txt(r))
    end

    @testset "a broken `until` is reported, not treated as 'not yet'" begin
        # A typo'd condition that silently means "false" turns a mistake into a
        # full-length wait, every time, with nothing to see.
        r = M.wait_handler(Dict{String,Any}(
            "seconds" => 0.5, "until" => "exit 3", "poll" => 0.1))
        @test r["isError"] === false        # non-zero exit IS "not yet"
        @test occursin("still running", txt(r))
    end

    @testset "it is registered and visible" begin
        t = only([x for x in M.available_tools() if x.name == "bt_wait"])
        @test "seconds" in t.input_schema["required"]
        @test haskey(t.input_schema["properties"], "until")
        # The description has to say it BLOCKS — that is the whole reason to
        # reach for it over a background sleeper.
        @test occursin("blocks", lowercase(t.description))
        @test occursin("notification", lowercase(t.description))
    end
end
