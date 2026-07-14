# Zombie worker link (#33): a suspend / wifi drop leaves the worker's control
# socket half-open — ESTABLISHED on both ends, nothing flowing. Production
# incident: the server kept the worker registered for 20+ minutes; every file
# open silently burned a 5s stat + 60s fetch timeout and chat binds died after
# 30s, reading as "the server crashed". SIGSTOP on the worker process is the
# lab-grade reproduction: the socket stays open, the process just stops
# answering — exactly the observed wedge.
#
# Own dev server (NOT SharedServer's): we freeze the worker and need
# sub-second heartbeat knobs. The heartbeat/offline assertions read
# `z.h.state` directly — the offline flip IS the contract here (every UI
# signal derives from it), and the worker-card pill only renders on the
# dashboard view.
@testitem "e2e:worker_zombie" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK

    z = TK.dev_server(agent = prompt -> [TK.text("echo: $(prompt)"), TK.end_turn()],
                      heartbeat_interval = 0.5, heartbeat_deadline = 2.5)
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

        wid = only(collect(keys(z.h.state.worker_control_ws)))
        @test z.h.state.workers[][wid].online[] == true

        freeze!()

        @testset "a stat timeout fails the open CLOSED, fast, with a toast" begin
            # Uncached path → the open-guard stat must time out (5s). Pre-fix
            # it failed OPEN into a silent 60s fetch; the user saw nothing.
            TK.eval_js(z, """(() => {
                const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
                c.__bt_chat.comm.notify({type: 'edit_file', id: '', path: 'zombie_probe.txt'});
                return true;
            })()""")
            @test TK.wait_for(z, "fail-closed toast within the stat timeout",
                "[...document.querySelectorAll('.bt-toast')].some(t => t.innerText.includes('zombie_probe.txt'))";
                timeout = 9) == true
        end

        @testset "heartbeat flips the zombie worker offline" begin
            # interval 0.5s + deadline 2.5s → the reaper must fire well within 10s.
            flipped = timedwait(10.0; pollint = 0.2) do
                z.h.state.workers[][wid].online[] == false
            end
            @test flipped == :ok
            # Teardown ran: the control socket registration is gone.
            @test !haskey(z.h.state.worker_control_ws, wid)
        end

        @testset "worker recovers after the wedge clears" begin
            unfreeze!()
            # The worker finds its socket closed by the server and re-dials.
            back = timedwait(60.0; pollint = 0.5) do
                haskey(z.h.state.worker_control_ws, wid) &&
                    z.h.state.workers[][wid].online[] == true
            end
            @test back == :ok
        end

        @testset "recovery leaves no stray agent process" begin
            # #28 keeps the chat model, but still tears down its DEAD ACP session
            # (`stop!(m.agent)`), so no worker-side agent subprocess may survive
            # into the fresh registration. NOTE this is a weak invariant here: over healthy
            # loopback the relay teardown already reaps (the server's session
            # close is deliverable), so this does NOT distinguish
            # `reap_all_sessions!` from the relay path — a real network wedge
            # (interface switch) can't be simulated without root. The reap
            # itself is covered by unit:reap_all_sessions.
            agent_count() = length(readlines(ignorestatus(
                pipeline(`pgrep -P $wpid -f MockACP`))))
            @test timedwait(() -> agent_count() == 0, 30.0; pollint = 0.5) == :ok
        end

        @testset "the chat stays live through the wedge and rebinds on the next message (#28)" begin
            # #28: a worker disconnect DELIBERATELY KEEPS the chat model AND its
            # open pane (it used to evict the model + tear the pane down — see
            # worker_client.jl "chats kept for reconnect"). Through the wedge the
            # pane renders offline; no chat vanishes from the sidebar. So there is
            # nothing to re-open and NO re-click: the pane is still here, and the
            # next message after the worker returns rebinds a fresh session in
            # place and streams a reply. Recovery is only real if the user can
            # keep chatting in the SAME pane.
            @test TK.wait_for(z, "open pane kept live through the wedge (never evicted)",
                "[...document.querySelectorAll('.bt-messages')].filter(e=>e.offsetParent).length === 1 && " *
                "[...document.querySelectorAll('textarea')].some(e=>e.offsetParent)";
                timeout = 15) == true
            # No re-click — send straight into the kept pane; the reconnect
            # rebinds on this message.
            TK.send_message(z, "back again")
            @test TK.wait_for(z, "post-recovery reply (rebound in place)",
                "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).some(n => n.innerText.includes('echo: back again'))";
                timeout = 90) == true
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(z))
        end
    finally
        unfreeze!()
        close(z)
    end
end
