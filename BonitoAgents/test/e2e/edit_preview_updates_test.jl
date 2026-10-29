@testitem "e2e:edit_preview_updates" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    s = SharedServer.server()
    cwd = mktempdir()
    old = "- The full suite runs ONCE, at the very end of a refactor."
    new = old * "\n- Verify follow-up fixes with the failing test files."
    path = joinpath(cwd, "MEMORY.md")
    ready = joinpath(cwd, "release")
    s.agent_fn[] = _ -> [
        TK.tool(kind="edit", tool_name="Edit", title="Edit MEMORY.md", id="stream-edit",
            open_status="pending", complete=false),
        TK.tool_update("stream-edit"; status="in_progress",
            raw_input=Dict("file_path"=>path, "old_string"=>old, "new_string"=>"")),
        TK.delay(60000; until_file=ready),
        TK.tool_update("stream-edit"; status="in_progress",
            raw_input=Dict("new_string"=>new)),
        TK.tool_update("stream-edit"; status="completed",
            content=[TK.text_block("The file has been updated successfully.")]),
        TK.end_turn(),
    ]
    body = "document.querySelector('.bt-tool-body[data-tool-id=\"stream-edit\"]')"
    try
        TK.new_chat(s; cwd, title="Streaming edit preview")
        TK.send_message(s, "append a test instruction")
        @test TK.wait_for(s, "partial input has rendered its preview",
            "!!$body?.querySelector('.bt-code-diff .bt-l')"; timeout=60)
        # Release the final input only once the stale, deletion-only body is
        # definitely on screen, the ordering behind the reported bug.
        write(ready, "go")
        @test TK.wait_for(s, "completed edit has the final diff",
            "$body?.querySelector('.bt-code-diff')?.dataset.ops === '=1 +1'"; timeout=15)
        @test TK.eval_js(s, "$body.querySelectorAll('.bt-l-del').length") == 0
        @test TK.eval_js(s, "$body.textContent.includes($(TK.json(old)))")
        @test TK.eval_js(s, "$body.textContent.includes('Verify follow-up fixes')")
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-edit-preview-updated.png"))
        TK.reload!(s)
        @test TK.wait_for(s, "edit card restored", "!!$body"; timeout=30)
        TK.eval_js(s, "$body.closest('.bt-tool-msg').querySelector('.bt-tool-header').click()")
        @test TK.wait_for(s, "reloaded diff agrees with the live preview",
            "$body?.querySelector('.bt-code-diff')?.dataset.ops === '=1 +1'"; timeout=30)
        @test isempty(TK.js_errors(s))
    finally
        write(ready, "go")
        s.agent_fn[] = SharedServer.default_agent
    end
end
