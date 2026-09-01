# The review tab shows the PROJECT's folder, not the whole repository.
#
# A project is routinely a package inside a bigger checkout. The diff used to run
# at the git ROOT with no pathspec, so reviewing `pkg/` handed you every change in
# the monorepo — a sibling's edits in a review of code you were not looking at.
#
# ISOLATED, with exactly ONE chat: the same check inside `review.jl` needed a
# second chat, and then two review panels live in the DOM at once. `querySelector`
# answers about the first (the unscoped one) and — since an INACTIVE workspace
# panel still has an `offsetParent` — filtering for the "visible" one does not
# separate them either. Every assertion then reads as a product failure. One chat
# removes the ambiguity instead of working around it.
#
# What this pins that the headless `unit:git_diff_scope` cannot: that the scope
# actually reaches the UI — rows drop the shared prefix, `data-file` keeps a path
# the agent can act on from its own working directory, and the header names the
# folder on screen rather than the repository above it.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const SCOPE_REPO = mktempdir()
const SCOPE_SUB  = joinpath(SCOPE_REPO, "pkg")
const SCOPE_REVIEW = ".bw-ws-panel[data-panel-id^=\"review:\"] .bt-review"

# Names are all distinct on purpose: `includes("member.jl")` would also match
# `member_new.jl`, which would quietly weaken every assertion here.
function init_scope_repo!()
    git(args...) = run(pipeline(`git -C $SCOPE_REPO $args`; stdout = devnull, stderr = devnull))
    git("init", "-q")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "TestUser")
    mkpath(SCOPE_SUB)
    write(joinpath(SCOPE_SUB, "member.jl"), "member() = 1\n")
    write(joinpath(SCOPE_REPO, "sibling.jl"), "sibling() = 1\n")
    git("add", "-A")
    git("commit", "-qm", "initial")
    # One change on each side of the boundary, plus an untracked file inside.
    write(joinpath(SCOPE_SUB, "member.jl"), "member() = 2\n")
    write(joinpath(SCOPE_REPO, "sibling.jl"), "sibling() = 2\n")
    write(joinpath(SCOPE_SUB, "arrival.jl"), "arrival() = :in\n")
    return nothing
end

scope_agent(prompt) = [TK.text("RECEIVED<<" * prompt * ">>"), TK.end_turn()]

function run_suite(server)
    server.agent_fn[] = scope_agent
    init_scope_repo!()

    @testset "review is scoped to the project's folder" begin
        # The chat's cwd is the SUB-folder; the git root is one level up.
        TK.new_chat(server; cwd = SCOPE_SUB, title = "Scoped")
        TK.send_message(server, "hello")
        @test TK.wait_for(server, "chat bound",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 1";
            timeout = 90) == true

        TK.eval_js(server, "document.querySelector('.bt-header-review').click(); true")
        @test TK.wait_for(server, "review tab mounted",
            "!!document.querySelector('$(SCOPE_REVIEW)')"; timeout = 40) == true

        @test TK.wait_for(server, "the project's own change is listed",
            """[...document.querySelectorAll('$(SCOPE_REVIEW) .bt-rv-file-path')]
                .some(e => e.textContent.includes('member.jl'))"""; timeout = 60) == true
        # The untracked file inside the folder is scoped in too.
        @test TK.eval_js(server,
            """[...document.querySelectorAll('$(SCOPE_REVIEW) .bt-rv-file-path')]
                .some(e => e.textContent.includes('arrival.jl'))""") === true
        # The sibling lives in the same repository and must NOT be here.
        @test TK.eval_js(server,
            """[...document.querySelectorAll('$(SCOPE_REVIEW) .bt-rv-file-path')]
                .every(e => !e.textContent.includes('sibling.jl'))""") === true

        # The row drops the prefix every row would otherwise share…
        @test TK.eval_js(server, """(() => {
            const p = [...document.querySelectorAll('$(SCOPE_REVIEW) .bt-rv-file-path')]
                .find(e => e.textContent.includes('member.jl'));
            return !!p && p.textContent === 'member.jl';
        })()""") === true
        # …and `data-file` carries a path the AGENT can act on: its working
        # directory is the project folder, so a root-relative `pkg/member.jl`
        # would point at `pkg/pkg/member.jl` from where it stands.
        @test TK.eval_js(server, """(() => {
            const row = [...document.querySelectorAll('$(SCOPE_REVIEW) .bt-rv-line')]
                .find(r => (r.dataset.file || '').includes('member.jl'));
            return !!row && row.dataset.file === 'member.jl';
        })()""") === true
        # …and the header names what is on screen, not the repository above it.
        @test TK.eval_js(server,
            """(document.querySelector('$(SCOPE_REVIEW) .bt-rv-repo')?.textContent || '')
                .endsWith('/pkg')""") === true

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = scope_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
