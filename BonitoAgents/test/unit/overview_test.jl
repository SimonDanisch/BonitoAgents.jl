# Headless: the recent-chats overview data layer (overview.jl) — the card
# selection (last N by chat.md mtime), the user-prompt snippets (system tags /
# interruption markers stripped, auto-continues skipped), and the last-image
# resolution (user attachments via the /attachment route). Everything derives
# from the persisted store, so these tests exercise exactly the code path a
# server restart takes (no live ChatModel involved).
@testitem "unit:overview" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test

    newstate() = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                                worker_secret = "x")

    # A persisted chat for project `pid`: write user messages through the real
    # writer (append_user → the exact chat.md form load_history parses).
    function seed_chat!(state, pid, name, prompts; title = nothing)
        cwd = mktempdir()
        p = BT.ProjectInfo(pid, name, "w1", cwd, cwd, BT.now(BT.UTC))
        p.title = title
        state.projects[][pid] = p
        chat_dir = BT.chat_storage_dir(state, pid, cwd)
        sess = BT.load_session(chat_dir, cwd)
        for t in prompts
            BT.append_user(sess, BT.UserMsg(t))
        end
        return p
    end

    @testset "overview_user_snippet strips system noise" begin
        @test BT.overview_user_snippet("plain prompt") == "plain prompt"
        @test BT.overview_user_snippet(
            "<system-reminder>ctx</system-reminder>real question") == "real question"
        @test BT.overview_user_snippet("[Request interrupted by user]") === nothing
        @test BT.overview_user_snippet(
            "do the thing [Request interrupted by user for tool use]") == "do the thing"
        # Attachment suffix never leaks into the snippet.
        @test BT.overview_user_snippet(
            "see image\n\n[attached files in this message]\n  - .bt-attachments/a.png") ==
            "see image"
        # Pure system commentary → no snippet.
        @test BT.overview_user_snippet("<ide_opened_file>The user opened x.jl") === nothing
    end

    @testset "overview_snippets: last N meaningful prompts, oldest first" begin
        msgs = BT.ChatMsg[
            BT.UserMsg("one"), BT.UserMsg("two"), BT.UserMsg("three"), BT.UserMsg("four"),
        ]
        @test BT.overview_snippets(msgs; limit = 3) == ["two", "three", "four"]
        # Auto-continue nudges and system-only messages don't count.
        auto = BT.UserMsg("yolo auto-continue"); auto.auto = true
        msgs2 = BT.ChatMsg[BT.UserMsg("real"), auto,
                           BT.UserMsg("<system-reminder>x</system-reminder>")]
        @test BT.overview_snippets(msgs2; limit = 3) == ["real"]
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

    @testset "overview_image: newest user attachment wins, missing files skipped" begin
        state = newstate()
        p = seed_chat!(state, "imgproj01", "imgchat", String[])
        att = joinpath(p.server_path, BT.ATTACHMENT_DIR_NAME)
        mkpath(att)
        write(joinpath(att, "2026-01-01_000000_aaaa1111.png"), UInt8[1, 2, 3])
        msgs = BT.ChatMsg[
            BT.UserMsg("first\n\n[attached files in this message]\n  - .bt-attachments/2026-01-01_000000_aaaa1111.png"),
            BT.UserMsg("later, file gone\n\n[attached files in this message]\n  - .bt-attachments/2026-01-01_000000_gone0000.png"),
        ]
        chat_dir = BT.chat_storage_dir(state, p.id, p.server_path)
        img = BT.overview_image(state, p, msgs, chat_dir)
        # The newest message's file is missing → falls back to the older one.
        @test img == "/attachment/imgproj01?file=2026-01-01_000000_aaaa1111.png"
        # No attachments at all → nothing.
        @test BT.overview_image(state, p, BT.ChatMsg[BT.UserMsg("no image")], chat_dir) === nothing
    end
end
