# A Bash call is a live background task only if its RESULT is Claude Code's launch
# sentence. On 11-27 a foreground command that printed old chat logs (which
# quoted such a sentence) went into the taskbar as a running background shell and
# stayed there until the session ended.
@testitem "unit:bg_launch_result" tags = [:unit] begin
    import BonitoAgents as BT
    import AgentClientProtocol as ACP
    texts(xs...) = ACP.ToolContent[ACP.TextContent(x) for x in xs]

    # The result of a real launch (AgentClientProtocol/test/fixtures/real_stop_orphan_wire.jsonl).
    out = "/tmp/claude-1000/-tmp-recap-qHNFKD/188ee18c-2cb9-405e-a26c-38190c4c436e/tasks/b1fzuzp65.output"
    launch = "```console\nCommand running in background with ID: b1fzuzp65. Output is being written to: " *
             "$out. You will be notified when it completes. To check interim output, use Read on that file path.\n```"
    @test BT.parse_bg_output_path(texts(launch)) == out          # the sentence's period is not the path's
    @test BT.parse_bg_output_path(texts("Command running in background with ID: x1. Output is being written to: /tmp/x1.output")) ==
          "/tmp/x1.output"

    # A foreground command whose output quotes a launch is not one.
    printed = "----- 2026-07-14T20:50:26\nCMD: grep -r background chats/\n" * launch
    @test BT.parse_bg_output_path(texts(printed)) === nothing
    @test BT.parse_bg_output_path(texts("log line: Output is being written to: /tmp/a.log")) === nothing
    @test BT.parse_bg_output_path(texts("total 8\n", "drwxr-xr-x 2 u u 4096 .")) === nothing
    @test BT.parse_bg_output_path(ACP.ToolContent[]) === nothing
end
