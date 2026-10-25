@testitem "e2e:yolo_queue" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    s = SharedServer.server()
    BT = TK.BT
    pass = Ref(0)
    s.agent_fn[] = function(prompt)
        if occursin("Background Julia run", prompt)
            ids = unique([m.match for m in eachmatch(r"\br\d+\b", prompt)])
            return [TK.mcp_call("bt_julia_wait"; real_process=true, runs=ids, seconds=5),
                    TK.text("Background completion handled"), TK.end_turn()]
        elseif startswith(prompt, BT.YOLO_CONFIRM_PROMPT)
            return [TK.text(BT.YOLO_DONE_SENTINEL), TK.end_turn()]
        elseif startswith(prompt, BT.YOLO_CONTINUE_PROMPT)
            pass[] += 1
            pass[] > 3 && return [TK.text(BT.YOLO_DONE_SENTINEL), TK.end_turn()]
        end
        # The job finishes mid-turn, but its notifier waits for the idle edge,
        # racing YOLO exactly as in the live LLM Research chat.
        return [TK.bt_eval("sleep(1); :job_finished"; real_process=true, background=true),
                TK.text("Working on pass $(pass[])"), TK.delay(5000),
                TK.text("Pass $(pass[]) complete"), TK.end_turn()]
    end
    pid = TK.new_chat(s; title="YOLO and background completions")
    pane = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
    says(t) = "$pane?.querySelector('.bt-messages')?.textContent.includes($(repr(t))) === true"
    TK.send_message(s, "start background work")
    @test TK.wait_for(s, "initial turn is still working", says("Working on pass 0"); timeout=90)
    TK.eval_js(s, """(() => {
        const p = $pane;
        const sample = () => {
            const n = [...p.querySelectorAll('.bt-queue-item')].filter(e =>
                e.textContent.includes('You are being continued automatically') ||
                e.textContent.includes('Are you really done?')).length;
            window.__yoloQueueMax = Math.max(window.__yoloQueueMax || 0, n);
        };
        window.__yoloQueueProbe = new MutationObserver(sample);
        window.__yoloQueueProbe.observe(p, {subtree:true, childList:true, characterData:true});
        sample(); p.querySelector('.bt-yolo-bar').click(); return true;
    })()""")
    @test TK.wait_for(s, "background notifications are handled",
        says("Background completion handled"); timeout=90)
    @test TK.wait_for(s, "multiple productive continuations ran",
        says("Pass 3 complete"); timeout=90)
    @test TK.wait_for(s, "YOLO finishes its confirmation with an empty queue",
        "!$pane.querySelector('.bt-busy-active') && !$pane.querySelector('.bt-queue-item') && " *
        "[...$pane.querySelectorAll('.bt-user-msg-auto')].some(e => e.textContent.includes('Are you really done?'))";
        timeout=90)
    @test TK.eval_js(s, "window.__yoloQueueMax <= 1")
    @test TK.eval_js(s, "$pane.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')")
    TK.screenshot(s, joinpath(tempdir(), "bonitoagents-yolo-queue.png"))
    TK.reload!(s)
    @test TK.wait_for(s, "no stale nudges return on reload",
        "!!$pane?.querySelector('.bt-text-input') && !$pane.querySelector('.bt-queue-item') && !$pane.querySelector('.bt-busy-active')";
        timeout=30)
    @test isempty(TK.js_errors(s))
end
