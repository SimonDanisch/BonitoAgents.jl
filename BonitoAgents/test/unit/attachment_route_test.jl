# Headless: the inline-attachment pipeline that turns a user message's
# "[attached files in this message]" suffix into an image gallery.
#   • `split_attachment_suffix` — text ⇄ attachment-list split (msg_to_dict).
#   • `attachment_response` — the /attachment/<pid>?file=<name> route: serves
#     the server-mirror file inline with the real image mime, and rejects
#     anything that isn't a bare, known-extension filename inside the
#     project's `.bt-attachments/` dir.
#   • `msg_to_dict(::UserMsg)` — the wire dict carries `attachments` + the
#     STRIPPED text, while `m.text` (agent prompt / chat.md form) is untouched.
@testitem "unit:attachment_route" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test

    @testset "split_attachment_suffix" begin
        # No suffix → text unchanged, no attachments.
        @test BT.split_attachment_suffix("hello") == ("hello", String[])
        # Canonical process_attachments! shape.
        t = "look\n\n[attached files in this message]\n  - .bt-attachments/a.png\n  - .bt-attachments/b.jpg"
        @test BT.split_attachment_suffix(t) ==
              ("look", [".bt-attachments/a.png", ".bt-attachments/b.jpg"])
        # Marker with no list lines → treated as plain text (nothing stripped).
        @test BT.split_attachment_suffix("x [attached files in this message] y") ==
              ("x [attached files in this message] y", String[])
        # Empty text.
        @test BT.split_attachment_suffix("") == ("", String[])
    end

    @testset "attachment_response route guards + happy path" begin
        state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                               worker_secret = "x")
        pid = "attroute1"
        root = mktempdir()
        p = BT.ProjectInfo(pid, "AttRoute", "w1", root, root, BT.now(BT.UTC))
        state.projects[][pid] = p

        att = joinpath(root, BT.ATTACHMENT_DIR_NAME)
        mkpath(att)
        bytes = UInt8[0x89, 0x50, 0x4e, 0x47, 0x01, 0x02, 0x03]
        write(joinpath(att, "2026-01-01_000000_abcd1234.png"), bytes)

        r = BT.attachment_response(state, pid, "2026-01-01_000000_abcd1234.png")
        @test r.status == 200
        hdrs = Dict(r.headers)
        @test hdrs["Content-Type"] == "image/png"
        @test occursin("immutable", hdrs["Cache-Control"])
        @test Vector{UInt8}(r.body) == bytes

        # The exposed surface is EXACTLY `<server_path>/.bt-attachments/<bare name>`.
        @test BT.attachment_response(state, pid, "../chat.md").status == 403
        @test BT.attachment_response(state, pid, "/etc/passwd").status == 403
        @test BT.attachment_response(state, pid, "sub/x.png").status == 403
        @test BT.attachment_response(state, pid, "evil.html").status == 403   # foreign ext
        @test BT.attachment_response(state, pid, "missing.png").status == 404
        @test BT.attachment_response(state, "nope", "x.png").status == 404
        @test BT.attachment_response(state, "../../etc", "x.png").status == 404
    end

    @testset "msg_to_dict(::UserMsg) splits the wire form only" begin
        state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                               worker_secret = "x")
        cwd = mktempdir()
        pid = "attwire01"
        state.projects[][pid] = BT.ProjectInfo(pid, "AttWire", "w1", cwd, cwd,
                                               BT.now(BT.UTC))
        # A WorkerAgent is a plain struct — nothing connects until `start!`,
        # which this wire-shape test never calls (same pattern as unit:ram_bounds).
        model = BT.ChatModel(state, cwd; project_id = pid,
                             agent = BT.WorkerAgent(state, "w1", cwd))
        text = "see this\n\n[attached files in this message]\n  - .bt-attachments/2026-01-01_000000_beef00.png"
        m = BT.UserMsg(model, text)
        d = BT.msg_to_dict(m)
        @test d["text"] == "see this"                       # display form stripped
        @test length(d["attachments"]) == 1
        a = d["attachments"][1]
        @test a["url"] == "/attachment/$(pid)?file=2026-01-01_000000_beef00.png"
        @test a["mime"] == "image/png"
        @test m.text == text                                # model text untouched
        # No project bound → no attachment URLs, raw text passes through.
        m2 = BT.UserMsg(text)
        d2 = BT.msg_to_dict(m2)
        @test d2["text"] == text
        @test !haskey(d2, "attachments")
        # A foreign extension in the list keeps the whole message textual —
        # never a partial gallery next to a partial list.
        t3 = "x\n\n[attached files in this message]\n  - .bt-attachments/ok.png\n  - .bt-attachments/odd.tiff"
        d3 = BT.msg_to_dict(BT.UserMsg(model, t3))
        @test d3["text"] == t3
        @test !haskey(d3, "attachments")
        close(model)
    end

    @testset "server restart: history-loaded messages resolve attachments" begin
        # Regression: load_history builds `UserMsg(text)` with `chat = nothing`
        # (the model doesn't exist while parsing), so after a SERVER RESTART a
        # reopened chat rendered the raw "[attached files …]" suffix instead of
        # the inline gallery — a mere page reload never hit this because the
        # live msgs_store kept the original chat-ref'd instances. The ChatModel
        # constructor now re-parents history-loaded UserMsgs.
        state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                               worker_secret = "x")
        cwd = mktempdir()
        pid = "attboot01"
        state.projects[][pid] = BT.ProjectInfo(pid, "AttBoot", "w1", cwd, cwd,
                                               BT.now(BT.UTC))
        # Persist the chat BEFORE any model exists (what a past session left).
        chat_dir = BT.chat_storage_dir(state, pid, cwd)
        sess = BT.load_session(chat_dir, cwd)
        BT.append_user(sess, BT.UserMsg(
            "look at this\n\n[attached files in this message]\n  - .bt-attachments/2026-01-01_000000_boot0001.png"))
        att = joinpath(cwd, BT.ATTACHMENT_DIR_NAME)
        mkpath(att)
        write(joinpath(att, "2026-01-01_000000_boot0001.png"), UInt8[1, 2, 3])

        # Fresh model = the post-restart reconstruction (load_history inside).
        model = BT.ChatModel(state, cwd; project_id = pid,
                             agent = BT.WorkerAgent(state, "w1", cwd))
        m = BT.shared(model).msgs_store[1]
        @test m isa BT.UserMsg
        @test m.chat !== nothing                       # re-parented on load
        d = BT.msg_to_dict(m)
        @test d["text"] == "look at this"
        @test length(d["attachments"]) == 1
        @test d["attachments"][1]["url"] ==
              "/attachment/$(pid)?file=2026-01-01_000000_boot0001.png"
        close(model)
    end
end
