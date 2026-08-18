# The file VIEWER, end to end through the browser: clicking a file opens a
# workspace tab that renders it as whatever it is — image, markdown, table,
# geometry, opaque bytes — not "a text editor or a refusal".
#
# Every assertion is on the rendered DOM of a real dev_server + electron window,
# driven the way a user drives it (a path-link click through the chat's comm).
# What each case is really guarding:
#
#   • png      — opens at all (it used to toast "not a text file"), renders an
#                <img>, and has NO editor/Save.
#   • md       — opens on the RENDERED view with a Preview/Source toggle, and
#                Source really is an editable Monaco holding the file's text.
#   • csv      — becomes a sortable table with the right shape, not a wall of
#                commas.
#   • obj      — reaches the WebGL viewer and reports the geometry it parsed
#                (server-side parse → BTMESH1 blob → canvas).
#   • bin      — a hex dump, and no attempt to feed Monaco binary.
#   • header   — every kind shows the WORKER path, not the server mirror path,
#                and shows it in reading order (the `direction: rtl` bidi trap).
#   • save     — editing the source and hitting Save writes the WORKER file.
#   • mp4/png  — media is FITTED to its stage; a 1600px-tall file used to run off
#                the bottom of the tab, taking a video's controls with it.
#   • pdf      — the frame gets its src from inside the document, without which
#                Chromium's PDF plugin renders nothing at all.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const VIEW_CWD = mktempdir()

# A real, valid 1×1 PNG (correct CRCs and a well-formed IDAT). It has to actually
# DECODE: the header's dimension readout comes from `img.naturalWidth`, which
# stays 0 for a malformed file — so a hand-assembled "close enough" PNG would
# turn this into a test of nothing.
using Base64
const PNG_BYTES = base64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

# A real 4×1600 PNG and a real 480×1600 H.264 mp4. Both are TALLER than any
# panel this suite opens, which is the whole point of them: they are what makes
# the stages' fit rule testable. Embedded rather than generated so the suite
# needs no ffmpeg/imagemagick at run time.
const TALL_PNG_BYTES = base64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAZAAQMAAABkJnF9AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURTNmzP///w3eOY0AAAABYktHRAH/Ai3eAAAAGklEQVRIx+3BMQEAAADCoPVPbQsvoAAAAD4GDIAAAes+exkAAAAASUVORK5CYII=")
const TALL_MP4_BYTES = base64decode(
    "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")

write(joinpath(VIEW_CWD, "pixel.png"), PNG_BYTES)
write(joinpath(VIEW_CWD, "tall.png"), TALL_PNG_BYTES)
write(joinpath(VIEW_CWD, "tall.mp4"), TALL_MP4_BYTES)
# One triangle, so the viewer's status line has to say "1 triangle", not "1 triangles".
write(joinpath(VIEW_CWD, "one.obj"), "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
# The PDF only has to be well-formed enough for Chromium to instantiate its
# viewer; what this suite can check is the plumbing, not the painted page.
write(joinpath(VIEW_CWD, "doc.pdf"),
      "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n" *
      "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" *
      "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\n" *
      "trailer<</Root 1 0 R>>\n")
write(joinpath(VIEW_CWD, "notes.md"), "# Heading One\n\nSome *emphasised* prose.\n")
write(joinpath(VIEW_CWD, "table.csv"), "name,score\nada,42\ngrace,7\nalan,13\n")
# A unit square as two triangles — the mesh viewer must report exactly this.
write(joinpath(VIEW_CWD, "square.obj"),
      "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
write(joinpath(VIEW_CWD, "blob.bin"), UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
write(joinpath(VIEW_CWD, "plain.jl"), "const X = 1\n")

open_file(path) = """(() => { document.querySelector('.bt-messages').__bt_chat.comm.notify(
    {type:'edit_file', path: $(TK.json(path))}); return true; })()"""
# A file tab is identified by its ABSOLUTE worker path, whichever way it was
# opened — see `open_project_file!`. Resolve here so these selectors keep
# matching whether the test opens by a relative or an absolute path.
panel_sel(path) = ".bw-ws-panel[data-panel-id=\"file:$(isabspath(path) ? path : joinpath(VIEW_CWD, path))\"]"
view_sel(path)  = "$(panel_sel(path)) .bt-file-view"

function run_suite(server)
    server.agent_fn[] = _ -> [TK.text("ready"), TK.end_turn()]

    @testset "BonitoAgents file viewer (UI-only)" begin
        TK.new_chat(server; cwd = VIEW_CWD, title = "Viewer")

        @testset "an image opens as an image" begin
            TK.eval_js(server, open_file("pixel.png"))
            @test TK.wait_for(server, "png panel exists",
                "!!document.querySelector('$(view_sel("pixel.png"))')"; timeout = 40) == true
            @test TK.wait_for(server, "renders an <img> on the image stage",
                """(() => {
                    const v = document.querySelector('$(view_sel("pixel.png"))');
                    return v.dataset.kind === 'image'
                        && !!v.querySelector('.bt-fv-image-stage img.bt-media');
                })()"""; timeout = 30) == true
            # No editor, no Save: there is nothing to edit in a PNG, and offering
            # it would be a way to corrupt the file.
            @test TK.eval_js(server, """(() => {
                const v = document.querySelector('$(view_sel("pixel.png"))');
                return v.querySelector('.monaco-editor-div') === null
                    && v.querySelector('.bt-file-editor-save') === null
                    && v.querySelector('.bt-fv-segmented') === null;
            })()""") === true
            # The image really loaded (not a broken src): the header picks up its
            # intrinsic size from the decoded bitmap.
            @test TK.wait_for(server, "header reports the pixel dimensions",
                "(document.querySelector('$(view_sel("pixel.png")) .bt-fv-dims')?.textContent || '').includes('1 × 1')";
                timeout = 30) == true
        end

        @testset "markdown opens rendered, with an editable source behind a toggle" begin
            TK.eval_js(server, open_file("notes.md"))
            @test TK.wait_for(server, "markdown renders as HTML, not source",
                """(() => {
                    const v = document.querySelector('$(view_sel("notes.md"))');
                    if (!v) return false;
                    const h1 = v.querySelector('.bt-fv-markdown h1');
                    return v.dataset.kind === 'markdown' && v.dataset.view === 'preview'
                        && !!h1 && h1.textContent.includes('Heading One');
                })()"""; timeout = 40) == true

            # Source toggle → an editable Monaco holding the file's real text.
            TK.eval_js(server, """(() => {
                document.querySelector('$(view_sel("notes.md")) [data-fv-view="source"]').click();
                return true; })()""")
            @test TK.wait_for(server, "source view shows the markdown text",
                """(() => {
                    const v = document.querySelector('$(view_sel("notes.md"))');
                    const ed = v?.querySelector('.monaco-editor-div')?.__btEditor;
                    return v.dataset.view === 'source' && !!ed
                        && ed.getValue().includes('Heading One');
                })()"""; timeout = 30) == true
        end

        @testset "saving the source writes the file ON THE WORKER" begin
            # This is the point of the whole editor: the agent reads the worker's
            # copy, so a save that only touched the server mirror never happened.
            TK.eval_js(server, """(() => {
                const v = document.querySelector('$(view_sel("notes.md"))');
                v.querySelector('.monaco-editor-div').__btEditor.setValue('# Edited By The Test\\n');
                v.querySelector('.bt-file-editor-save').click();
                return true; })()""")
            @test TK.wait_for(server, "status line confirms the worker save",
                "(document.querySelector('$(view_sel("notes.md")) .bt-file-editor-status')?.textContent || '').includes('saved to the worker')";
                timeout = 40) == true
            # The dev worker is this machine, so the file on disk IS the worker's.
            probe = joinpath(VIEW_CWD, "notes.md")
            saved = false
            for _ in 1:60
                occursin("Edited By The Test", read(probe, String)) && (saved = true; break)
                sleep(0.5)
            end
            @test saved
            # …and the rendered half followed the save rather than showing the
            # pre-edit preview.
            TK.eval_js(server, """(() => {
                document.querySelector('$(view_sel("notes.md")) [data-fv-view="preview"]').click();
                return true; })()""")
            @test TK.wait_for(server, "preview shows the saved text",
                "(document.querySelector('$(view_sel("notes.md")) .bt-fv-markdown')?.textContent || '').includes('Edited By The Test')";
                timeout = 30) == true
        end

        @testset "a csv opens as a sortable table" begin
            TK.eval_js(server, open_file("table.csv"))
            @test TK.wait_for(server, "csv renders as a table with the right shape",
                """(() => {
                    const v = document.querySelector('$(view_sel("table.csv"))');
                    const t = v?.querySelector('table.bt-fv-table');
                    if (!t) return false;
                    // header row + a row-number column
                    return t.tHead.rows[0].cells.length === 3
                        && t.tBodies[0].rows.length === 3
                        && t.tBodies[0].rows[0].cells[1].textContent === 'ada';
                })()"""; timeout = 40) == true
            # Sorting is local (no round-trip): clicking the numeric column header
            # reorders the rows in place.
            TK.eval_js(server, """(() => {
                const t = document.querySelector('$(view_sel("table.csv")) table.bt-fv-table');
                t.tHead.rows[0].cells[2].click(); return true; })()""")
            @test TK.wait_for(server, "clicking a numeric header sorts ascending",
                """(() => {
                    const b = document.querySelector('$(view_sel("table.csv")) table.bt-fv-table').tBodies[0];
                    return [...b.rows].map(r => r.cells[2].textContent).join(',') === '7,13,42';
                })()"""; timeout = 15) == true
        end

        @testset "an .obj opens in the 3D viewer and reports its geometry" begin
            TK.eval_js(server, open_file("square.obj"))
            @test TK.wait_for(server, "mesh canvas mounted",
                "!!document.querySelector('$(view_sel("square.obj")) canvas.bt-mesh-canvas')";
                timeout = 40) == true
            # The status line is written by the JS AFTER it fetched and decoded the
            # BTMESH1 blob — so this asserts the whole server-parse → blob →
            # browser-decode path, with the exact triangle count of the fixture.
            @test TK.wait_for(server, "viewer reports 2 triangles / 4 vertices",
                """(() => {
                    const s = document.querySelector('$(view_sel("square.obj")) .bt-mesh-status');
                    const t = s?.textContent || '';
                    return t.includes('2 triangles') && t.includes('4 vertices');
                })()"""; timeout = 40) == true
        end

        @testset "opaque bytes get a hex dump, never Monaco" begin
            TK.eval_js(server, open_file("blob.bin"))
            @test TK.wait_for(server, "hex dump with the file's magic bytes",
                """(() => {
                    const v = document.querySelector('$(view_sel("blob.bin"))');
                    const pre = v?.querySelector('pre.bt-fv-hex');
                    return v.dataset.kind === 'binary' && !!pre
                        && pre.textContent.includes('DE AD BE EF')
                        && v.querySelector('.monaco-editor-div') === null;
                })()"""; timeout = 40) == true
        end

        @testset "every panel names the WORKER path" begin
            TK.eval_js(server, open_file("plain.jl"))
            @test TK.wait_for(server, "source file opens",
                "!!document.querySelector('$(view_sel("plain.jl")) .monaco-editor-div')";
                timeout = 40) == true
            # The header must show where the file really lives — the path the user
            # typed and the agent reads — not the server's mirror under state/.
            @test TK.eval_js(server, """(() => {
                const cwd = $(TK.json(VIEW_CWD));
                const paths = ['pixel.png','notes.md','table.csv','square.obj','blob.bin','plain.jl'];
                return paths.every(p => {
                    // Tabs are keyed by the ABSOLUTE worker path — see `open_project_file!`.
                    const el = document.querySelector(
                        '.bw-ws-panel[data-panel-id="file:' + cwd + '/' + p + '"] .bt-file-editor-path');
                    return !!el && el.textContent === cwd + '/' + p;
                });
            })()""") === true
        end

        @testset "a video opens on a stage, fitted and centred" begin
            # It used to get no stage at all: the element sat at its intrinsic
            # size in the top-left of an empty tab, and a clip TALLER than the
            # panel pushed its own controls off the bottom — `media_element`
            # constrains width only. The fixture is 480×1600 for exactly that.
            TK.eval_js(server, open_file("tall.mp4"))
            @test TK.wait_for(server, "video mounted on the stage and decoded",
                """(() => {
                    const v = document.querySelector('$(view_sel("tall.mp4"))');
                    const vid = v?.querySelector('.bt-fv-video-stage video');
                    return v?.dataset.kind === 'video' && !!vid && vid.videoHeight === 1600;
                })()"""; timeout = 40) == true
            @test TK.wait_for(server, "the 1600px-tall clip fits inside its stage",
                """(() => {
                    const v = document.querySelector('$(view_sel("tall.mp4"))');
                    const st = v.querySelector('.bt-fv-video-stage');
                    const r = v.querySelector('video').getBoundingClientRect();
                    const sr = st.getBoundingClientRect();
                    return sr.height > 100 && r.height <= sr.height + 1
                        && r.bottom <= sr.bottom + 1
                        && Math.abs((r.left + r.right) / 2 - (sr.left + sr.right) / 2) < 2;
                })()"""; timeout = 30) == true
        end

        @testset "a tall image fits its stage too" begin
            # Same rule, same bug: `max-height: 100%` on the media alone resolves
            # against a content-height wrapper and does nothing.
            TK.eval_js(server, open_file("tall.png"))
            @test TK.wait_for(server, "the 1600px-tall image fits inside its stage",
                """(() => {
                    const v = document.querySelector('$(view_sel("tall.png"))');
                    const st = v?.querySelector('.bt-fv-image-stage');
                    const img = v?.querySelector('img.bt-media');
                    if (!st || !img || img.naturalHeight !== 1600) return false;
                    const r = img.getBoundingClientRect(), sr = st.getBoundingClientRect();
                    return sr.height > 100 && r.height <= sr.height + 1;
                })()"""; timeout = 40) == true
        end

        @testset "a pdf frame is pointed at its file from inside the document" begin
            # An <iframe src=…> that arrives already-sourced through Bonito's node
            # insertion leaves Chromium's PDF plugin without a live view: the tab
            # shows the viewer's dark backdrop and nothing else, FOREVER. The DOM
            # of a dead frame and a live one are identical (both carry an <embed
            # src="about:blank">), which is why only the plumbing is assertable
            # here — see "Headless limitations" in COVERAGE.md.
            TK.eval_js(server, open_file("doc.pdf"))
            @test TK.wait_for(server, "the driver assigned the frame's src in-document",
                """(() => {
                    const v = document.querySelector('$(view_sel("doc.pdf"))');
                    const f = v?.querySelector('iframe.bt-fv-frame');
                    if (!f) return false;
                    // The url carries a ?v=<mtime> cache-buster, so match inside it.
                    const want = f.dataset.frameSrc || '';
                    return v.dataset.kind === 'pdf' && want.includes('doc.pdf')
                        && f.dataset.fvReady === '1'
                        && f.getAttribute('src') === want;
                })()"""; timeout = 40) == true
        end

        @testset "the worker path renders in reading order" begin
            # `direction: rtl` gives the header its left-truncation, and on its own
            # it also moves the leading "/" of an absolute path to the visual END —
            # every file tab read `tmp/x/y.png/`. textContent is unaffected, so the
            # path assertions above all passed straight through it; what has to be
            # checked is the bidi treatment the browser will actually apply.
            @test TK.eval_js(server, """(() => {
                const el = document.querySelector('$(view_sel("plain.jl")) .bt-file-editor-path');
                const run = el?.querySelector('.bt-path-ltr');
                if (!run) return false;
                const outer = getComputedStyle(el), inner = getComputedStyle(run);
                return outer.direction === 'rtl'          // still truncates from the left
                    && inner.direction === 'ltr'          // …without reordering the path
                    && inner.unicodeBidi === 'isolate'
                    && el.textContent === $(TK.json(VIEW_CWD)) + '/plain.jl';
            })()""") === true
        end

        @testset "the geometry viewer counts in singular" begin
            TK.eval_js(server, open_file("one.obj"))
            @test TK.wait_for(server, "a one-triangle file reads '1 triangle'",
                """(() => {
                    const s = document.querySelector('$(view_sel("one.obj")) .bt-mesh-status');
                    const t = s?.textContent || '';
                    return t.includes('1 triangle ') && !t.includes('1 triangles')
                        && t.includes('3 vertices');
                })()"""; timeout = 40) == true
        end

        @testset "the same file opened both ways is ONE tab" begin
            # The two routes in disagree about the path: the file TREE passes an
            # absolute path, a tool pill passes whatever the agent printed —
            # usually relative to the chat's cwd. Keyed on the raw string those
            # were two tabs for one file: edit in one, save, and the other holds
            # the old text. Tab disambiguation then made the pair look like two
            # genuinely different files (`viewer/notes.md` next to `notes.md`).
            TK.eval_js(server, open_file("plain.jl"))
            @test TK.wait_for(server, "opened by relative path",
                "!!document.querySelector('$(panel_sel("plain.jl"))')"; timeout = 40) == true
            TK.eval_js(server, open_file(joinpath(VIEW_CWD, "plain.jl")))
            sleep(2)   # a second tab would be added by now
            @test TK.eval_js(server, """(() => {
                return [...document.querySelectorAll('.bw-ws-panel')]
                    .filter(p => (p.dataset.panelId || '').endsWith('plain.jl')).length;
            })()""") == 1
        end

        @testset "⟳ reloads a plain source file" begin
            # The reload handler used to be registered only for kinds that HAVE a
            # rendered view, so on a source file — the commonest tab there is — ⟳
            # flashed "reloaded" with nothing listening: the editor kept whatever
            # it was opened with. Change the file underneath it and press the
            # button the user presses.
            TK.eval_js(server, open_file("plain.jl"))
            @test TK.wait_for(server, "source open with its original text",
                "(document.querySelector('$(view_sel("plain.jl")) .monaco-editor-div')?.__btEditor?.getValue() || '').includes('const X = 1')";
                timeout = 40) == true
            write(joinpath(VIEW_CWD, "plain.jl"), "const X = 99  # changed underneath\n")
            TK.eval_js(server, """(() => {
                document.querySelector('$(view_sel("plain.jl")) [data-fv-action="reload"]').click();
                return true; })()""")
            @test TK.wait_for(server, "the editor picks the new text up",
                "(document.querySelector('$(view_sel("plain.jl")) .monaco-editor-div')?.__btEditor?.getValue() || '').includes('const X = 99')";
                timeout = 40) == true
        end

        @testset "an unsaved buffer is marked on its tab" begin
            # Closing a tab discards the buffer without asking, so this marker is
            # the only warning that unsaved work is about to go. It also has to
            # come BACK OFF on save: the save moves the baseline without changing
            # the content, so no editor change event fires and a naive
            # implementation leaves the dot stuck on forever.
            TK.eval_js(server, open_file("notes.md"))
            @test TK.wait_for(server, "editor ready", """(() => {
                const v = document.querySelector('$(view_sel("notes.md"))');
                v?.querySelector('[data-fv-view="source"]')?.click();
                return !!v?.querySelector('.monaco-editor-div')?.__btEditor;
            })()"""; timeout = 40) == true
            label_of(name) = """(() => ([...document.querySelectorAll('.bw-tab-label')]
                .map(t => t.textContent).find(t => t.includes($(TK.json(name)))) || ''))()"""

            TK.eval_js(server, """(() => {
                const ed = document.querySelector('$(view_sel("notes.md")) .monaco-editor-div').__btEditor;
                ed.setValue(ed.getValue() + "\\nunsaved edit\\n");
                return true; })()""")
            @test TK.wait_for(server, "tab shows the unsaved marker",
                "$(label_of("notes.md")).startsWith('●')"; timeout = 30) == true

            TK.eval_js(server, """(() => {
                document.querySelector('$(view_sel("notes.md")) .bt-file-editor-save').click();
                return true; })()""")
            @test TK.wait_for(server, "marker clears once the save landed",
                """(() => {
                    const l = $(label_of("notes.md"));
                    const s = document.querySelector('$(view_sel("notes.md")) .bt-file-editor-status');
                    return !l.startsWith('●') && (s?.textContent || '').includes('saved to the worker');
                })()"""; timeout = 40) == true
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = _ -> [TK.text("ready"), TK.end_turn()])
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
