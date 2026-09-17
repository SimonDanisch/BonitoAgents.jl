# "Continue this chat on another worker" against the REAL Claude Code agent.
#
# `worker_move_test.jl` proves the mechanics with the mock (transcript moved,
# cwd rewritten, session loaded). What only a real agent can prove is that
# Claude Code accepts a transcript that was written on one machine and moved
# under another working directory — that its `session/load` finds the file and
# the model actually remembers the conversation. So: tell the agent a word on
# worker A, continue the chat on worker B, ask for the word back.
#
# Opt-in (`BT_REAL_AGENT=1`): it needs `claude-agent-acp` on PATH, an
# authenticated Claude account, and it spends real tokens. Skipped otherwise,
# loudly, so a green run never silently means "not run".
@testitem "e2e:continue_on_worker_real" tags = [:e2e, :real] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT
    import AgentProviders

    if get(ENV, "BT_REAL_AGENT", "") != "1"
        @info "e2e:continue_on_worker_real skipped — set BT_REAL_AGENT=1 (needs claude-agent-acp + an authenticated Claude account)"
        @test true
    elseif Sys.which("claude-agent-acp") === nothing && isempty(get(ENV, "CLAUDE_AGENT_ACP", ""))
        error("BT_REAL_AGENT=1 but no claude-agent-acp on PATH (or CLAUDE_AGENT_ACP)")
    else
        VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
        header_env = "(() => { const p=$VP; const e=p && p.querySelector('.bt-header-env'); return e ? (e.textContent||'').trim() : ''; })()"
        open_menu = "(() => { const p=$VP; const t=p && p.querySelector('.bt-header-menu .bt-menu-trigger'); if(!t) return false; t.click(); return true; })()"
        continue_items = "(() => { const p=$VP; return [...(p ? p.querySelectorAll('.bt-header-menu .bt-menu-continue') : [])].map(b => (b.textContent||'').trim()); })()"
        click_continue(name) = "(() => { const p=$VP; const b=[...p.querySelectorAll('.bt-header-menu .bt-menu-continue')]" *
            ".find(x => (x.textContent||'').trim() === $(repr(name))); if(!b) return false; b.click(); return true; })()"
        # The last agent reply's text in the visible pane.
        last_reply = "(() => { const p=$VP; const m=p ? [...p.querySelectorAll('.bt-agent-msg')] : []; return m.length ? (m[m.length-1].innerText||'') : ''; })()"

        server = TK.dev_server(mock = false)
        # Claude Code writes the chat's transcripts under ~/.claude/projects/;
        # the test removes the two project dirs it causes (A's, then B's after
        # the move), so a real run leaves nothing in the user's session list.
        transcript_dirs = String[]
        transcript_dir(cwd) = joinpath(homedir(), ".claude", "projects", AgentProviders.claude_project_key(cwd))
        try
            TK.open_browser(server)
            state = server.h.state
            # The chat is created while the dev worker is the ONLY worker (which
            # card `new_chat` presses "+ Project" on follows the worker list's
            # order); worker B is spawned afterwards and shows up in the menu.
            cwd = mktempdir()
            write(joinpath(cwd, "README.md"), "a real chat that will move\n")
            pid = TK.new_chat(server; cwd = cwd, title = "realmove")
            p = state.projects[][pid]
            push!(transcript_dirs, transcript_dir(p.worker_path))
            worker_b_proc = TK.add_worker!(server; name = "worker-b")
            t0 = time()
            while time() - t0 < 30 &&
                  !any(w -> w.name == "worker-b" && w.online[], values(state.workers[]))
                sleep(0.1)
            end
            worker_b = only(w for w in values(state.workers[]) if w.name == "worker-b")
            @test worker_b.online[]
            @test p.worker_id != worker_b.worker_id

            TK.send_message(server, "Remember the secret word: pineapple. Reply with just OK.")
            @test TK.wait_for(server, "the agent acknowledged on A",
                "$(last_reply).toLowerCase().includes('ok')"; timeout = 180) == true
            t0 = time()
            while p.resume_session_id === nothing && time() - t0 < 30; sleep(0.1); end
            sid = p.resume_session_id
            @test sid !== nothing

            @test TK.eval_js(server, open_menu) == true
            @test TK.wait_for(server, "the menu offers worker-b",
                "$(continue_items).includes('worker-b')"; timeout = 30) == true
            @test TK.eval_js(server, click_continue("worker-b")) == true
            proj_dir_b = BT.worker_join(worker_b.projects_root, p.name)
            @test TK.wait_for(server, "the chat shows B's path",
                "$(header_env) === $(TK.json(replace(proj_dir_b, homedir() => "~")))";
                timeout = 180) == true
            # The transcript travelled and the session id was kept — Claude Code
            # on B will `session/load` a file written on A.
            @test p.resume_session_id == sid
            push!(transcript_dirs, transcript_dir(p.worker_path))
            @test isfile(joinpath(transcript_dir(p.worker_path), sid * ".jsonl"))

            TK.send_message(server, "What was the secret word? Reply with the word only.")
            @test TK.wait_for(server, "the agent remembers on B",
                "$(last_reply).toLowerCase().includes('pineapple')"; timeout = 180) == true
            # …through a LOADED session, not a fresh one that happened to be told.
            @test p.resume_session_id == sid

            kill(worker_b_proc)
            @test isempty(TK.js_errors(server))
        finally
            close(server)
            for d in transcript_dirs
                rm(d; recursive = true, force = true)
            end
        end
    end
end
