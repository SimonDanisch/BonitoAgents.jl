# A wait on a job blocks for up to an hour, and its card said "(loading…)" until
# the wait returned (2026-11-12). Opened while the wait runs, it shows the job,
# its command and its output, and follows the output as it grows.
@testitem "e2e:process_wait_card" setup=[SharedServer] tags=[:e2e] begin
    if Sys.isunix()
        TK = SharedServer.TK
        # `$x` keeps the output's words out of the command line the card also shows.
        command = "x=output; echo first-\$x; sleep 3; echo second-\$x; sleep 300"
        agent(prompt) = [
            TK.mcp_call("bt_process"; real_process = true, id = "start-job",
                arguments = Dict("action" => "start", "id" => "copy-job", "label" => "Copy the renders",
                                 "argv" => ["sh", "-c", command])),
            TK.mcp_call("bt_process"; real_process = true, id = "wait-job",
                arguments = Dict("action" => "wait", "id" => "copy-job", "seconds" => 60)),
            TK.text("Wait released"), TK.delay(1000)]
        s = TK.dev_server(; agent)
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        card = "$pane.querySelector('.bt-tool-body[data-tool-id=\"wait-job\"]')?.closest('.bt-tool-msg')"
        body = "($card?.querySelector('.bt-tool-body')?.innerText || '')"
        try
            TK.open_browser(s)
            TK.new_chat(s; title = "Process-wait-card")
            TK.send_message(s, "copy the renders")
            @test TK.wait_for(s, "the running wait's card", "!!$card && $card.classList.contains('bt-tool-live')"; timeout = 60)
            TK.eval_js(s, "$card.querySelector('.bt-tool-header').click(); true")
            @test TK.wait_for(s, "the job in the open card", "$body.includes('first-output') && $body.includes('echo first-')"; timeout = 20)
            @test TK.eval_js(s, "!$body.includes('loading')")
            @test TK.wait_for(s, "the job's later output", "$body.includes('second-output')"; timeout = 20)
            @test TK.eval_js(s, "$card.classList.contains('bt-tool-live')")    # the wait still runs
            @test isempty(TK.js_errors(s))
        finally
            close(s)
        end
    end
end
