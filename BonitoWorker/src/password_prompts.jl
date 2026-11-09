# ── Jobs that ask for passwords: sudo and ssh ────────────────────────────────
# The worker runs them so that a password typed into the chat goes from the
# server straight to sudo or ssh, never through the agent or its transcript.
#
# Their standard input is a socket that only the worker and the job hold, never a
# pipe. A process of the same user can open a pipe through /proc/<pid>/fd and read
# the password before the job does, but it can't open a socket that way at all.
# Yama (kernel.yama.ptrace_scope >= 1) keeps the agent, which the worker started,
# out of the worker's memory and its children's.
#
# sudo is setuid root, so the agent can't read its memory or environment either.
# It prompts with a nonce that the gate hands it over that socket, as SUDO_PROMPT,
# never on a command line, which anyone can read. The worker answers once, when the
# nonce shows up in the output. Without a prompt (a NOPASSWD rule) the password is
# never written, so the command can't read it from its input.
#
# sudo on another host goes through a bt_ssh connection of the same chat: ssh's
# input is that socket, the nonce travels to the remote shell as its first line,
# and the prompt comes back in ssh's output. The agent never gets the password,
# but there it passes through the user's account on that host (its shell reads
# ~/.bashrc first), so that is no defense against an agent working against the user.
#
# ssh asks through SSH_ASKPASS: a helper that writes the prompt to the worker over
# the same socket and prints the answer. That keeps the password out of the agent's
# context and the transcript, but it doesn't protect it from an agent working
# against the user: ssh runs as the user and reads ~/.ssh/config, which the agent
# can change (a ProxyCommand to a host of its own, say).

abstract type PromptingLaunch <: Launch end

# Where sudo runs: on the worker, or on the host a bt_ssh connection reaches.
struct LocalSudo
    sudo::String                       # setuid root, see `sudo_program`
end
struct SshSudo
    ssh::String
    control_path::String               # the connection's master
    destination::String
    sudo::String                       # "sudo" on that host's PATH, or the supervisor's own
end

mutable struct SudoLaunch <: PromptingLaunch
    route::Union{LocalSudo,SshSudo}
    nonce::String                      # the prompt sudo prints; only it and the worker know it
    held::Vector{UInt8}                # output that may be the start of the prompt
    asked::Bool                        # sudo gets one answer, see `respond!`
    input::Union{Base.PipeEndpoint,Nothing}
end
SudoLaunch(route::Union{LocalSudo,SshSudo}) = SudoLaunch(route,
    "bonito-sudo-" * bytes2hex(rand(Random.RandomDevice(), UInt8, 16)) * ": ", UInt8[], false, nothing)

mutable struct SshLaunch <: PromptingLaunch
    ssh::String
    askpass::String
    control_path::String               # the master's socket; ssh creates it once logged in
    input::Union{Base.PipeEndpoint,Nothing}
end

job_kind(::PlainLaunch) = "command"
job_kind(::SudoLaunch) = "sudo"
job_kind(::SshLaunch) = "ssh"

launch_record(::Launch) = Dict{String,Any}()
launch_record(l::SshLaunch) = Dict{String,Any}("control_path" => l.control_path, "ready" => false)
launch_record(l::SudoLaunch) = sudo_record(l.route)
sudo_record(::LocalSudo) = Dict{String,Any}()
sudo_record(r::SshSudo) = Dict{String,Any}("host" => r.destination)

# The prompting jobs get no environment from the agent: an ENV or BASH_ENV would
# run its code in the gate, which holds the socket.
check_launch(::PlainLaunch, env) = nothing
function check_launch(::PromptingLaunch, env)
    Sys.isunix() || throw(ArgumentError("password prompts need a Linux or macOS worker"))
    isempty(env) || throw(ArgumentError("a sudo or ssh job takes no environment"))
    return nothing
end

launch_argv(::PlainLaunch, argv) = argv
launch_argv(l::SudoLaunch, argv) = sudo_argv(l.route, argv)
sudo_argv(r::LocalSudo, argv) = [r.sudo, "-S", "-k", "--", argv...]
# Through the master only: BatchMode, so a connection that ended fails instead of
# asking. The remote login shell runs one POSIX sh line (`remote_sudo`).
sudo_argv(r::SshSudo, argv) = [r.ssh, "-S", r.control_path, "-o", "ControlMaster=no",
    "-o", "BatchMode=yes", "-T", "--", r.destination, remote_sudo(r.sudo, argv)]

const REMOTE_SUDO = "IFS= read -r p || exit 125; SUDO_PROMPT=\$p; export SUDO_PROMPT; " *
    "s=\$1; shift; exec \"\$s\" -S -k -- \"\$@\""
remote_sudo(sudo, argv) =
    join(Base.shell_escape_posixly.(["exec", "sh", "-c", REMOTE_SUDO, "bonito-sudo", sudo, argv...]), ' ')
# `argv` is what the job record shows, `ssh -o ... -- destination`. Ours go first:
# for `-o` the first value wins. LocalCommand would inherit the socket.
launch_argv(l::SshLaunch, argv) = [l.ssh, "-M", "-N", "-o", "ControlPath=$(l.control_path)",
    "-o", "ControlPersist=no", "-o", "PermitLocalCommand=no", "-o", "BatchMode=no", argv[2:end]...]

launch_env(::Launch) = ()
launch_env(l::SshLaunch) = ("SSH_ASKPASS" => l.askpass, "SSH_ASKPASS_REQUIRE" => "force")

const PROMPT_GATE = "IFS= read -r gate || exit 125; [ \"\$gate\" = go ] || exit 125; "
# The gate, then the command with the rest of the input.
gated(argv) = Cmd(["/bin/sh", "-c", PROMPT_GATE * "exec \"\$@\"", "bonito-managed-process", argv...])
process_launch_command(::SshLaunch, argv) = gated(argv)
process_launch_command(l::SudoLaunch, argv) = sudo_gate(l.route, argv)
sudo_gate(::LocalSudo, argv) = Cmd(["/bin/sh", "-c",
    PROMPT_GATE * "IFS= read -r SUDO_PROMPT || exit 125; export SUDO_PROMPT; exec \"\$@\"",
    "bonito-managed-process", argv...])
# The nonce line stays in the input: ssh carries it to the remote shell.
sudo_gate(::SshSudo, argv) = gated(argv)

gate_lines(::Launch) = "go\n"
gate_lines(l::SudoLaunch) = "go\n" * l.nonce * "\n"

# ── The job's input ──────────────────────────────────────────────────────────
# A plain job's is the gate pipe, closed once the gate passed, so the command reads
# EOF. A prompting job's is a socket pair: the child's end until it is spawned, the
# worker's for as long as the job runs.

job_input(::PlainLaunch) = Pipe()
child_end(gate::Pipe) = gate
close_child_end!(gate::Pipe) = close(gate.out)
keep_input!(::PlainLaunch, gate::Pipe, s, j) = nothing
release_input!(::PlainLaunch, gate::Pipe) = close(gate)

mutable struct SocketInput
    child::RawFD                       # RawFD(-1) once closed in the worker
    ours::Base.PipeEndpoint
end

function job_input(::PromptingLaunch)
    fds = Vector{Cint}(undef, 2)
    # libuv sets close-on-exec on both, so no other child of the worker inherits them.
    err = ccall(:uv_socketpair, Cint, (Cint, Cint, Ptr{Cint}, Cint, Cint), 1, 0, fds, 0, 0)  # SOCK_STREAM
    err == 0 || throw(Base.IOError("socketpair: " * Base.struverror(err), err))
    ours = Base.PipeEndpoint()
    Base.open_pipe!(ours, RawFD(fds[1]))
    return SocketInput(RawFD(fds[2]), ours)
end
child_end(i::SocketInput) = i.child
function close_child_end!(i::SocketInput)
    fd = reinterpret(Cint, i.child)
    fd >= 0 && ccall(:close, Cint, (Cint,), fd)
    i.child = RawFD(-1)
    return nothing
end
Base.write(i::SocketInput, data::AbstractString) = write(i.ours, data)
Base.flush(i::SocketInput) = flush(i.ours)

keep_input!(l::SudoLaunch, i::SocketInput, s, j) = (l.input = i.ours; nothing)
function keep_input!(l::SshLaunch, i::SocketInput, s, j)
    l.input = i.ours
    Base.errormonitor(@async read_prompts(s, j, l))
    return nothing
end
# After a failed start nothing kept it.
function release_input!(l::PromptingLaunch, i::SocketInput)
    close_child_end!(i)
    l.input === i.ours || close(i.ours)
    return nothing
end

finish!(::PlainLaunch) = nothing
function finish!(l::PromptingLaunch)
    l.input === nothing || close(l.input)
    return nothing
end
function finish!(l::SshLaunch)
    l.input === nothing || close(l.input)
    rm(dirname(l.control_path); recursive = true, force = true)
    return nothing
end

# Called on the supervisor's tick. True when the record changed.
observe!(::Launch, record) = false
function observe!(l::SshLaunch, record)
    record["ready"] === false && ispath(l.control_path) || return false
    record["ready"] = true
    return true
end

# ── Prompts ──────────────────────────────────────────────────────────────────
# A prompt is part of the job's record, so the server shows the question from the
# job's state, after a reload or a reconnect too. `seq` tells the answers apart.

function ask!(j::ManagedProcess, kind::AbstractString, text::AbstractString)
    d = j.record
    d["prompt_seq"] += 1
    d["prompt"] = Dict{String,Any}("seq" => d["prompt_seq"], "kind" => String(kind), "text" => first(String(text), 4000))
    d["revision"] += 1
    return nothing
end

# Output on its way to the log. sudo's prompt is taken out: what is left is held
# back while it could still be the start of the next one.
screen_output!(::Launch, j, data::Vector{UInt8}) = data
held_output!(::Launch) = UInt8[]
function screen_output!(l::SudoLaunch, j::ManagedProcess, data::Vector{UInt8})
    buf = vcat(l.held, data)
    nonce = codeunits(l.nonce)
    while (at = findfirst(nonce, buf)) !== nothing
        deleteat!(buf, at)
        l.asked || ask!(j, "sudo", "")
        l.asked = true
    end
    keep = 0
    for n in min(length(nonce) - 1, length(buf)):-1:1
        if view(buf, length(buf)-n+1:length(buf)) == view(nonce, 1:n)
            keep = n
            break
        end
    end
    l.held = buf[end-keep+1:end]
    return buf[1:end-keep]
end
function held_output!(l::SudoLaunch)
    rest = l.held
    l.held = UInt8[]
    return rest
end

# The askpass helper writes `kind\0prompt\0` and reads one line back.
function read_prompts(s::ProcessSupervisor, j::ManagedProcess, l::SshLaunch)
    io = l.input
    try
        while !eof(io)
            kind = String(readuntil(io, 0x00))
            text = String(readuntil(io, 0x00))
            lock(() -> ask!(j, kind == "confirm" ? "confirm" : "secret", text), s.lock)
        end
    catch e
        e isa Base.IOError || rethrow()   # the job ended and `finish!` closed it
    end
    return nothing
end

# One line, `+answer` or `-` for no. The helper exits 1 on `-`, so ssh moves on.
const SSH_ASKPASS_HELPER = raw"""#!/bin/sh
[ "$SSH_ASKPASS_PROMPT" = none ] && exit 0
printf '%s\000%s\000' "${SSH_ASKPASS_PROMPT:-secret}" "$1" >&0 || exit 1
IFS= read -r answer <&0 || exit 1
case $answer in
    +*) printf '%s\n' "${answer#+}" ;;
    *) exit 1 ;;
esac
"""

function askpass_helper(s::ProcessSupervisor)
    path = joinpath(s.directory, "askpass.sh")
    write(path, SSH_ASKPASS_HELPER)
    chmod(path, 0o700)
    return path
end

# sudo gets one answer: the socket closes behind the password, so a second prompt
# (a wrong password) reads EOF and sudo gives up instead of waiting.
function respond!(l::SudoLaunch, password::String)
    write(l.input, password, "\n")
    closewrite(l.input)
    return nothing
end
respond!(l::SudoLaunch, ::Nothing) = closewrite(l.input)
respond!(l::SshLaunch, answer::String) = (write(l.input, "+", answer, "\n"); nothing)
respond!(l::SshLaunch, ::Nothing) = (write(l.input, "-\n"); nothing)

"""
    answer_prompt!(supervisor, project, id, args)

Answer job `id`'s open prompt: `args["seq"]` names it, `args["secret"]` is the
answer, and `args["deny"] = true` refuses it.
"""
function answer_prompt!(s::ProcessSupervisor, project::AbstractString, id::AbstractString, args::AbstractDict)
    seq = get(args, "seq", nothing)
    seq isa Integer || throw(ArgumentError("an answer names its prompt's seq"))
    answer = get(args, "deny", false) === true ? nothing : String(get(args, "secret", ""))
    answer === nothing || !occursin(r"[\n\r\0]", answer) ||
        throw(ArgumentError("an answer is one line"))
    job = lock(s.lock) do
        j = get(s.jobs, process_key(project, id), nothing)
        j === nothing && throw(ArgumentError("no managed process '$id' in this chat"))
        prompt = j.record["prompt"]
        prompt !== nothing && prompt["seq"] == seq ||
            throw(ArgumentError("that question was answered already or its job ended"))
        respond!(j.launch, answer)
        j.record["prompt"] = nothing
        j.record["revision"] += 1
        save_process_jobs!(s)
        j
    end
    return publish_process!(s, job)
end

# ── Starting them ────────────────────────────────────────────────────────────

# The sudo to run: the one the worker's PATH finds, if it is setuid root. A user
# can't make such a file, so a `sudo` the agent put earlier on the PATH (in
# ~/.local/bin, say) is refused rather than handed the password. `configured` is
# the supervisor's own, which skips that check.
function sudo_program(configured::AbstractString)
    isempty(configured) || return String(configured)
    found = Sys.which("sudo")
    found === nothing && error("sudo is not installed on this worker")
    path = realpath(found)
    info = stat(path)
    info.uid == 0 && (info.mode & 0o4000) != 0 ||
        error("refusing $path: the sudo to run must be owned by root and setuid")
    return path
end

function start_sudo!(s::ProcessSupervisor, project::AbstractString, args::AbstractDict)
    argv = get(args, "argv", Any[])
    id = String(get(args, "id", ""))
    via = String(get(args, "ssh", ""))
    route = isempty(via) ? LocalSudo(sudo_program(s.sudo)) : ssh_route(s, project, via)
    return start_process!(s, project, argv; id, cwd = String(get(args, "cwd", "")),
        label = String(get(args, "label", id)), epoch = String(get(args, "epoch", "")),
        launch = SudoLaunch(route))
end

# The ready bt_ssh connection `via` of the same chat.
function ssh_route(s::ProcessSupervisor, project::AbstractString, via::AbstractString)
    return lock(s.lock) do
        j = get(s.jobs, process_key(project, via), nothing)
        j !== nothing && j.launch isa SshLaunch ||
            throw(ArgumentError("no bt_ssh connection '$via' in this chat"))
        j.record["status"] in PROCESS_ACTIVE && j.record["ready"] === true ||
            throw(ArgumentError("the bt_ssh connection '$via' is not open"))
        SshSudo(j.launch.ssh, j.launch.control_path, j.record["argv"][end], isempty(s.sudo) ? "sudo" : s.sudo)
    end
end

function start_ssh!(s::ProcessSupervisor, project::AbstractString, args::AbstractDict)
    destination = String(get(args, "destination", ""))
    occursin(r"^[^-\s][^\s]{0,255}$", destination) ||
        throw(ArgumentError("destination must be one ssh destination, such as user@host"))
    options = get(args, "options", Any[])
    options isa AbstractVector && all(o -> o isa AbstractString &&
        occursin(r"^[A-Za-z][A-Za-z0-9]*[= ][^\n\r\0]{1,500}$", o), options) ||
        throw(ArgumentError("options must be ssh options such as \"Port=2222\""))
    ssh = Sys.which("ssh")
    ssh === nothing && error("ssh is not installed on this worker")
    # A short path: a socket path is limited to about 100 bytes.
    control = joinpath(mktempdir(tempdir(); prefix = "bt-ssh-", cleanup = false), "master")
    argv = ["ssh"; [x for o in options for x in ("-o", String(o))]; "--"; destination]
    id = String(get(args, "id", ""))
    job = try
        start_process!(s, project, argv; id, cwd = String(get(args, "cwd", "")),
            label = String(get(args, "label", "ssh " * destination)), epoch = String(get(args, "epoch", "")),
            launch = SshLaunch(ssh, askpass_helper(s), control, nothing))
    catch
        rm(dirname(control); recursive = true, force = true)
        rethrow()
    end
    # A repeated id returns the job it started before; a failed start has no master.
    (job["control_path"] != control || job["status"] == "failed") &&
        rm(dirname(control); recursive = true, force = true)
    return job
end
