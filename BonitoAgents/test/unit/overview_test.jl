# Headless: the recent-chats overview data layer (overview.jl) — the card
# selection (last N by chat.md mtime), the user-prompt snippets (system tags /
# interruption markers stripped, auto-continues skipped), and persistent chat image identities. Everything derives
# from the persisted store, so these tests exercise exactly the code path a
# server restart takes (no live ChatModel involved).
@testitem "unit:overview" tags = [:unit] begin
    import BonitoAgents
    import AgentProviders
    const BT = BonitoAgents
    using Test

    # Wrapper stripping is dispatched per provider (AgentProviders), and these
    # are Claude's wrappers. Bound once here so the cases below read as before.
    overview_user_snippet(t) =
        BT.overview_user_snippet(AgentProviders.ClaudeCodeAgent(), t)
    overview_snippets(msgs; kw...) =
        BT.overview_snippets(msgs; provider = AgentProviders.ClaudeCodeAgent(), kw...)

    newstate() = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                                worker_secret = "x")

    # A persisted chat for project `pid`: write user messages through the real
    # writer (append_user → the exact chat.md form load_history parses).
    function seed_chat!(state, pid, name, prompts; title = nothing)
        cwd = mktempdir()
        p = BT.ProjectInfo(pid, name, "w1", cwd, cwd, BT.now(BT.UTC))
        title === nothing || (p.title[] = title)
        state.projects[][pid] = p
        chat_dir = BT.chat_storage_dir(state, pid, cwd)
        sess = BT.load_session(chat_dir, cwd)
        for t in prompts
            BT.append_user(sess, BT.UserMsg(t))
        end
        return p
    end

    @testset "overview_user_snippet strips system noise" begin
        @test overview_user_snippet("plain prompt") == "plain prompt"
        @test overview_user_snippet(
            "<system-reminder>ctx</system-reminder>real question") == "real question"
        @test overview_user_snippet("[Request interrupted by user]") === nothing
        @test overview_user_snippet(
            "do the thing [Request interrupted by user for tool use]") == "do the thing"
        # Attachment suffix never leaks into the snippet.
        @test overview_user_snippet(
            "see image\n\n[attached files in this message]\n  - .bt-attachments/a.png") ==
            "see image"
        # Pure system commentary → no snippet.
        @test overview_user_snippet("<ide_opened_file>The user opened x.jl") === nothing
    end

    @testset "overview_snippets: last N meaningful prompts, oldest first" begin
        msgs = BT.ChatMsg[
            BT.UserMsg("one"), BT.UserMsg("two"), BT.UserMsg("three"), BT.UserMsg("four"),
        ]
        @test overview_snippets(msgs; limit = 3) == ["two", "three", "four"]
        # Auto-continue nudges and system-only messages don't count.
        auto = BT.UserMsg("yolo auto-continue"); auto.auto = true
        msgs2 = BT.ChatMsg[BT.UserMsg("real"), auto,
                           BT.UserMsg("<system-reminder>x</system-reminder>")]
        @test overview_snippets(msgs2; limit = 3) == ["real"]
    end

    @testset "recent_chat_cards: mtime order, limit, counts, persistence path" begin
        state = newstate()
        # 8 chats, mtimes staggered oldest→newest by explicit touch.
        for i in 1:8
            seed_chat!(state, "proj000$(i)", "chat-$i", ["prompt for chat $i"];
                       title = i == 8 ? "pinned title" : nothing)
            f = joinpath(state.state_dir, "chats", "proj000$(i)", "chat.md")
            run(`touch -d "2026-01-0$(i) 12:00" $f`)
        end
        cards = BT.recent_chat_cards(state)
        @test length(cards) == 6                              # capped at OVERVIEW_LIMIT
        @test [c.pid for c in cards] ==
              ["proj000$(i)" for i in 8:-1:3]                 # newest first
        @test cards[1].title == "pinned title"                # persistent title wins
        @test cards[2].title == "chat-7"                      # else folder name
        @test all(c -> c.msg_count == 1, cards)
        @test cards[1].snippets == ["prompt for chat 8"]
        # No live ChatModel exists for any of these — this exercised the
        # load_history (restart) path by construction.
        @test isempty(state.chat_models)
    end

    @testset "chat image is a durable identity, changed only by an explicit pick" begin
        state = newstate()
        p = seed_chat!(state, "imgproj01", "imgchat", String[])
        att = joinpath(p.server_path, BT.ATTACHMENT_DIR_NAME)
        mkpath(att)
        picture(color) = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"60\"><rect width=\"80\" height=\"60\" fill=\"$color\"/></svg>"
        red, blue = picture("red"), picture("blue")
        write(joinpath(att, "red.svg"), red)
        write(joinpath(att, "notes.txt"), "not an image")
        attachment(name) = BT.UserMsg("look\n\n[attached files in this message]\n  - .bt-attachments/$name")
        msgs = BT.ChatMsg[attachment("red.svg")]
        append!(msgs, [BT.UserMsg("later message $i") for i in 1:250])
        push!(msgs, attachment("missing.png"), attachment("notes.txt"))
        chat_dir = BT.chat_storage_dir(state, p.id, p.server_path)
        selected = BT.select_chat_icon!(state, p, msgs, chat_dir)
        @test selected !== nothing
        @test read(selected, String) == red  # searches beyond the old 200-message window
        @test dirname(selected) == BT.chat_icon_dir(state, p)

        # New pictures do not change the identity.
        write(joinpath(att, "blue.svg"), blue)
        push!(msgs, attachment("blue.svg"))
        @test BT.select_chat_icon!(state, p, msgs, chat_dir) == selected
        @test BT.chat_icon_image(state, p).local_path == selected
        @test isempty(state.chat_models)  # does not need a live chat

        # The chosen source can be overwritten/deleted, and the server can
        # restart with NO worker or model. The image bytes remain identical.
        write(joinpath(att, "red.svg"), "overwritten")
        rm(joinpath(att, "red.svg"))
        restarted = BT.ServerState(; state_dir=state.state_dir,
            working_dir=state.working_dir, worker_secret="x")
        @test BT.chat_icon_image(restarted, p).local_path == selected
        @test read(selected, String) == red

        # "Set as chat icon" on a picture in the chat replaces the identity,
        # which then survives a restart and the loss of its source as well.
        wait(BT.set_chat_icon!(restarted, p, false, "blue.svg"))
        chosen = BT.chat_icon_image(restarted, p).local_path
        @test chosen != selected
        @test read(chosen, String) == blue
        @test readdir(BT.chat_icon_dir(restarted, p)) == sort([basename(chosen), "selected"])
        rm(joinpath(att, "blue.svg"))
        again = BT.ServerState(; state_dir=state.state_dir,
            working_dir=state.working_dir, worker_secret="x")
        @test BT.chat_icon_image(again, p).local_path == chosen
        @test read(chosen, String) == blue
        @test BT.select_chat_icon!(again, p, msgs, chat_dir) == chosen

        # A picture that cannot be read leaves the identity alone; picking the
        # current one again is a no-op.
        @test_logs (:warn, r"picture unavailable") match_mode=:any wait(BT.set_chat_icon!(again, p, false, "missing.png"))
        @test BT.chat_icon_image(again, p).local_path == chosen
        write(joinpath(att, "blue.svg"), blue)
        wait(BT.set_chat_icon!(again, p, false, "blue.svg"))
        @test BT.chat_icon_image(again, p).local_path == chosen
        @test readdir(BT.chat_icon_dir(again, p)) == sort([basename(chosen), "selected"])

        # Only pictures the chat itself serves are accepted.
        @test_throws ArgumentError BT.set_chat_icon!(again, p, false, "../secret.png")
        @test_throws ArgumentError BT.set_chat_icon!(again, p, false, "notes.txt")
        @test_throws ArgumentError BT.set_chat_icon!(again, p, true, "relative/plot.png")
    end

    @testset "old unopened chats acquire their image from persisted history" begin
        state = newstate()
        prompts = ["look\n\n[attached files in this message]\n  - .bt-attachments/old.svg"]
        append!(prompts, ["later message $i" for i in 1:250])
        p = seed_chat!(state, "old-image", "old chat", prompts; title="old chat")
        att = joinpath(p.server_path, BT.ATTACHMENT_DIR_NAME)
        mkpath(att)
        bytes = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"73\" height=\"41\"/>"
        write(joinpath(att, "old.svg"), bytes)
        BT.chat_icon_image(state, p)
        task = state.chat_icons[p.id].task
        task === nothing || wait(task)
        image = BT.chat_icon_image(state, p)
        @test image !== nothing
        @test read(image.local_path, String) == bytes
        @test isempty(state.chat_models)
        @test isempty(state.worker_control_ws)
    end
end
