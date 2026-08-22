# Cancel against a BADLY-BEHAVED agent.
#
# Every cancel bug this project shipped lived in the gap between "the client
# asked to stop" and "the agent finished stopping" — and the existing cancel
# suites cannot see that gap. `chat_cancel_test.jl` has 41 references to cancel
# and ZERO to tools: it stops a text stream against a mock that breaks its loop
# the instant `cancelled[]` flips and answers `cancelled` immediately. Nothing
# is ever left in flight, so the states that break us never occur.
#
# These tests are written as INVARIANTS rather than flows. "Click stop, see the
# turn end, send a follow-up" passed throughout every one of the regressions
# below, because the follow-up genuinely worked — against a polite agent. What
# broke was narrower and never asserted:
#
#   * after a cancel, does the renderer still render?
#   * does a message typed during the cancel window reach the agent?
#
# Each testset names the shipped bug it would have caught.
@testitem "e2e:cancel_misbehaving" tags = [:e2e] setup = [SharedServer] begin

using Test
const S  = SharedServer
const TK = S.TK
const BA = TK.BT

# These need their own dev_server: the scenario is a property of the spawned
# MockACP process, not something the dispatcher can script (the dispatcher is by
# construction a well-behaved agent — it answers when the script says to).
function scenario_server(scenario::AbstractString; kw...)
    h = TK.dev_server(; scenario = scenario, kw...)
    TK.open_browser(h)
    return h
end

# Click the VISIBLE stop button, the way `chat_cancel_test.jl` does — a global
# selector can resolve to a hidden pane's button and the cancel then lands on the
# wrong (idle) chat.
stop!(s) = TK.eval_js(s, "(() => { const b = [...document.querySelectorAll('.bt-stop-btn')]" *
                         ".find(e => e.offsetParent !== null); if (!b) return false; " *
                         "b.click(); return true; })()")

# ── 1. An orphaned tool must not park the renderer  [NOT YET RUNNING] ────────
# The `cancel_orphan_tool` scenario is written and correct (MockACP: open a
# tool, never send its terminal frame, talk, then answer `cancelled`), and it
# reproduces the shipped bug in principle. But driving it from here does not
# work yet: the turn never settles, which says the mock is not observing the
# `session/cancel` — and MockACP's stderr is not plumbed into the test log, so
# there is no way to see which side is at fault without guessing.
#
# Parked deliberately rather than committed red or quietly deleted. To finish
# it: give `dev_server` a way to surface the agent subprocess's stderr (the
# worker sends it to a logfile, `BonitoWorker.jl:598`), then re-enable the
# block below. The invariant it asserts — after a cancel, output the agent
# produced while the renderer was parked must still reach the screen — is
# covered at the unit level meanwhile, in
# `AgentClientProtocol/test/runtests.jl` ("a cancelled span releases its tools;
# a handoff does not").
#=
# ── 1. An orphaned tool must not park the renderer ───────────────────────────
# Shipped bug: stopping a tool left it with no terminal frame ever coming (the
# adapter sits in its 30 s interrupt floor). A tool's update channel closes on
# its terminal frame, and the consumer BLOCKS draining it — so the renderer
# parked, the agent kept talking, and nothing appeared until a restart replayed
# the backlog. Reported as "stop took forever, my message did nothing, then I
# restarted and got 10 messages at once".
@testset "a cancelled turn's orphaned tool does not stop the renderer" begin
    s = scenario_server("cancel_orphan_tool")
    try
        TK.new_chat(s)
        TK.send_message(s, "run the long tool")
        # The tool is up and visible. Asserted on the title the mock gives it
        # rather than a DOM class, so the test says "the user can see the tool".
        @test TK.wait_for(s, "tool visible",
            "document.body.innerText.includes('long tool')"; timeout = 20) == true

        @test stop!(s) == true

        # THE INVARIANT: the agent keeps talking after the cancel, and we must
        # still render it. The mock emits `after-cancel1..3` AFTER answering
        # `cancelled` precisely so a parked renderer shows none of it.
        @test TK.wait_for(s, "post-cancel output still renders",
            "document.body.innerText.includes('after-cancel1')"; timeout = 25) == true
        # ...and the chat comes back to rest rather than spinning forever.
        @test TK.wait_for(s, "turn settles",
            "(() => { const b = document.querySelector('.bt-busy'); " *
            "return !!b && !b.classList.contains('bt-busy-active'); })()";
            timeout = 40) == true
    finally
        close(s)
    end
end

=#

# The server-side halves of `busy` (see `BonitoAgents.busy`), for a spinner that
# will not clear. Read straight off the live model — this is a diagnostic on
# failure only, never an assertion, so it does not make the suite depend on
# internals the way driving the chat through them would.
function busy_diag(s)
    st  = s.h.state
    pid = TK.current_chat_id(s)
    m   = get(st.chat_models, pid, nothing)
    m === nothing && return (; pid, model = "no ChatModel for this project")
    sh   = BA.shared(m)
    cli  = BA.client(m.agent)
    conn = cli === nothing ? nothing : cli.conn
    return (; pid,
            turn_in_flight = lock(() -> sh.turn_in_flight[], sh.lock),
            busy           = BA.busy(m),
            activity       = string(BA.session_activity(m)),
            active_prompts = conn === nothing ? -1 :
                             lock(() -> length(conn.active_prompts), conn.lock),
            pending_sends  = lock(() -> length(sh.pending_sends), sh.lock),
            queued         = isopen(sh.user_messages) ? "open" : "closed")
end

# ── 2. A message typed during the cancel window must not be swallowed ────────
# Shipped bug: claude-agent-acp settles turns queued while it is interrupting
# ("they have no in-flight SDK work to interrupt") — so a prompt sent inside the
# window was resolved WITHOUT RUNNING. The user's correction vanished and the
# loop died. `swallow_next_prompt` reproduces exactly that.
@testset "a message sent while cancelling still reaches the agent" begin
    s = scenario_server("swallow_next_prompt")
    try
        TK.new_chat(s)
        TK.send_message(s, "start working")
        @test TK.wait_for(s, "streaming",
            "document.body.innerText.includes('work1')"; timeout = 20) == true

        @test stop!(s) == true
        # Type immediately, the way a user correcting the agent does.
        TK.send_message(s, "STOP AND DO THIS INSTEAD")

        # THE INVARIANT: the message is not silently dropped. It either gets a
        # reply or is still visibly queued — what must NOT happen is the bubble
        # sitting there with the turn over and nothing having run.
        @test TK.wait_for(s, "the typed message is not lost",
            "(() => { const t = document.body.innerText; " *
            "return t.includes('STOP AND DO THIS INSTEAD'); })()"; timeout = 20) == true
        # This assertion carried an UNRESOLVED note for a long time, weighing
        # "the chat really does stay busy" against "this is the wrong
        # observable". It was NEITHER: the mock never swallowed the prompt.
        # `swallow_next_prompt` keyed on the per-prompt `cancelled` flag, which
        # the arriving prompt itself cleared, so it took the STREAMING branch
        # and looped forever — the chat was busy because the agent genuinely
        # never stopped talking. Fixed in MockACP with a sticky `INTERRUPTED`
        # latch; the diagnostic below is what named it (turn slot held,
        # activity = Prompted, active_prompts = 1 ⇒ a prompt on the wire that
        # never settled, not a lost turn slot on our side).
        #
        # The probe is scoped to the VISIBLE pane for the same reason `stop!`
        # above is: a bare `document.querySelector('.bt-busy')` can resolve to a
        # pane this testset isn't driving.
        settled = try
            TK.wait_for(s, "chat is usable again (not stuck busy)",
                "(() => { const b = [...document.querySelectorAll('.bt-busy')]" *
                ".find(e => e.offsetParent !== null); " *
                "return !!b && !b.classList.contains('bt-busy-active'); })()";
                timeout = 40)
        catch e
            e isa InterruptException && rethrow()
            # `busy` is a derivation of exactly two things, and the spinner alone
            # cannot say which one is stuck: OUR turn slot (`turn_in_flight`, held
            # by a `drain_turn!` that never finished) or the CONNECTION's view
            # (`Cancelling` persists while any prompt is active — see
            # `settle(::Cancelling, …)`). Naming the half is the whole
            # difference between a client bug and a protocol bug.
            @info "cancel_misbehaving: chat stayed busy" diag = busy_diag(s)
            false
        end
        @test settled == true
    finally
        close(s)
    end
end

# ── 3. A slow cancel is visible, and never loses output ──────────────────────
# The adapter waits `DEFAULT_FORCE_CANCEL_GRACE_MS` (30 s) for the SDK to yield.
# During that window the agent is still streaming. An earlier design MUTED the
# stream on cancel to reach the response sooner, which discarded those frames
# unparsed — the chat looked dead and only a reload brought them back.
@testset "output produced while a cancel winds down is kept" begin
    s = scenario_server("slow_cancel"; cancel_delay_ms = 2000)
    try
        TK.new_chat(s)
        TK.send_message(s, "stream please")
        @test TK.wait_for(s, "streaming",
            "document.body.innerText.includes('pre1')"; timeout = 20) == true

        @test stop!(s) == true

        # THE INVARIANT: frames the agent sent between the cancel and the
        # response are output it really produced — they must render, not vanish.
        @test TK.wait_for(s, "wind-down output rendered",
            "document.body.innerText.includes('winddown')"; timeout = 25) == true
        @test TK.wait_for(s, "turn settles",
            "(() => { const b = document.querySelector('.bt-busy'); " *
            "return !!b && !b.classList.contains('bt-busy-active'); })()";
            timeout = 40) == true
    finally
        close(s)
    end
end

end
