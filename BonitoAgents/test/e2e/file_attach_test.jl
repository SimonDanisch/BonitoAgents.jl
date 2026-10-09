# Any file can be attached, not only an image: a PDF, a video, an archive. The
# agent cannot take such a file in directly, so it is uploaded (in chunks, each
# a plain HTTP request), copied to the worker next to the project, and the
# message names its path, where the agent opens it.
@testitem "e2e:file_attach" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    folder = mkpath(joinpath(mktempdir(), "FileAttach"))
    n = 3 * 512 * 1024 + 12_345                 # four chunks, the last one short
    expected = UInt8[(7i) % 256 for i in 0:(n - 1)]
    # The agent looks for the file where the worker has the project, and says
    # whether every byte made it.
    s.agent_fn[] = prompt -> begin
        m = match(r"\.bt-attachments/\S+", prompt)
        verdict = m === nothing ? "NO PATH" :
            (p = joinpath(folder, m.match); !isfile(p) ? "NOT ON WORKER" :
             read(p) == expected ? "BYTES MATCH $(basename(p))" : "BYTES DIFFER")
        [TK.text(verdict), TK.end_turn()]
    end
    pid = TK.new_chat(s; cwd = folder)
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    q(sel) = "document.querySelector($(repr(P * sel)))"
    @test TK.wait_for(s, "composer", "!!$(q(".bt-attach-input"))"; timeout = 30)

    # Picked through the real file input, as a phone or the button would.
    TK.eval_js(s, """(() => {
        const n = $(n), bytes = new Uint8Array(n);
        for (let i = 0; i < n; i++) bytes[i] = (7 * i) % 256;
        const dt = new DataTransfer();
        dt.items.add(new File([bytes], 'quarterly report v2.pdf', {type: 'application/pdf'}));
        const input = $(q(".bt-attach-input"));
        input.files = dt.files;
        input.dispatchEvent(new Event('change', {bubbles: true}));
        return true; })()""")
    chip = q(".bt-attachment-file")
    @test TK.wait_for(s, "the file uploaded", "$(chip)?.dataset.state === 'done'"; timeout = 60)
    @test TK.eval_js(s, "$(chip).querySelector('.bt-attachment-file-name').textContent") == "quarterly report v2.pdf"
    TK.set_input(s, "$(P).bt-text-input", "please read the attached report")
    TK.click(s, "$(P).bt-send-btn")
    @test TK.wait_for(s, "the agent found every byte on the worker",
        "[...document.querySelectorAll('$(P).bt-agent-msg')].some(e => e.textContent.includes('BYTES MATCH'))"; timeout = 60)
    @test TK.eval_js(s, "!$(q(".bt-attachment-file"))")      # the composer is empty again

    # The bubble: the text, and the file as a link that opens it.
    link = "[...document.querySelectorAll('$(P).bt-user-msg .bt-user-att-file')].pop()"
    @test TK.wait_for(s, "the file in the bubble", "!!$(link)"; timeout = 10)
    @test TK.eval_js(s, "$(link).textContent") == "quarterly_report_v2.pdf"
    served = TK.eval_js(s, """(async () => { const r = await fetch($(link).href);
        return [r.status, r.headers.get('content-type'), (await r.arrayBuffer()).byteLength]; })()""")
    @test served == [200, "application/pdf", n]

    # The upload route answers only requests that carry its header: a page on
    # another site cannot send one without a preflight nobody answers.
    @test TK.eval_js(s, """(async () => (await fetch('/attachment-upload/$(pid)?upload=abcdefgh1&offset=0&total=1',
        {method: 'POST', body: 'x'})).status)()""") == 403

    # Removed while it uploads: no error, nothing sent with the next message.
    TK.eval_js(s, """(() => {
        const dt = new DataTransfer();
        dt.items.add(new File([new Uint8Array(8 * 1024 * 1024)], 'big.bin', {type: 'application/octet-stream'}));
        const input = $(q(".bt-attach-input"));
        input.files = dt.files;
        input.dispatchEvent(new Event('change', {bubbles: true}));
        $(q(".bt-attachment-file .bt-attachment-remove")).click();
        return true; })()""")
    @test TK.wait_for(s, "the upload removed", "!$(q(".bt-attachment-file"))"; timeout = 10)
    @test isempty(TK.js_errors(s))
end
