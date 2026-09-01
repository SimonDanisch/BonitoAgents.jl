# The git_diff patch crosses the control WS in CHUNKS, not one giant frame.
#
# A multi-MB single frame stalled heartbeats on both ends — the worker's send
# held the socket send lock while its inline pong queued behind it, and the
# server's inline decode of the whole frame fell behind ITS pong deadline.
# Each frame is now ≤ GIT_DIFF_CHUNK_BYTES (256 KiB), with metadata on frame 1,
# and the server reassembles them before parsing. THIS test is the "did the
# whole multi-frame reply really arrive" end of it: the fixture repo's patch is
# ~1.4 MB (~6 frames at 256 KiB), and the UI must show every file with the full
# "+600 / −600" counts — a truncated or mis-ordered reassembly would show less.
#
# The headless unit:git_diff_chunk_reassembly covers the reassembler's edge
# cases deterministically; this pins that real dev_server + real worker + real
# browser survive index > 1. Each file's 600 changed lines are deliberately
# over REVIEW_AUTO_OPEN_LINES (400) so it renders as a CLOSED summary row; the
# assertions read the counts from those rows, which exist regardless of
# open/closed and prove the full frame set arrived.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const BIG_DIFF_REPO = mktempdir()
const BIG_DIFF_FILES = ["big1.jl", "big2.jl", "big3.jl", "big4.jl", "big5.jl", "big6.jl"]
const BIG_DIFF_PER_FILE = 600
const BIG_DIFF_REVIEW = ".bw-ws-panel[data-panel-id^=\"review:\"] .bt-review"

# One file of `per` lines, each line distinct AND just under 200 chars long, so
# a full rewrite of all six files yields a patch of ~1.4 MB — comfortably past
# the 256 KiB chunk cap, far under the 15 000-rendered-line review cap.
function big_lines(f::Int, n::Int, v::Int)
    ["$(lpad("$f:$i", 9, '0'))|v$v|" * repeat("~", 180) for i in 1:n]
end

function init_big_diff_repo!()
    git(args...) = run(pipeline(`git -C $BIG_DIFF_REPO $args`; stdout = devnull, stderr = devnull))
    git("init", "-q")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "TestUser")
    for (idx, name) in enumerate(BIG_DIFF_FILES)
        write(joinpath(BIG_DIFF_REPO, name), join(big_lines(idx, BIG_DIFF_PER_FILE, 1), "\n") * "\n")
    end
    git("add", "-A")
    git("commit", "-qm", "initial")
    # Rewrite every line of every file: v1 → v2, nothing left identical.
    for (idx, name) in enumerate(BIG_DIFF_FILES)
        write(joinpath(BIG_DIFF_REPO, name), join(big_lines(idx, BIG_DIFF_PER_FILE, 2), "\n") * "\n")
    end
    return nothing
end

big_agent(prompt) = [TK.text("RECEIVED<<" * prompt * ">>"), TK.end_turn()]

function run_suite(server)
    server.agent_fn[] = big_agent
    init_big_diff_repo!()

    @testset "the big diff arrives as MULTIPLE frames" begin
        TK.new_chat(server; cwd = BIG_DIFF_REPO, title = "BigDiff")
        TK.send_message(server, "hello")
        @test TK.wait_for(server, "chat bound",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 1";
            timeout = 90) == true

        TK.eval_js(server, "document.querySelector('.bt-header-review').click(); true")
        @test TK.wait_for(server, "review tab mounted",
            "!!document.querySelector('$(BIG_DIFF_REVIEW)')"; timeout = 40) == true

        # All six files survived the chunked trip — one lost frame would drop a
        # file or leave it with a shortened hunk, both visible below.
        @test TK.wait_for(server, "the first big file is listed",
            """[...document.querySelectorAll('$(BIG_DIFF_REVIEW) .bt-rv-file-path')]
                .some(e => e.textContent.includes('big1.jl'))"""; timeout = 90) == true
        @test TK.eval_js(server,
            """[...document.querySelectorAll('$(BIG_DIFF_REVIEW) .bt-rv-file-path')]
                .map(e => e.textContent).filter(t => /big[1-6][.]jl/.test(t)).length""") == 6

        # The FULL patch reassembled: each file must show all 600 additions and
        # 600 deletions. Fewer means a chunk was lost, truncated, or mis-ordered.
        for name in BIG_DIFF_FILES
            @test TK.eval_js(server, """(() => {
                const f = [...document.querySelectorAll('$(BIG_DIFF_REVIEW) .bt-rv-file')]
                    .find(e => e.querySelector('.bt-rv-file-path')?.textContent.includes('$name'));
                return f && f.querySelector('.bt-rv-plus-count')?.textContent === '+$(BIG_DIFF_PER_FILE)'
                    && f.querySelector('.bt-rv-minus-count')?.textContent === '−$(BIG_DIFF_PER_FILE)';
            })()""") === true
        end

        # Header names the repository the multi-frame diff was taken from.
        @test TK.eval_js(server,
            """(document.querySelector('$(BIG_DIFF_REVIEW) .bt-rv-repo')?.textContent || '')
                .endsWith('/$(basename(BIG_DIFF_REPO))')""") === true

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = big_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end