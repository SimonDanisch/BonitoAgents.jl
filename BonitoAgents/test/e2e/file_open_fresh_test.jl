# Stale file opens (#34): the agent edits files on the WORKER; the editor must
# show what's there NOW, not the first-ever-fetched mirror copy. Each testset
# was verified RED against the pre-fix code (fetch_show_file returned the
# cached mirror file unconditionally, and activating an already-open panel
# never re-read anything).
@testitem "e2e:file_open_fresh" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    s.agent_fn[] = prompt -> [TK.text("echo: $(prompt)"), TK.end_turn()]
    pid = TK.new_chat(s; title = "FreshFiles")
    TK.send_message(s, "hello")
    @test TK.wait_for(s, "chat bound + first reply",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 1";
        timeout = 90) == true

    # The worker-side project directory (dev worker runs on this machine).
    wdir = joinpath(s.h.worker_root, "FreshFiles")
    @test isdir(wdir)
    probe = joinpath(wdir, "stale_probe.txt")

    open_probe!() = TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        c.__bt_chat.comm.notify({type: 'edit_file', id: '', path: 'stale_probe.txt'});
        return true;
    })()""")

    # Monaco buffer content of the probe's editor panel (null until mounted).
    EDITOR_VAL = """(() => {
        const fe = [...document.querySelectorAll('.bt-file-editor')]
            .find(e => (e.querySelector('.bt-file-editor-path')?.textContent ?? '')
                       .includes('stale_probe.txt'));
        const ed = fe?.querySelector('.monaco-editor-div')?.__btEditor;
        return ed ? ed.getValue() : null;
    })()"""

    editor_shows(marker; timeout = 20) = TK.wait_for(s, "editor shows $(marker)",
        "($EDITOR_VAL ?? '').includes('$(marker)')"; timeout)

    @testset "reopening after close shows the current worker content" begin
        write(probe, "VERSION-ONE\n")
        open_probe!()
        @test editor_shows("VERSION-ONE") == true

        # Close the panel, edit the file ON THE WORKER, reopen.
        TK.eval_js(s, """(() => {
            const tab = [...document.querySelectorAll('.bw-tab')]
                .find(t => t.innerText.includes('stale_probe.txt'));
            tab?.querySelector('.bw-tab-close')?.click();
            return true;
        })()""")
        @test TK.wait_for(s, "probe panel closed",
            "![...document.querySelectorAll('.bw-tab')].some(t => t.innerText.includes('stale_probe.txt'))";
            timeout = 10) == true
        write(probe, "VERSION-TWO\n")
        open_probe!()
        @test editor_shows("VERSION-TWO") == true
    end

    @testset "activating the open panel refreshes a clean buffer" begin
        write(probe, "VERSION-THREE\n")
        open_probe!()   # panel already open — activation must re-read the worker
        @test editor_shows("VERSION-THREE") == true
    end

    @testset "unsaved edits are never clobbered by a refresh" begin
        TK.eval_js(s, """(() => {
            const fe = [...document.querySelectorAll('.bt-file-editor')]
                .find(e => (e.querySelector('.bt-file-editor-path')?.textContent ?? '')
                           .includes('stale_probe.txt'));
            fe.querySelector('.monaco-editor-div').__btEditor.setValue('MY-LOCAL-EDITS');
            return true;
        })()""")
        write(probe, "VERSION-FOUR\n")
        open_probe!()
        sleep(3)   # give a (wrong) reload every chance to clobber
        val = TK.eval_js(s, EDITOR_VAL)
        @test val isa AbstractString && occursin("MY-LOCAL-EDITS", val)
    end

    @testset "no JS errors" begin
        @test isempty(TK.js_errors(s))
    end
end
