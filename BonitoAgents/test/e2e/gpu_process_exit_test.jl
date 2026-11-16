# The browser's GPU process exits (2026-11-16). Without a GPU, as on CI, it
# does under load ("GPU process exited unexpectedly: exit_code=512"), and
# every live WebGL context goes with it. Chromium reports each such loss in the
# console, and the console check took that report for the page's warning:
# e2e:composer_wobble failed on CI while a 3D viewer from an earlier item was
# still mounted. The loss is the browser's; what the page owes is recovering
# from it. Here a chat shows the 3D viewer, the GPU process is crashed the way
# Chromium offers for it, and the viewer must come back and the console stay
# clean.
#
# Its own server and browser: crashing the shared browser's GPU process would
# take every other item's contexts with it.
@testitem "e2e:gpu_process_exit" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    obj = joinpath(mktempdir(), "square.obj")
    write(obj, "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
    s = TK.dev_server(agent = _ -> [
        TK.tool(; kind = "other", tool_name = "bt_show", title = "square.obj",
                  content = [TK.text_block("shown: $(obj) (model/obj, $(filesize(obj)))")], id = "obj1"),
        TK.end_turn()])
    STATUS = "(document.querySelector('.bt-tool-body[data-tool-id=\"obj1\"] .bt-mesh-status')?.textContent || '')"
    try
        TK.open_browser(s)
        TK.new_chat(s)
        TK.send_message(s, "show the mesh")
        @test TK.wait_for(s, "the 3D viewer", "$STATUS.includes('2 triangles')"; timeout = 60) == true
        @test isempty(TK.check_console!())

        # Chromium's own way to crash the GPU process, from a window of the same browser.
        TK.ECT.run(s.browser[].app, """(() => {
            const w = new electron.BrowserWindow({show: false});
            w.loadURL('chrome://gpucrash');
            setTimeout(() => w.destroy(), 3000);   // the test's window stays the browser's last
            return true; })()""")
        @test TK.wait_for(s, "the viewer saw its context go", "$STATUS.includes('context lost')"; timeout = 30) == true
        @test TK.wait_for(s, "and came back on its own", "$STATUS.includes('2 triangles')"; timeout = 60) == true
        # The browser's report of the loss is logged, not counted against the page.
        @test isempty(TK.check_console!())
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
