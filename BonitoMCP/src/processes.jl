# ── The processes this one runs, as the server records them ──────────────────
# The server keeps a record of every process a chat runs, on every worker, and a
# restart of the chat kills from it (BonitoAgents processes.jl). Its eval workers
# are what that record exists for: Malt starts each one in a process group of its
# own, so a kill of the agent's group (or the eval host's) never reaches them, nor
# anything their code started. A busy one, a test suite or a GPU wait, ran on for
# good after its chat was restarted.
#
# So this process reports itself and every eval worker it starts or stops, and on
# each (re)connect all of them again: a server that missed a frame, or restarted,
# catches up.
#
# `recorded_at` is a moment the process was alive. A process that takes its pid
# later started after it died, so a worker kills a recorded pid only if the
# process there now started before that moment (BonitoWorker `recorded_alive`).

function process_frame(pid::Integer; kind::AbstractString, label::AbstractString = "",
                       pgid::Integer = 0, alive::Bool = true)
    return Dict{String,Any}("type" => "process_update", "pid" => Int(pid), "pgid" => Int(pgid),
                            "kind" => String(kind), "label" => String(label),
                            "recorded_at" => time(), "alive" => alive)
end

report_process(pid::Integer; kw...) = (send_ctrl_frame(process_frame(pid; kw...)); nothing)
report_process_gone(pid::Integer) = (send_ctrl_frame(process_frame(pid; kind = "", alive = false)); nothing)

session_label(s::JuliaSession) = s.is_temp ? "temp session" : String(s.env_path)
report_session(s::JuliaSession) =
    report_process(worker_pid(s); kind = "julia session", label = session_label(s), pgid = s.pgid)

# This process and its live eval workers, all at once (on connect).
function announce_processes(m = manager())
    report_process(getpid(); kind = isempty(host_worker_id()) ? "mcp" : "eval host")
    live = @lock m.lock [s for s in values(m.sessions) if is_alive(s)]
    foreach(report_session, live)
    return length(live)
end
