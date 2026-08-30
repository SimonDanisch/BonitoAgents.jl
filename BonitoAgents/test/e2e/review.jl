# The change-review tab, end to end: a real git repo on the worker, the real
# `git diff` RPC, the real rendered diff, and — the part that actually matters —
# the two ways a comment leaves the tab.
#
#   ASK      — submitting sends the question to the CHAT immediately. Asserted by
#              having the mock agent echo whatever prompt it received: if the
#              file, line and code aren't in the echoed message, the agent never
#              got the context and the feature is decoration.
#   FEEDBACK — comments collect in the tray and go as ONE numbered instruction
#              when you press Send. Asserted the same way, plus that the tray
#              empties only after the send succeeded.
#
# Also covers what the diff must SHOW: a modified file, a file the agent created
# (untracked — invisible to `git diff` alone, and the most important thing to
# review), both sides' line numbers, and a re-read after the tree changes.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const REPO = mktempdir()

function init_repo!()
    run(pipeline(`git -C $REPO init -q`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $REPO config user.email t@example.com`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $REPO config user.name TestUser`; stdout = devnull, stderr = devnull))
    write(joinpath(REPO, "calc.jl"), "function add(a, b)\n    return a + b\nend\n")
    run(pipeline(`git -C $REPO add -A`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $REPO commit -qm initial`; stdout = devnull, stderr = devnull))
    # The change under review: one edited line, plus a brand-new file.
    write(joinpath(REPO, "calc.jl"), "function add(a, b)\n    return a * b\nend\n")
    write(joinpath(REPO, "helper.jl"), "helper() = nothing\n")
    return nothing
end

# The mock agent echoes the prompt it was given, so the rendered agent message IS
# proof of what reached the model.
agent_script(prompt) = [TK.text("RECEIVED<<" * prompt * ">>"), TK.end_turn()]

const REVIEW = ".bw-ws-panel[data-panel-id^=\"review:\"] .bt-review"
# The agent bubbles' text, joined — what the model was told, as rendered.
# `textContent`, NOT `innerText`: once the review tab is active the chat panel is
# the workspace's INACTIVE tab and therefore not laid out, and `innerText` of an
# unrendered element is the empty string.
const AGENT_TEXT = "[...document.querySelectorAll('.bt-agent-msg')].map(e => e.textContent).join('\\n')"

# Click the `+` on the diff row for `file` at `line`, type `text`, submit.
# `shift = true` extends from the previously clicked `+` — the block-comment path.
comment_on(file, line, text; shift = false) = """(() => {
    const rows = [...document.querySelectorAll('$(REVIEW) .bt-rv-line')];
    const row = rows.find(r => r.dataset.file === $(TK.json(file)) && r.dataset.line === $(TK.json(string(line))));
    if (!row) return 'no-row';
    row.querySelector('.bt-rv-plus').dispatchEvent(
        new MouseEvent('click', { bubbles: true, shiftKey: $(shift ? "true" : "false") }));
    const form = document.querySelector('$(REVIEW) .bt-rv-form');
    if (!form) return 'no-form';
    form.querySelector('textarea').value = $(TK.json(text));
    form.querySelector('button.bt-btn').click();
    return true;
})()"""

function run_suite(server)
    server.agent_fn[] = agent_script
    init_repo!()

    @testset "BonitoAgents change review (UI-only)" begin
        TK.new_chat(server; cwd = REPO, title = "Review")
        # A first turn, so the ACP session is live — Ask/Send both refuse without
        # one, and refusing is the correct behaviour we don't want to test around.
        TK.send_message(server, "hello")
        @test TK.wait_for(server, "chat bound",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 1";
            timeout = 90) == true

        @testset "the Review button opens a diff of the project" begin
            TK.eval_js(server, "document.querySelector('.bt-header-review').click(); true")
            @test TK.wait_for(server, "review tab mounted", "!!document.querySelector('$(REVIEW)')";
                timeout = 40) == true
            @test TK.wait_for(server, "both changed files listed",
                """(() => {
                    const paths = [...document.querySelectorAll('$(REVIEW) .bt-rv-file-path')]
                        .map(e => e.textContent);
                    return paths.includes('calc.jl') && paths.includes('helper.jl');
                })()"""; timeout = 60) == true
            # The NEW file must be there and marked as added — `git diff` alone
            # doesn't report untracked files, so this is the untracked-synthesis
            # path working.
            @test TK.eval_js(server, """(() => {
                const secs = [...document.querySelectorAll('$(REVIEW) .bt-rv-file')];
                const s = secs.find(x => x.querySelector('.bt-rv-file-path').textContent === 'helper.jl');
                return !!s && s.querySelector('.bt-rv-file-status').dataset.status === 'added';
            })()""") === true
            # Both sides' line numbers are rendered; the edited line shows as a
            # -/+ pair on line 2.
            @test TK.eval_js(server, """(() => {
                const rows = [...document.querySelectorAll('$(REVIEW) .bt-rv-line')];
                const add = rows.find(r => r.dataset.file === 'calc.jl'
                    && r.classList.contains('bt-rv-add'));
                return !!add && add.dataset.line === '2'
                    && add.querySelector('.bt-rv-code').textContent.includes('a * b');
            })()""") === true
        end

        @testset "the comment affordance is visible without hovering" begin
            # It used to be `display: none` until row hover, so nothing on screen
            # said the diff was commentable — you had to already know, or brush a
            # line by accident. Faint-but-present is the compromise: still quiet
            # enough for a thousand-line diff, but discoverable.
            @test TK.eval_js(server, """(() => {
                const p = document.querySelector('$(REVIEW) .bt-rv-line .bt-rv-plus');
                if (!p) return false;
                const cs = getComputedStyle(p);
                return cs.display !== 'none'
                    && parseFloat(cs.opacity) > 0.1
                    && p.getBoundingClientRect().width > 0;
            })()""") === true
        end

        @testset "Ask sends the question to the chat immediately" begin
            TK.eval_js(server, """(() => {
                document.querySelector('$(REVIEW) [data-rv-mode="ask"]').click(); return true; })()""")
            @test TK.eval_js(server, comment_on("calc.jl", 2, "why is this multiplication?")) === true
            @test TK.wait_for(server, "the agent received the question with its code context",
                """(() => {
                    const t = $(AGENT_TEXT);
                    return t.includes('why is this multiplication?')
                        && t.includes('calc.jl:2')
                        && t.includes('a * b');
                })()"""; timeout = 90) == true
            # Ask mode never fills the tray — that's the whole distinction.
            @test TK.eval_js(server,
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length") == 0
        end

        @testset "Feedback batches, then sends as one instruction" begin
            # With nothing queued, Send is not dressed as the primary action: the
            # only thing pressing it can do is answer "no comments to send", and
            # in Ask mode it never applies at all.
            @test TK.eval_js(server,
                "document.querySelector('$(REVIEW) .bt-rv-send').dataset.empty === '1'") === true

            TK.eval_js(server, """(() => {
                document.querySelector('$(REVIEW) [data-rv-mode="feedback"]').click(); return true; })()""")
            @test TK.eval_js(server, comment_on("calc.jl", 2, "should be a + b")) === true
            @test TK.wait_for(server, "first comment lands in the tray",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 1"; timeout = 30) == true
            @test TK.eval_js(server, comment_on("helper.jl", 1, "give this a real name")) === true
            @test TK.wait_for(server, "second comment lands in the tray",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 2"; timeout = 30) == true
            # Nothing has been sent yet — batching is the point.
            @test TK.eval_js(server, "!$(AGENT_TEXT).includes('should be a + b')") === true
            # The button counts what it will send — and only NOW becomes primary.
            @test TK.eval_js(server, """(() => {
                const b = document.querySelector('$(REVIEW) .bt-rv-send');
                return b.textContent.includes('2 comments') && b.dataset.empty === '0';
            })()""") === true

            TK.eval_js(server, "document.querySelector('$(REVIEW) .bt-rv-send').click(); true")
            # The chat renders the message as markdown, so by the time it is on
            # screen the backticks around a path have become <code> — assert the
            # RENDERED text, not the source.
            @test TK.wait_for(server, "both comments arrive in ONE numbered message",
                """(() => {
                    const t = $(AGENT_TEXT);
                    return t.includes('should be a + b') && t.includes('give this a real name')
                        && t.includes('1. calc.jl:2') && t.includes('2. helper.jl:1');
                })()"""; timeout = 90) == true
            # …and only then does the tray empty — and Send steps back down with
            # it. (Both directions matter: a reactive ATTRIBUTE would have gone
            # primary once and stayed there, counting correctly the whole time.)
            @test TK.wait_for(server, "tray cleared after a successful send",
                """(() => {
                    const b = document.querySelector('$(REVIEW) .bt-rv-send');
                    return document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 0
                        && b.dataset.empty === '1' && b.textContent.trim() === 'Send';
                })()"""; timeout = 30) == true

            # The snippet's rows must be joined by REAL newlines. The js-string
            # that builds the snippet keeps backslashes verbatim, so a `'\\n'`
            # join reached the browser as an escaped backslash and every row of
            # the quoted code arrived glued together by literal "\n" characters.
            @test TK.eval_js(server, """(() => {
                const bs = String.fromCharCode(92);
                return !$(AGENT_TEXT).includes(bs + 'n ');
            })()""") === true
        end

        @testset "shift-click covers a BLOCK, and the range reaches the agent" begin
            # Most review notes are about a region ("this loop"), not one line.
            # Anchor on line 1, shift-click line 3: the comment must name the
            # range and quote every line in it.
            #
            # The anchor has to be set on THIS file first — the previous testset
            # left it on helper.jl, and a range may not span hunks (its line
            # numbers wouldn't be contiguous), which is itself worth exercising.
            @test TK.eval_js(server, comment_on("calc.jl", 1, "anchor")) === true
            @test TK.wait_for(server, "anchor comment queued",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 1"; timeout = 30) == true
            TK.eval_js(server, "document.querySelector('$(REVIEW) .bt-rv-chip-drop').click(); true")
            @test TK.wait_for(server, "tray empty again",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 0"; timeout = 30) == true
            @test TK.eval_js(server, comment_on("calc.jl", 3, "this whole function is wrong";
                                                shift = true)) === true
            @test TK.wait_for(server, "block comment queued as one chip",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 1"; timeout = 30) == true
            # The chip names the range, not a single line.
            @test TK.eval_js(server,
                "document.querySelector('$(REVIEW) .bt-rv-chip-loc').textContent") == "calc.jl:1-3"

            TK.eval_js(server, "document.querySelector('$(REVIEW) .bt-rv-send').click(); true")
            @test TK.wait_for(server, "the agent gets the range and every line in it",
                """(() => {
                    const t = $(AGENT_TEXT);
                    return t.includes('this whole function is wrong')
                        && t.includes('calc.jl:1-3')
                        && t.includes('function add(a, b)') && t.includes('a * b') && t.includes('end');
                })()"""; timeout = 90) == true
        end

        @testset "dropping a pending comment removes it" begin
            @test TK.eval_js(server, comment_on("calc.jl", 2, "temporary note")) === true
            @test TK.wait_for(server, "comment queued",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 1"; timeout = 30) == true
            TK.eval_js(server, "document.querySelector('$(REVIEW) .bt-rv-chip-drop').click(); true")
            @test TK.wait_for(server, "comment dropped",
                "document.querySelectorAll('$(REVIEW) .bt-rv-chip').length === 0"; timeout = 30) == true
        end

        @testset "opening a file from the diff" begin
            # Reading a diff and wanting the whole file is the obvious next move,
            # so the file header opens it — in a real file tab, through the same
            # guarded path a tree click uses.
            TK.eval_js(server, """(() => {
                const secs = [...document.querySelectorAll('$(REVIEW) .bt-rv-file')];
                const s = secs.find(x => x.querySelector('.bt-rv-file-path').textContent === 'calc.jl');
                s.querySelector('.bt-rv-open').click();
                return true; })()""")
            @test TK.wait_for(server, "calc.jl opens as a file tab with its content",
                """(() => {
                    const p = [...document.querySelectorAll('.bw-ws-panel .bt-file-view')]
                        .find(v => (v.querySelector('.bt-file-editor-path')?.textContent || '')
                                   .endsWith('/calc.jl'));
                    const ed = p?.querySelector('.monaco-editor-div')?.__btEditor;
                    return !!ed && ed.getValue().includes('a * b');
                })()"""; timeout = 60) == true
        end

        @testset "reload re-reads the working tree" begin
            write(joinpath(REPO, "fresh.txt"), "appeared after the first read\n")
            TK.eval_js(server,
                "document.querySelector('$(REVIEW) [data-rv-action=\"reload\"]').click(); true")
            @test TK.wait_for(server, "the new file shows up",
                """[...document.querySelectorAll('$(REVIEW) .bt-rv-file-path')]
                     .some(e => e.textContent === 'fresh.txt')"""; timeout = 60) == true
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
