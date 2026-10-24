# A picture the agent opens with Read is a file on its worker: it streams from
# there, it can be made the chat's icon, and the chat's automatic icon may pick
# it. A Read restored from chat.md came back without the file it names, so a
# reopened chat (the Smartwatch chat, 10-15) showed its pictures from inline
# base64, without "Set as chat icon", and never took one as its icon. The file
# is stored with the call's arguments next to the chat; it is read back here.
@testitem "unit:read_pictures" tags = [:unit] begin
    using BonitoAgents
    import JSON
    const BT = BonitoAgents

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    root = mktempdir()
    p = BT.ProjectInfo("rp1", "Pictures", "w1", root, root, BT.now(BT.UTC))
    state.projects[][p.id] = p
    model = BT.ChatModel(state, root; project_id = p.id, agent = BT.WorkerAgent(state, "w1", root))

    # As `load_history` rebuilds a Read call, with its arguments stored as
    # `persist_tool_content!` writes them.
    function restored_read(id, path)
        open(BT.tool_file(model.chat_dir, id), "w") do io
            JSON.print(io, Dict("content" => Any[], "rawInput" => Dict("file_path" => path)))
        end
        m = BT.builtin_msg_type("read", "Read")(
            BT.Message(id, "read", "Read", "Read $(basename(path))", "completed", "", time(), time(), nothing))
        m.message.chat = model
        return m
    end

    watch = restored_read("toolu_watch", "/w/Smartwatch/bilder/venu3.jpg")
    code = restored_read("toolu_code", "/w/Smartwatch/notes.jl")
    @test watch isa BT.ReadToolMsg
    @test watch.file_path == ""                       # what chat.md gives back

    @testset "a restored Read names its file again" begin
        @test BT.tool_file_path(watch) == "/w/Smartwatch/bilder/venu3.jpg"
        @test watch.file_path == "/w/Smartwatch/bilder/venu3.jpg"     # kept
        rm(BT.tool_file(model.chat_dir, "toolu_watch"))
        @test BT.tool_file_path(watch) == "/w/Smartwatch/bilder/venu3.jpg"
    end

    @testset "a Read picture can become the chat's icon" begin
        msgs = BT.ChatMsg[code, watch]
        @test BT.chat_icon_candidates(state, p, msgs, model.chat_dir) ==
              [(true, "/w/Smartwatch/bilder/venu3.jpg")]   # not the source file
    end
end
