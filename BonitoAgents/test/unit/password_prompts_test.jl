@testitem "unit:password_prompts" tags=[:unit] begin
    using BonitoWorker
    import Sockets
    const BW = BonitoWorker
    if Sys.isunix()
        dir = mktempdir()
        # Stands in for `sudo -S -k -- command...`: the prompt from SUDO_PROMPT on
        # stderr, one line of password on stdin, then the command. It leaves a mark
        # first, and a password goes out only once that is there (`sudo_asked`): a
        # real sudo must never get a test password.
        fake = joinpath(dir, "sudo")
        ran = fake * ".ran"
        write(fake, raw"""#!/bin/sh
: > "$0.ran"
[ "$1" = -S ] && [ "$2" = -k ] && [ "$3" = -- ] || exit 90
shift 3
printf '%s' "$SUDO_PROMPT" >&2
IFS= read -r pw || { echo "sudo: no password was provided" >&2; exit 1; }
[ "$pw" = letmein ] || { echo "Sorry, try again." >&2; exit 1; }
exec "$@"
""")
        chmod(fake, 0o755)
        s = BW.ProcessSupervisor(joinpath(dir, "logs"); sudo = fake)
        s.monitor = @async BW.monitor_processes!(s)
        request(pairs...) = BW.managed_process_request(s, "chat-a", Dict{String,Any}(pairs...))
        status(id) = request("action" => "status", "id" => id)
        until(id, f) = timedwait(() -> f(status(id)), 15.0; pollint = 0.05) === :ok
        asked(id) = until(id, d -> d["prompt"] !== nothing) ? status(id)["prompt"] : nothing
        answer(id, seq, pairs...) = request("action" => "answer", "id" => id, "seq" => seq, pairs...)
        function sudo_asked(id)
            p = asked(id)
            isfile(ran) || error("the stand-in sudo didn't run for '$id', so no password is sent")
            return p
        end
        function sudo(id; kw...)
            rm(ran; force = true)
            return request("action" => "sudo", "id" => id, "cwd" => dir,
                           "argv" => ["sh", "-c", "echo ran; cat; echo input-closed"], (string(k) => v for (k, v) in kw)...)
        end
        try
            @testset "sudo gets the password once, from the worker" begin
                sudo("right")
                p = sudo_asked("right")
                @test p["kind"] == "sudo"
                @test status("right")["kind"] == "sudo"
                @test_throws ArgumentError answer("right", p["seq"] + 1, "secret" => "letmein")
                @test_throws ArgumentError answer("right", p["seq"], "secret" => "two\nlines")
                answer("right", p["seq"], "secret" => "letmein")
                @test until("right", d -> d["status"] == "succeeded")
                # The prompt is not in the output, and the input ends behind the password.
                @test status("right")["output"] == "ran\ninput-closed\n"
                @test status("right")["prompt"] === nothing
                @test_throws ArgumentError answer("right", p["seq"], "secret" => "letmein")

                sudo("wrong")
                answer("wrong", sudo_asked("wrong")["seq"], "secret" => "nope")
                @test until("wrong", d -> d["status"] == "failed")
                @test occursin("Sorry", status("wrong")["output"])

                sudo("refused")
                answer("refused", sudo_asked("refused")["seq"], "deny" => true)
                @test until("refused", d -> d["status"] == "failed")
                @test occursin("no password", status("refused")["output"])
            end

            @testset "nothing of the agent's reaches sudo" begin
                @test_throws ArgumentError BW.start_process!(s, "chat-a", ["true"]; id = "with-env", cwd = dir,
                    label = "env", env = Dict("BASH_ENV" => joinpath(dir, "evil.sh")), launch = BW.SudoLaunch(BW.LocalSudo(fake)))
                # A sudo earlier on the PATH that isn't setuid root is refused.
                @test_throws ErrorException withenv(() -> BW.sudo_program(""), "PATH" => dir * ":" * ENV["PATH"])
                if Sys.islinux()
                    # Another process of the user can open a job's input pipe through
                    # /proc and read the password first. A socket can't be opened there.
                    sudo("held")
                    p = sudo_asked("held")
                    @test_throws SystemError open("/proc/$(status("held")["pid"])/fd/0")
                    answer("held", p["seq"], "deny" => true)
                    @test until("held", d -> d["status"] == "failed")
                end
            end

            sshd = something(Sys.which("sshd"), isfile("/usr/sbin/sshd") ? "/usr/sbin/sshd" : nothing, Some(nothing))
            if sshd !== nothing && Sys.which("ssh-keygen") !== nothing
                @testset "ssh asks through the worker and keeps a master" begin
                    keys = mktempdir()
                    run(pipeline(`ssh-keygen -q -t ed25519 -N "" -f $keys/host_key`; stdout = devnull))
                    run(pipeline(`ssh-keygen -q -t ed25519 -N "hunter2" -f $keys/user_key`; stdout = devnull))
                    cp("$keys/user_key.pub", "$keys/authorized_keys")
                    port = let l = Sockets.listen(Sockets.IPv4(0x7f000001), 0)
                        p = Int(Sockets.getsockname(l)[2]); close(l); p
                    end
                    write("$keys/sshd_config", """
                        Port $port
                        ListenAddress 127.0.0.1
                        HostKey $keys/host_key
                        AuthorizedKeysFile $keys/authorized_keys
                        PidFile none
                        UsePAM no
                        StrictModes no
                        PasswordAuthentication no
                        KbdInteractiveAuthentication no
                        """)
                    daemon = run(pipeline(`$sshd -D -e -f $keys/sshd_config`; stdout = devnull, stderr = devnull); wait = false)
                    ssh(id) = request("action" => "ssh", "id" => id, "cwd" => dir, "destination" => "127.0.0.1",
                        "options" => ["Port=$port", "IdentityFile=$keys/user_key", "IdentitiesOnly=yes",
                                      "UserKnownHostsFile=$keys/known_hosts"])
                    try
                        listening() = try
                            close(Sockets.connect(Sockets.IPv4(0x7f000001), port)); true
                        catch e
                            e isa Base.IOError || rethrow(); false
                        end
                        @test timedwait(listening, 10.0) === :ok
                        job = ssh("master")
                        @test job["argv"][end] == "127.0.0.1"
                        control = job["control_path"]
                        hostkey = asked("master")
                        @test hostkey["kind"] == "secret"
                        @test occursin("authenticity of host", hostkey["text"])
                        answer("master", hostkey["seq"], "secret" => "yes")
                        @test until("master", d -> d["prompt"] !== nothing && d["prompt"]["seq"] > hostkey["seq"])
                        passphrase = status("master")["prompt"]
                        @test occursin("passphrase", passphrase["text"])
                        answer("master", passphrase["seq"], "secret" => "hunter2")
                        @test until("master", d -> d["ready"] === true)
                        @test readchomp(`ssh -S $control -o Port=$port 127.0.0.1 echo through-the-master`) == "through-the-master"
                        @test ssh("master")["pid"] == job["pid"]          # a repeated id is the same job

                        # sudo on the host, through the connection: the supervisor's
                        # stand-in there too, by its path.
                        remote(id) = sudo(id; ssh = "master")
                        remote("remote-right")
                        p = sudo_asked("remote-right")
                        @test p["kind"] == "sudo"
                        @test status("remote-right")["host"] == "127.0.0.1"
                        answer("remote-right", p["seq"], "secret" => "letmein")
                        @test until("remote-right", d -> d["status"] == "succeeded")
                        @test status("remote-right")["output"] == "ran\ninput-closed\n"
                        remote("remote-refused")
                        answer("remote-refused", sudo_asked("remote-refused")["seq"], "deny" => true)
                        @test until("remote-refused", d -> d["status"] == "failed")
                        @test occursin("no password", status("remote-refused")["output"])
                        @test_throws ArgumentError request("action" => "sudo", "id" => "nowhere", "cwd" => dir,
                                                           "ssh" => "no-such-connection", "argv" => ["true"])
                        BW.signal_process!(s, "chat-a", "master", "terminate")
                        @test until("master", d -> !(d["status"] in BW.PROCESS_ACTIVE))
                        @test !ispath(dirname(control))

                        ssh("ssh-refused")
                        answer("ssh-refused", asked("ssh-refused")["seq"], "deny" => true)
                        @test until("ssh-refused", d -> d["status"] == "failed")
                        @test occursin("Permission denied", status("ssh-refused")["output"])
                        @test_throws ArgumentError request("action" => "ssh", "id" => "flag", "cwd" => dir,
                            "destination" => "-oProxyCommand=sh")
                    finally
                        kill(daemon)
                    end
                end
            end
        finally
            s.closed = true
            BW.close_process_jobs!(s)
        end
    end
end

@testitem "unit:password_prompt_cards" tags=[:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    project = BT.ProjectInfo("prompts", "prompts", "worker", mktempdir(), "/worker/project", BT.now(BT.UTC))
    state.projects[][project.id] = project
    BT.save_projects!(state)
    @test isempty(BT.prompt_cards(state, project.id))     # no book yet, and none is made
    @test !isfile(joinpath(state.state_dir, "chats", project.id, "process_jobs.json"))
    frame(revision, prompt; status = "running") = Dict{String,Any}("project_id" => project.id, "id" => "root-1",
        "epoch" => BT.managed_process_epoch(state, project.id), "status" => status, "revision" => revision,
        "output_bytes" => 0, "output" => "", "started" => time(), "label" => "Install", "pid" => 4242,
        "argv" => ["zypper", "install", "ripgrep"], "cwd" => "/worker/project", "exitcode" => nothing,
        "kind" => "sudo", "prompt" => prompt)
    BT.managed_process_update!(state, "worker", frame(1, nothing))
    @test isempty(BT.prompt_cards(state, project.id))
    BT.managed_process_update!(state, "worker", frame(2, Dict("seq" => 1, "kind" => "sudo", "text" => "")))
    cards = BT.prompt_cards(state, project.id)
    @test length(cards) == 1
    @test only(cards)["key"] == "managed:worker:root-1#1"
    @test only(cards)["job"] == "zypper install ripgrep"
    @test only(cards)["cwd"] == "/worker/project"
    # A job that ended has nothing left to ask.
    BT.managed_process_update!(state, "worker", frame(3, Dict("seq" => 1, "kind" => "sudo", "text" => ""); status = "failed"))
    @test isempty(BT.prompt_cards(state, project.id))
    # The agent can't answer its own prompt.
    @test_throws ErrorException BT.process_request(state, project.id,
        Dict("action" => "answer", "id" => "root-1", "seq" => 1, "secret" => "guess"))
end
