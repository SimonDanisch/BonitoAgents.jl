# Zombie worker link (#33): a suspend / wifi drop leaves the worker's connection
# half-open — ESTABLISHED on both ends, nothing flowing. Production incident:
# the server kept the worker registered for 20+ minutes; every file open
# silently burned a 5s stat + 60s fetch timeout and chat binds died after 30s,
# reading as "the server crashed". SIGSTOP on the worker process is the
# lab-grade reproduction: the socket stays open, the process just stops
# answering — exactly the observed wedge.
#
# Since the worker link, a wedge no longer costs the chat anything: the link's
# ping deadline drops the dead connection (the worker shows offline), the link
# itself waits, and once the worker answers again it RESUMES — same link, same
# agent process, and the chat carries on in the same session.
#
# Own dev server (NOT SharedServer's): we freeze the worker and need
# sub-second liveness knobs. The offline/link assertions read `z.h.state`
# directly — the offline flip IS the contract here (every UI signal derives
# from it), and the worker-card pill only renders on the dashboard view.
@testitem "e2e:worker_zombie" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    import BonitoAgents as BT

    # Start RELAXED and tighten the link's liveness only once the chat is up
    # (see `arm!` below). Armed from birth at 0.5s/2.5s, this item dropped its
    # OWN healthy worker: as the last of eleven items in a CI shard, a fresh
    # worker needs longer than that to answer its first ping, and the run died
    # on "chat view opened" — never reaching anything this test is about.
    z = TK.dev_server(agent = prompt -> [TK.text("echo: $(prompt)"), TK.end_turn()],
                      heartbeat_interval = 5.0, heartbeat_deadline = 60.0)
    # The knobs the wedge detection is measured with, applied to the live link
    # when we are ready to wedge the worker.
    arm!(link) = BT.WorkerLink.set_liveness!(link; ping_interval = 0.5, ping_deadline = 2.5)
    wpid = getpid(z.h.worker_proc)
    frozen = Ref(false)
    freeze!()   = (run(`kill -STOP $wpid`); frozen[] = true)
    unfreeze!() = (frozen[] && run(`kill -CONT $wpid`); frozen[] = false)
    try
        TK.open_browser(z)
        pid = TK.new_chat(z; title = "Zombie")
        TK.send_message(z, "hello")
        @test TK.wait_for(z, "chat bound + first reply",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 1";
            timeout = 90) == true

        wid = only(collect(keys(z.h.state.worker_links)))
        link = z.h.state.worker_links[wid]
        @test z.h.state.workers[][wid].online[] == true
        agent_pids() = readlines(ignorestatus(pipeline(`pgrep -P $wpid -f MockACP`)))
        # The chat's agent, once the worker's short-lived ones (the session
        # scan's `session/list` spawns) are gone.
        @test timedwait(() -> length(agent_pids()) == 1, 60.0; pollint = 0.5) == :ok
        agents_before = agent_pids()

        arm!(link)  # sub-second knobs from here on: the wedge is what we measure
        freeze!()

        @testset "a stat timeout fails the open CLOSED, fast, with a toast" begin
            # Uncached path → the open-guard stat must time out (5s). Pre-fix
            # it failed OPEN into a silent 60s fetch; the user saw nothing.
            TK.eval_js(z, """(() => {
                const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
                c.__bt_chat.comm.notify({type: 'edit_file', id: '', path: 'zombie_probe.txt'});
                return true;
            })()""")
            @test TK.wait_for(z, "fail-closed message within the stat timeout",
                "[...document.querySelectorAll('.bt-prog-err')].some(t => t.innerText.includes('zombie_probe.txt'))";
                timeout = 9) == true
        end

        @testset "the ping deadline flips the wedged worker offline" begin
            # interval 0.5s + deadline 2.5s → the link must drop the connection
            # well within 20s.
            flipped = timedwait(20.0; pollint = 0.2) do
                z.h.state.workers[][wid].online[] == false
            end
            @test flipped == :ok
            # Only the CONNECTION is gone: the link waits for the worker, and
            # the worker stays registered.
            @test BT.WorkerLink.state(link) === :detached
            @test z.h.state.worker_links[wid] === link
        end

        @testset "the thawed worker resumes the same link and keeps its agent" begin
            unfreeze!()
            back = timedwait(60.0; pollint = 0.5) do
                z.h.state.workers[][wid].online[] == true
            end
            @test back == :ok
            @test z.h.state.worker_links[wid] === link         # resumed, not replaced
            @test agent_pids() == agents_before                # the SAME agent process
        end

        @testset "the chat carries on in the same pane" begin
            # Nothing was torn down, so there is nothing to rebind: the next
            # message goes to the agent that was running all along.
            @test TK.wait_for(z, "open pane kept live through the wedge",
                "[...document.querySelectorAll('.bt-messages')].filter(e=>e.offsetParent).length === 1 && " *
                "[...document.querySelectorAll('textarea')].some(e=>e.offsetParent)";
                timeout = 15) == true
            TK.send_message(z, "back again")
            @test TK.wait_for(z, "reply after the wedge",
                "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).some(n => n.innerText.includes('echo: back again'))";
                timeout = 90) == true
            @test agent_pids() == agents_before
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(z))
        end
    finally
        unfreeze!()
        close(z)
    end
end
