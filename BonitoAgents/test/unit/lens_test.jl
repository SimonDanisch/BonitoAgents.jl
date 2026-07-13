@testitem "unit:lens" tags = [:unit] begin

# Lens search core: grammar parsing, per-message keys/text, fuzzy filtering,
# vocabulary, and saved-lens persistence. Pure headless — no Electron/worker.
using Test
using BonitoAgents
const BT = BonitoAgents

@testset "lens search" begin
    @testset "parse: clauses, key, action, query" begin
        cs = BT.parse_lens("/user_message \"search string\" + /bt_show_app: expand")
        @test length(cs) == 2
        @test cs[1].key == "user_message"
        @test cs[1].action === nothing
        @test cs[1].query == "search string"
        @test cs[2].key == "bt_show_app"
        @test cs[2].action == "expand"
        @test cs[2].query === nothing

        # Bare (unquoted) query runs to end of clause.
        c = only(BT.parse_lens("/agent raytracer perf"))
        @test c.key == "agent" && c.query == "raytracer perf"

        # `+` inside a quoted query does NOT split.
        cs2 = BT.parse_lens("""/user "a + b" + /tools""")
        @test length(cs2) == 2
        @test cs2[1].query == "a + b"
        @test cs2[2].key == "tools"

        @test isempty(BT.parse_lens("   "))
    end

    @testset "key subsequence matching (bt_eval ⊆ bt_julia_eval)" begin
        @test BT.subseq_match("bt_eval", "bt_julia_eval")
        @test BT.subseq_match("usr", "user_message")
        @test !BT.subseq_match("xyz", "user_message")
        @test BT.subseq_match("", "anything")
    end

    @testset "fuzzy text match: exact substring + typo/reorder" begin
        body = "start a background resource monitor for cpu and memory"
        @test BT.lens_text_match("monitor", body)            # exact substring
        @test BT.lens_text_match("resource monitor", body)   # substring phrase
        @test BT.lens_text_match("monitor resource", body)   # reordered → fuzzy
        @test !BT.lens_text_match("lissajous", body)         # unrelated
    end

    @testset "apply_lens: union of clauses + per-index actions" begin
        U  = BT.UserMsg("please start a resource monitor")
        A  = BT.AgentMsg("a1", "here is the monitor")
        app = BT.BonitoAppMsg("app1","bonito_app","Dashboard","completed","",
                              time(),time(),"","",nothing)
        U2 = BT.UserMsg("show me the lissajous plot")
        bash = BT.BashToolMsg("b1","execute","loop","completed","",time(),nothing,
                              "sleep 9","Monitor",true,"/tmp/x",0,"",nothing)
        msgs = Any[U, A, app, U2, bash]

        vis, acts = BT.apply_lens(msgs, BT.parse_lens(
            "/user_message \"monitor\" + /bt_show_app: expand"))
        @test vis == [0, 2]                  # U matches "monitor"; app shown
        @test acts == Dict(2 => "expand")    # app expanded; U has no action
        @test 3 ∉ vis                        # lissajous user msg hidden

        # `/tools` matches every tool (the app + the bash).
        vis2, _ = BT.apply_lens(msgs, BT.parse_lens("/tools"))
        @test sort(vis2) == [2, 4]

        # Empty lens shows everything.
        vis3, _ = BT.apply_lens(msgs, BT.LensClause[])
        @test vis3 == collect(0:4)
    end

    @testset "signed clauses: include / exclude / wildcard / base rule" begin
        U  = BT.UserMsg("please start a resource monitor")
        A  = BT.AgentMsg("a1", "here is the monitor")
        app = BT.BonitoAppMsg("app1","bonito_app","Dashboard","completed","",
                              time(),time(),"","",nothing)
        U2 = BT.UserMsg("show me the lissajous plot")
        bash = BT.BashToolMsg("b1","execute","loop","completed","",time(),nothing,
                              "sleep 9","Monitor",true,"/tmp/x",0,"",nothing)
        Th = BT.ThoughtMsg("t1","thinking about monitors")
        msgs = Any[U, A, app, U2, bash, Th]      # 0:U 1:A 2:app 3:U2 4:bash 5:Th

        # A bare positive clause is already exclusive.
        @test BT.apply_lens(msgs, BT.parse_lens("/bt_show_app"))[1] == [2]

        # `+` unions includes.
        @test sort(BT.apply_lens(msgs, BT.parse_lens("/user_message + /agent"))[1]) == [0,1,3]

        # Exclude-only ⇒ base is ALL minus the excluded type (`!` and ` - ` forms).
        @test sort(BT.apply_lens(msgs, BT.parse_lens("!/thought"))[1])   == [0,1,2,3,4]
        @test sort(BT.apply_lens(msgs, BT.parse_lens("/all - /Bash"))[1]) == [0,1,2,3,5]

        # Include base minus an exclude: tools = app+bash, minus bash ⇒ app.
        @test BT.apply_lens(msgs, BT.parse_lens("/tools - /Bash"))[1] == [2]

        # Action keyword (no `:`), and action on a clause among matches.
        vis, acts = BT.apply_lens(msgs, BT.parse_lens("/tools collapse - /Bash"))
        @test vis == [2] && acts == Dict(2 => "collapse")

        # An action on an EXCLUDE clause is irrelevant (excluded = hidden).
        @test sort(BT.apply_lens(msgs, BT.parse_lens("!/Bash collapse"))[1]) == [0,1,2,3,5]

        # Bare text (no `/`) = full-text fuzzy across ALL message types.
        @test sort(BT.apply_lens(msgs, BT.parse_lens("monitor"))[1]) == [0,1,4,5]

        # Quoted query + expand + subsequence key match ("dash" ⊆ "Dashboard").
        vis2, acts2 = BT.apply_lens(msgs, BT.parse_lens("/bt_show_app expand \"dash\""))
        @test vis2 == [2] && acts2 == Dict(2 => "expand")
    end

    @testset "parse: signs, wildcard, optional colon, full-text" begin
        c = only(BT.parse_lens("!/thought"))
        @test c.sign === :exclude && c.key == "thought"
        c = only(BT.parse_lens("/bt_show_app: expand"))   # colon still accepted
        @test c.key == "bt_show_app" && c.action == "expand"
        c = only(BT.parse_lens("/bt_show_app expand"))     # colon optional
        @test c.key == "bt_show_app" && c.action == "expand"
        cs = BT.parse_lens("/all - /Bash")
        @test cs[1].sign === :include && cs[1].key == "all"
        @test cs[2].sign === :exclude && cs[2].key == "Bash"
        c = only(BT.parse_lens("monitor"))                 # no slash ⇒ empty key
        @test c.key == "" && c.query == "monitor"
        # `all` is always in the vocabulary (wildcard for `/all - /x`).
        @test "all" in BT.lens_vocabulary(Any[BT.UserMsg("hi")])
    end

    @testset "vocabulary = keys present in the chat" begin
        msgs = Any[BT.UserMsg("hi"),
                   BT.BonitoAppMsg("a","bonito_app","D","completed","",time(),time(),"","",nothing)]
        vocab = BT.lens_vocabulary(msgs)
        @test "user_message" in vocab
        @test "bt_show_app" in vocab
        @test "tools" in vocab
        @test !("thought" in vocab)          # no thoughts in this chat
    end

    @testset "saved lenses: save (dedup) / load / delete, global file" begin
        mktempdir() do dir
            withenv("BONITOAGENTS_LENSES_PATH" => joinpath(dir, "lenses.json")) do
                @test isempty(BT.load_saved_lenses())
                BT.save_lens!("/tools \"eval\"")
                BT.save_lens!("/bt_show_app: expand")
                BT.save_lens!("/tools \"eval\"")          # duplicate → ignored
                ls = BT.load_saved_lenses()
                @test length(ls) == 2
                @test all(l -> !isempty(l.title) && startswith(l.color, "hsl("), ls)
                # Stable color: same query → same color across reload.
                @test BT.lens_color("/tools \"eval\"") == ls[1].color

                BT.delete_saved_lens!("/tools \"eval\"")
                @test length(BT.load_saved_lenses()) == 1
            end
        end
    end
end

end
