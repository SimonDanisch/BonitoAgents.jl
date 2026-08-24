# Reviewing a checkout that sits INSIDE the project folder.
#
# The tab used to ask git about the project folder and nothing else. That is the
# wrong shape for the way people actually lay projects out: the project folder is
# routinely a workspace holding one checkout per dependency being developed
# (`dev/Alpha`, `dev/Beta`, …) and is not a checkout itself. Asked about such a
# folder git says "not a git repository", so the tab had nothing to show and no
# way to say which repository it meant.
#
# Now the project is scanned for checkouts and the tab offers them. What this
# pins that the headless tests cannot:
#
#   * the picker is really populated from a scan of the worker's filesystem
#     (`unit:review_folder` only knows what to do with a list it is handed);
#   * a project that is not itself a checkout does NOT silently pick one — with
#     more than one candidate, guessing yields a real diff of the wrong
#     repository, which reads exactly like a real diff of the right one;
#   * choosing one actually re-runs the diff against it;
#   * and the paths survive the two frame changes. This is the part that bites:
#     git prints repository-relative, the rows show folder-relative, and
#     `data-file` has to come out PROJECT-relative because that is where the
#     agent stands and what `open_project_file!` resolves against.
#
# Its own dev_server and exactly ONE chat, for the same reason `review_scope.jl`
# has: two review panels in a window cannot be told apart by `querySelector`, and
# an inactive workspace panel still has an `offsetParent`.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The project folder — NOT a repository. Two checkouts under it, which is the
# case that has no defensible default.
const RF_PROJECT = mktempdir()
const RF_ALPHA   = joinpath(RF_PROJECT, "dev", "Alpha")
const RF_BETA    = joinpath(RF_PROJECT, "dev", "Beta")
const RF_REVIEW  = ".bw-ws-panel[data-panel-id^=\"review:\"] .bt-review"

# Distinct file names throughout: `includes("alpha.jl")` would also match
# `alpha_extra.jl`, which would quietly weaken every assertion here.
function init_repo!(dir, filename, untracked)
    mkpath(dir)
    git(args...) = run(pipeline(`git -C $dir $args`; stdout = devnull, stderr = devnull))
    git("init", "-q")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "TestUser")
    # One level down inside the checkout, so the path the row shows is a real
    # multi-segment one rather than a bare filename that would pass whatever
    # frame it happened to be in.
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", filename), "before() = 1\n")
    git("add", "-A")
    git("commit", "-qm", "initial")
    write(joinpath(dir, "src", filename), "after() = 2\n")
    write(joinpath(dir, "src", untracked), "fresh() = :new\n")
    return nothing
end

function init_workspace!()
    init_repo!(RF_ALPHA, "alpha.jl", "alpha_arrival.jl")
    init_repo!(RF_BETA,  "beta.jl",  "beta_arrival.jl")
    return nothing
end

folder_agent(prompt) = [TK.text("RECEIVED<<" * prompt * ">>"), TK.end_turn()]

# The picker's options, as the DOM has them.
const OPTIONS_JS = """[...document.querySelectorAll('$(RF_REVIEW) .bt-rv-folder option')]
    .map(o => o.textContent)"""

function run_suite(server)
    server.agent_fn[] = folder_agent
    init_workspace!()

    @testset "a checkout inside the project can be reviewed" begin
        TK.new_chat(server; cwd = RF_PROJECT, title = "Workspace")
        TK.send_message(server, "hello")
        @test TK.wait_for(server, "chat bound",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 1";
            timeout = 90) == true

        TK.eval_js(server, "document.querySelector('.bt-header-review').click(); true")
        @test TK.wait_for(server, "review tab mounted",
            "!!document.querySelector('$(RF_REVIEW)')"; timeout = 40) == true

        # ── The scan reached the UI.
        @test TK.wait_for(server, "both checkouts are offered",
            """(() => { const o = $(OPTIONS_JS);
                return o.some(t => t === 'dev/Alpha') && o.some(t => t === 'dev/Beta'); })()""";
            timeout = 60) == true
        # Labelled by their path UNDER the project. The absolute path is the same
        # prefix on every entry and the difference is the whole point of the list.
        @test TK.eval_js(server,
            """$(OPTIONS_JS).every(t => !t.includes($(repr(RF_PROJECT))))""") === true
        # The project folder is offered too, even though it isn't a checkout: it
        # is the default the tab used to hard-code, and a folder that gets
        # `git init`-ed should not need a reopen to become reviewable.
        @test TK.eval_js(server, "$(OPTIONS_JS).some(t => t === '.')") === true

        # ── Nothing is picked for you when there is no defensible pick.
        @test TK.eval_js(server,
            "document.querySelector('$(RF_REVIEW) .bt-rv-folder').value === ''") === true
        # And the tab SAYS that, rather than showing git's "not a git repository"
        # about a folder that was never going to be one.
        @test TK.wait_for(server, "the empty state asks for a folder",
            """(document.querySelector('$(RF_REVIEW) .bt-rv-empty')?.textContent || '')
                .includes('holds 2 of them')"""; timeout = 30) == true
        @test TK.eval_js(server,
            """[...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')].length === 0""") === true

        # ── Pick one. `change` and not `input`: a <select> fires both, but the
        # handler is wired to `change`, and driving the event the product listens
        # for is the point of an e2e.
        TK.eval_js(server, """(() => {
            const s = document.querySelector('$(RF_REVIEW) .bt-rv-folder');
            s.value = [...s.options].find(o => o.textContent === 'dev/Alpha').value;
            s.dispatchEvent(new Event('change', {bubbles: true}));
            return true; })()""")

        @test TK.wait_for(server, "Alpha's change is listed",
            """[...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                .some(e => e.textContent.includes('alpha.jl'))"""; timeout = 60) == true
        # The untracked file in that checkout comes along — a review that silently
        # misses what the agent CREATED misses the most important thing.
        @test TK.eval_js(server,
            """[...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                .some(e => e.textContent.includes('alpha_arrival.jl'))""") === true
        # The OTHER checkout is a different repository and must not leak in.
        @test TK.eval_js(server,
            """[...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                .every(e => !e.textContent.includes('beta.jl'))""") === true

        # ── The two frames, which is where this feature actually breaks.
        # What the row SHOWS is relative to the reviewed checkout: the header
        # names it, so repeating `dev/Alpha/` on every row is the noise the
        # prefix-stripping exists to remove.
        @test TK.eval_js(server, """(() => {
            const p = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                .find(e => e.textContent.includes('alpha.jl') &&
                          !e.textContent.includes('arrival'));
            return !!p && p.textContent === 'src/alpha.jl';
        })()""") === true
        # What the row CARRIES is relative to the PROJECT. The agent's working
        # directory is the project folder, so `src/alpha.jl` sends it to
        # `<project>/src/alpha.jl` — a file that does not exist.
        @test TK.eval_js(server, """(() => {
            const row = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-line')]
                .find(r => (r.dataset.file || '').includes('alpha.jl'));
            return !!row && row.dataset.file === 'dev/Alpha/src/alpha.jl';
        })()""") === true
        # Same frame for the ⤢ target, which `open_project_file!` resolves
        # against the project.
        @test TK.eval_js(server, """(() => {
            const b = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-open')]
                .find(e => (e.dataset.open || '').includes('alpha.jl'));
            return !!b && b.dataset.open === 'dev/Alpha/src/alpha.jl';
        })()""") === true
        # And the header names the checkout on screen.
        @test TK.eval_js(server,
            """(document.querySelector('$(RF_REVIEW) .bt-rv-repo')?.textContent || '')
                .endsWith('/dev/Alpha')""") === true

        # ── Switching is the whole feature; it must actually re-run the diff.
        TK.eval_js(server, """(() => {
            const s = document.querySelector('$(RF_REVIEW) .bt-rv-folder');
            s.value = [...s.options].find(o => o.textContent === 'dev/Beta').value;
            s.dispatchEvent(new Event('change', {bubbles: true}));
            return true; })()""")
        @test TK.wait_for(server, "Beta's change replaces Alpha's",
            """(() => { const p = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                    .map(e => e.textContent);
                return p.some(t => t.includes('beta.jl')) &&
                       !p.some(t => t.includes('alpha.jl')); })()"""; timeout = 60) == true
        @test TK.eval_js(server, """(() => {
            const row = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-line')]
                .find(r => (r.dataset.file || '').includes('beta.jl'));
            return !!row && row.dataset.file === 'dev/Beta/src/beta.jl';
        })()""") === true

        # ── And it must STILL work after a page reload.
        #
        # This is the gap the rest of this file could not see. Every assertion
        # above passes against a picker whose handler is about to die: the
        # `<select>` is built inside a `map`, so it is rebuilt on every change and
        # re-serialised when the panel renders for a new session — and an
        # Observable interpolated onto such a node comes back `null` on the other
        # side of a reload. The picker then looks completely normal and does
        # nothing, for the rest of the session; ⟳ doesn't revive it either.
        #
        # It was found by driving the page by hand, not by a test, which is the
        # argument for this block existing. Asserted on the SYMPTOM (a pick has to
        # change the diff) rather than on the wiring, so it holds however the
        # handler is attached.
        @testset "the picker survives a reload" begin
            TK.eval_js(server, "location.reload(); true")
            @test TK.wait_for(server, "page back",
                "!!document.querySelector('.bt-header-review')"; timeout = 60) == true
            TK.eval_js(server, "document.querySelector('.bt-header-review').click(); true")
            @test TK.wait_for(server, "review tab back",
                "!!document.querySelector('$(RF_REVIEW) .bt-rv-folder')"; timeout = 60) == true
            # The reload REMEMBERS what was being reviewed. The workspace is
            # rebuilt and `open_review!` makes a fresh panel either way — what
            # changed is that the panel now wraps the project's `ReviewState`
            # instead of owning its own. Without it the tab came back undecided,
            # and with several checkouts (no auto-pick) that meant a trip through
            # the picker after every reload — for exactly the layout the feature
            # is for.
            @test TK.wait_for(server, "Beta still shown after the reload",
                """[...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                    .some(e => e.textContent.includes('beta.jl'))"""; timeout = 60) == true
            @test TK.eval_js(server, """(() => {
                const s = document.querySelector('$(RF_REVIEW) .bt-rv-folder');
                return [...s.options].find(o => o.selected)?.textContent === 'dev/Beta';
            })()""") === true

            # The actual regression: pick a checkout and the diff must follow.
            # Before the fix this was a no-op — the picker looked normal and did
            # nothing for the rest of the session.
            TK.eval_js(server, """(() => {
                const s = document.querySelector('$(RF_REVIEW) .bt-rv-folder');
                s.value = [...s.options].find(o => o.textContent === 'dev/Alpha').value;
                s.dispatchEvent(new Event('change', {bubbles: true}));
                return true; })()""")
            @test TK.wait_for(server, "switching still works after a reload",
                """(() => { const p = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-file-path')]
                        .map(e => e.textContent);
                    return p.some(t => t.includes('alpha.jl')) &&
                           !p.some(t => t.includes('beta.jl')); })()"""; timeout = 60) == true
            # And the paths are still in the project's frame, not the checkout's.
            @test TK.eval_js(server, """(() => {
                const row = [...document.querySelectorAll('$(RF_REVIEW) .bt-rv-line')]
                    .find(r => (r.dataset.file || '').includes('alpha.jl'));
                return !!row && row.dataset.file === 'dev/Alpha/src/alpha.jl';
            })()""") === true
        end

        # The one that actually hurts. A comment written in Feedback mode is
        # UNSENT work — the whole point of the mode is that they collect until you
        # deliver them as one instruction — and it used to be one accidental F5
        # away from gone, with no warning and no way back.
        @testset "pending comments survive a reload" begin
            TK.eval_js(server, """(() => {
                const b = document.querySelector('$(RF_REVIEW) [data-rv-mode="feedback"]');
                if (b) b.click(); return !!b; })()""")
            @test TK.wait_for(server, "feedback mode",
                "document.querySelector('$(RF_REVIEW)').dataset.mode === 'feedback'";
                timeout = 20) == true

            # Write one through the real affordance: + on a line, type, submit.
            TK.eval_js(server, """(() => {
                const p = document.querySelector('$(RF_REVIEW) .bt-rv-line .bt-rv-plus');
                if (p) p.click(); return !!p; })()""")
            @test TK.wait_for(server, "comment box open",
                "!!document.querySelector('$(RF_REVIEW) textarea')"; timeout = 20) == true
            TK.eval_js(server, """(() => {
                const t = document.querySelector('$(RF_REVIEW) textarea');
                t.value = 'UEBERLEBT-DEN-RELOAD';
                t.dispatchEvent(new Event('input', {bubbles: true}));
                return true; })()""")
            TK.eval_js(server, """(() => {
                const ok = [...document.querySelectorAll('$(RF_REVIEW) button')]
                    .find(b => /add|comment|ok|save/i.test(b.textContent));
                if (ok) ok.click(); return !!ok; })()""")
            @test TK.wait_for(server, "comment collected in the tray",
                """(document.querySelector('$(RF_REVIEW) .bt-rv-tray')?.innerText || '')
                    .includes('UEBERLEBT-DEN-RELOAD')"""; timeout = 30) == true

            TK.eval_js(server, "location.reload(); true")
            @test TK.wait_for(server, "page back",
                "!!document.querySelector('.bt-header-review')"; timeout = 60) == true
            TK.eval_js(server, "document.querySelector('.bt-header-review').click(); true")
            @test TK.wait_for(server, "review tab back",
                "!!document.querySelector('$(RF_REVIEW) .bt-rv-folder')"; timeout = 60) == true

            # Still there, and still in the mode it was written in.
            @test TK.wait_for(server, "the comment is still in the tray",
                """(document.querySelector('$(RF_REVIEW) .bt-rv-tray')?.innerText || '')
                    .includes('UEBERLEBT-DEN-RELOAD')"""; timeout = 30) == true
            @test TK.eval_js(server,
                "document.querySelector('$(RF_REVIEW)').dataset.mode === 'feedback'") === true
        end

        # An empty branch badge used to render as a visible 15×3px stub — a stray
        # dash beside the icon, held for as long as the "pick a folder" state was
        # on screen. It has a background and padding of its own, so unlike the
        # other header spans it does not collapse on its own.
        @testset "no stray empty branch badge" begin
            @test TK.eval_js(server, """(() => {
                const b = document.querySelector('$(RF_REVIEW) .bt-fv-badge');
                if (!b) return true;                      // not rendered at all is fine
                if (b.textContent.trim().length > 0) return true;   // has a branch: shown
                return b.getBoundingClientRect().width === 0;       // empty: invisible
            })()""") === true
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = folder_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
