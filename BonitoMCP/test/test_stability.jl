# Regression tests for the BonitoMCP stability findings (M2-M7, M9-M11, M14).
# These avoid spawning claude-agent-acp or networking; the worker-backed tests
# use a plain temp Malt session (same as test_eval_cancel.jl), and the rest hit
# pure helpers that were extracted specifically so they're unit-testable.

using Test
using BonitoMCP
const M = BonitoMCP

# helper_payload.jl defines a self-contained `BonitoMCPHelper` module. In
# production it's `include`d into each Malt worker (not into BonitoMCP itself),
# so for unit-testing its pure formatters we include it here directly.
include(joinpath(dirname(dirname(pathof(BonitoMCP))), "src", "helper_payload.jl"))
const Helper = BonitoMCPHelper

# ── M2: captured stdout is capped (no OOM, no tens-of-MB into the context) ─────
@testset "M2: stdout cap (pure helpers)" begin
    # cap_response_text keeps the TAIL within the byte budget + marks the drop.
    small = "hello"
    @test M.cap_response_text(small, 100) == small        # under budget → verbatim

    big = repeat("x", 10_000)
    capped = M.cap_response_text(big, 1_000)
    @test sizeof(capped) <= 1_000 + 200                   # budget + marker overhead
    @test occursin("stdout truncated", capped)
    @test endswith(capped, "x")                           # the tail is what's kept

    # cap_output_buffer! bounds the IOBuffer to STDOUT_CAP_BYTES, dropping head.
    buf = IOBuffer()
    write(buf, repeat("A", M.STDOUT_CAP_BYTES + 50_000))
    M.cap_output_buffer!(buf)
    @test buf.size <= M.STDOUT_CAP_BYTES + 200            # cap + marker line
    s = String(take!(buf))
    @test occursin("stdout truncated", s)
end

@testset "M2: huge-printing eval returns a capped response" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-m2-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    try
        # Print far more than the cap, then finish. The response stdout must be
        # bounded, not the multi-MB the worker actually emitted.
        r = M.execute(s, "for i in 1:2_000_000; println(i); end; 42";
                      timeout = 30.0)
        # Drain whatever variant we land in; if still running, interrupt to finish.
        if r.status == :running
            r = M.interrupt!(s)
        end
        stdout_blocks = filter(b -> startswith(get(b, "text", ""), "stdout:"),
                               get(r, :blocks, Dict{String,Any}[]))
        for b in stdout_blocks
            @test sizeof(b["text"]) <= M.STDOUT_CAP_BYTES + 1_000
        end
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end

# ── REPL semantics: soft scope + world-age-clean defs (execute path) ──────────
# The worker evals the code STRING per-top-level-statement (`repl_eval` →
# `include_string`, soft scope), NOT as one spliced expression. Regression for
# two things the old splice-as-argument path broke.
@testset "REPL semantics: soft-scope loops + world-age-clean defs" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-repl-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    outtext(r) = join(String[get(b, "text", "") for b in get(r, :blocks, Dict{String,Any}[])
                             if get(b, "type", "") == "text"], "\n")
    try
        # (1) Soft scope: a top-level for-loop assigns to a global. Under hard
        # scope this errored "acc not defined in local scope". No bridge in a
        # temp session → the result repr rides in the output text.
        r1 = M.execute(s, "acc = 0\nfor i in 1:5\n    acc += i\nend\nacc"; timeout = 30.0)
        @test r1.status == :completed
        @test r1.is_error == false
        @test occursin("15", outtext(r1))
        @test !occursin("local scope", outtext(r1))

        # (2) World age: define a function and call it in the SAME eval — no
        # "access to binding … in a world prior to its definition" warning.
        r2 = M.execute(s, "dbl(x) = 2x\ndbl(21)"; timeout = 30.0)
        @test r2.status == :completed
        @test r2.is_error == false
        @test occursin("42", outtext(r2))
        @test !occursin("prior to its definition", outtext(r2))
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end

# ── M5: continue/interrupt are pure lookups (never get_or_create!) ─────────────
@testset "M5: continue/interrupt error on absent session (no resurrection)" begin
    m = M.manager()
    missing_env = "/nonexistent-env-" * string(rand(UInt32))
    @test_throws Exception M.lookup_session(m, missing_env)
    # The tool handlers surface it as an isError response, not a new session.
    r = M.julia_continue_handler(Dict("env_path" => missing_env))
    @test r["isError"] == true
    @test !haskey(m.sessions, M._key(missing_env))      # nothing was created
    r2 = M.julia_interrupt_handler(Dict("env_path" => missing_env))
    @test r2["isError"] == true
    @test !haskey(m.sessions, M._key(missing_env))
end

# ── M6 + M10: kill_session! is terminal; start! refuses to resurrect ───────────
@testset "M6: killed session is terminal (start! refuses to resurrect)" begin
    s = M.JuliaSession(nothing; is_temp = true)
    M.start!(s)
    @test M.is_alive(s)
    M.kill_session!(s)
    @test s.closed == true
    @test !M.is_alive(s)
    # A killed session must NOT spin up a fresh untracked worker.
    @test_throws Exception M.start!(s)
    # execute also refuses (it calls start! internally).
    @test_throws Exception M.execute(s, "1+1"; timeout = 5.0)
end

@testset "M10: start! clears dialed_back so a fresh worker re-dials" begin
    s = M.JuliaSession(nothing; is_temp = true)
    s.dialed_back = true          # pretend a previous worker had dialed
    M.start!(s)
    try
        @test s.dialed_back == false   # fresh worker ⇒ must dial again
    finally
        M.kill_session!(s)
    end
end

# ── M4: concurrent kill during a poll never throws istaskdone(nothing) ─────────
@testset "M4: kill during in-flight poll is clean" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-m4-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    try
        r1 = M.execute(s, "sleep(30); 1"; timeout = 2.0)
        @test r1.status == :running
        # Poll concurrently while we kill — the poller must not MethodError on
        # istaskdone(nothing); it snapshots its own task.
        poller = @async try
            M.continue_eval!(s; timeout = 5.0)
            :ok
        catch e
            e   # an error here is acceptable (session gone), a MethodError is NOT
        end
        sleep(0.2)
        M.kill_session!(s)
        res = fetch(poller)
        @test !(res isa MethodError)
        @test s.closed == true
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end

# ── M3: a cancel's kill fallback only targets the eval it cancelled ────────────
# finalize_cancelled_eval! now takes the captured task; if a different/newer
# task occupies in_flight after the grace, it must NOT kill the worker.
@testset "M3: finalize targets the captured task only" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-m3-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    try
        M.start!(s)
        # A task that is already DONE (the cancelled one). With CANCEL_KILL_GRACE
        # being long, shorten by calling the finalizer logic with a done task and
        # a DIFFERENT current in_flight: it must not kill the live worker.
        done_task = @async 1
        wait(done_task)
        # Put a different "new eval" sentinel in in_flight.
        newtask = @async (sleep(0.3); 2)
        s.in_flight = newtask
        # finalize against the OLD (done) task: since s.in_flight !== done_task,
        # neither branch should kill the worker.
        ft = @async M.finalize_cancelled_eval!(s, done_task)
        # Don't wait the full grace; just assert the worker survives + newtask is
        # untouched shortly after.
        sleep(0.5)
        @test M.is_alive(s)
        @test s.in_flight === newtask
        # Let the finalizer finish (it sleeps the grace) without blocking the suite
        # unduly — it will no-op because in_flight !== done_task.
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end

# ── M9: cancel targets only the requestId's session ───────────────────────────
@testset "M9: requestId maps cancel to one session" begin
    # Pure mapping check — no workers needed.
    M.note_inflight_request!(42, "/some/env")
    got = lock(M.SERVER.inflight_lock) do
        get(M.SERVER.inflight, 42, :missing)
    end
    @test got == "/some/env"
    M.clear_inflight_request!(42)
    gone = lock(M.SERVER.inflight_lock) do
        get(M.SERVER.inflight, 42, :missing)
    end
    @test gone === :missing
end

# ── M11: trailing stdout printed right before the result isn't lost ────────────
@testset "M11: trailing stdout captured in the completed result" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-m11-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    try
        # Print then immediately return — the println must show up in THIS result.
        r = M.execute(s, "println(\"TRAILING_MARKER_123\"); 7"; timeout = 20.0)
        @test r.status == :completed
        joined = join(get(b, "text", "") for b in r.blocks)
        @test occursin("TRAILING_MARKER_123", joined)
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end

# ── M14: rich files are gated on a generous on-disk cap, not the response cap ───
# A value whose PNG render is ~50KB — comfortably over the 10KB response cap but
# well under the 50MB on-disk cap. Before M14, this silently degraded to text.
struct BigPng end
Base.showable(::MIME"image/png", ::BigPng) = true
Base.show(io::IO, ::MIME"image/png", ::BigPng) = write(io, fill(0x41, 50_000))

@testset "M14: try_save_rich uses on-disk cap, not max_bytes" begin
    @test Helper.RICH_FILE_CAP_BYTES > 1_000_000   # generous, not 10KB

    # The >10KB PNG must still produce a `shown:` file block even with the
    # default 10KB RESPONSE cap (the bytes go to disk, never the response).
    mktempdir() do dir
        block = Helper.try_save_rich(BigPng(), dir, 10_000)
        @test block !== nothing
        @test occursin("shown:", block["text"])
        @test occursin("image/png", block["text"])
        # The file actually landed on disk at full size.
        pngs = filter(f -> endswith(f, ".png"), readdir(dir))
        @test length(pngs) == 1
        @test filesize(joinpath(dir, pngs[1])) == 50_000
    end
end

# ── text/html is NOT a rich output ──────────────────────────────────────────
# An html show method is ubiquitous on values whose text/plain form (already in
# the response) is perfectly readable — method lists, DataFrames — and the chat
# renders html show files as raw SOURCE (see e2e:chat_show_extras). The old
# text/html arm turned a `methods(...)` eval result into a Monaco wall of
# markup. Only genuinely visual mimes (PNG/SVG) produce `shown:` files.
struct HtmlOnly end
Base.showable(::MIME"text/html", ::HtmlOnly) = true
Base.show(io::IO, ::MIME"text/html", ::HtmlOnly) = print(io, "<ul><li>hi</li></ul>")

@testset "try_save_rich ignores text/html-only values" begin
    mktempdir() do dir
        @test Helper.try_save_rich(HtmlOnly(), dir, 10_000) === nothing
        # The real-world case: a method list (html-showable in Base).
        @test Helper.try_save_rich(methods(push!), dir, 10_000) === nothing
        @test isempty(filter(f -> endswith(f, ".html"), readdir(dir)))
    end
    # format_value still ships the readable text repr for such values. With no
    # RemoteProxy bridge loaded here, there's no parked ref → the repr rides in
    # `echo` (the terminal output), NOT the descriptor. No rich file block, no
    # markup, no `html` descriptor.
    mktempdir() do dir
        r = Helper.format_value(methods(push!), dir, 10_000, false)
        @test isempty(r.blocks)          # html-only value → no rich file block
        @test r.html === nothing         # no bridge → no descriptor
        @test r.echo !== nothing
        @test occursin("push!", r.echo)
        @test !occursin("<li>", r.echo)
    end
end
