# The cap on live agents counted chats whose agent had ended (2026-11-15). A
# chat whose worker went away or whose session failed keeps its model but runs
# no process, and its entry stayed in the list: on a server up for three days
# five of the eight slots were such chats, so every new bind closed a live chat.
@testitem "unit:bind_cap" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    st =BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    wid = "unit-bind-cap-worker"
    function chat!(pid)
        p = BT.ProjectInfo(pid, pid, wid, mktempdir(), mktempdir(), BT.now(BT.UTC))
        st.projects[][pid] = p
        agent = BT.WorkerAgent(st, wid, p.worker_path; project_id = pid)
        st.chat_models[pid] = BT.ChatModel(st, p.server_path; project_id = pid, agent)
        return pid
    end
    ended = [chat!("ended-$(i)") for i in 1:BT.BIND_CAP]
    append!(st.bound_lru, ended)
    @test !any(pid -> isopen(st.chat_models[pid].agent), ended)

    new = chat!("new")
    BT.note_bound!(st, new)
    @test st.bound_lru == [new]
    # Nothing was closed to make room: there was room.
    @test all(pid -> haskey(st.chat_models, pid), ended)

    # A chat closed before its bind was noted stays out.
    BT.note_bound!(st, "gone")
    @test st.bound_lru == [new]
end
