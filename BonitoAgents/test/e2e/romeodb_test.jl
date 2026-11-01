# Exercises the shipped default: no separate environment or MCP registration.
# Seed only the code-index fixture, then use real chats and real MCP processes.
@testitem "e2e:romeodb" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    import JSON, RomeoDB
    mktempdir() do dir
        withenv("BONITOAGENTS_MCP_CONFIG" => nothing) do
            s = TK.dev_server(agent = prompt -> [
                TK.mcp_call("bt_julia_list_sessions"; real_process = true, id = "worker-sessions"),
                TK.mcp_call("find_existing"; real_process = true, server = "btromeodb", id = occursin("resume", prompt) ? "romeodb-body-resumed" : "romeodb-body",
                    code = "function coordinate_grid(xs, ys)\n nx, ny = length(xs), length(ys)\n x = reshape(xs, 1, nx)\n y = reshape(ys, ny, 1)\n return repeat(x, ny, 1), repeat(y, 1, nx)\nend",
                    purpose = "coordinate matrices from coordinate vectors"),
                TK.mcp_call("search_packages"; real_process = true, server = "btromeodb", id = "romeodb-packages",
                    query = "coordinate matrices"),
                TK.end_turn()])
            try
                idx = RomeoDB.Index(joinpath(s.h.worker_config, "romeodb"))
                try
                    RomeoDB.addlocal!(idx, normpath(joinpath(@__DIR__, "..", "fixtures", "RomeoDBFixture")))
                finally
                    RomeoDB.DBInterface.close!(idx.db)
                end
                TK.open_browser(s)
                TK.new_chat(s; title = "RomeoDB integration")
                TK.send_message(s, "Find existing Julia coordinate grid functionality")
                function open_tool(id)
                    selector = ".bt-tool-msg[data-msg-id*=\"$id\"] .bt-tool-header"
                    TK.wait_for(s, "tool card $id", "!!document.querySelector($(JSON.json(selector)))";
                        timeout = 90, describe = "document.body.innerText")
                    TK.click(s, selector)
                end
                open_tool("romeodb-body")
                open_tool("romeodb-packages")
                open_tool("worker-sessions")
                TK.wait_for(s, "RomeoDB body lookup and package search", """(() => {
                    const t = document.body.innerText;
                    return t.includes('Possible implementations') && t.includes('Relevant packages') &&
                           t.includes('RomeoDBFixture') && t.includes('coordinate_grid');
                })()"""; timeout = 90, describe = "document.body.innerText")
                @test !occursin("MCP launch/call failed", TK.eval_js(s, "document.body.innerText"))
                @test occursin("no active sessions", TK.eval_js(s, "document.body.innerText"))
                TK.screenshot(s, joinpath(dir, "romeodb.png"))
                # Restarting through the UI resumes the session;
                # the mock must receive and use the worker config again.
                TK.click(s, ".bt-header-menu .bw-menu-trigger")
                TK.eval_js(s, """(() => {
                    const b = [...document.querySelectorAll('.bt-header-menu .bw-menu-item')]
                        .find(e => e.textContent.trim().startsWith('Restart session'));
                    if (!b) throw new Error('Restart session not found');
                    b.click(); return true;
                })()""")
                TK.wait_for(s, "session restarted", "!document.querySelector('.bt-header-restart-busy') && !!document.querySelector('.bt-text-input')"; timeout = 90)
                TK.send_message(s, "Check again after resume")
                open_tool("romeodb-body-resumed")
                @test TK.wait_for(s, "RomeoDB lookup after resume", """(() => {
                    const e = document.querySelector('.bt-tool-body[data-tool-id="romeodb-body-resumed"]');
                    return !!e && e.innerText.includes('RomeoDBFixture') && e.innerText.includes('Possible implementations');
                })()"""; timeout = 90, describe = "document.body.innerText")
                @test isempty(TK.js_errors(s))
            finally
                close(s)
            end
        end
    end
end
