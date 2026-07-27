# The bail test used to require the whole reply to be exactly "no", so an agent
# answering "No, everything is done." kept getting re-prompted.
@testitem "unit:yolo_bail" tags = [:unit] begin
    B = BonitoAgents.yolo_bail

    @testset "declines that must stop the loop" begin
        for reply in ("no", "No", "NO", "No.", "no!", "  No.  ", "No...",
                      "**No**", "> No.",
                      "No, everything is done.",          # the reported miss
                      "No.\n\nThe tests pass and the branch is pushed.",
                      "No — there's nothing left I can do on my own.")
            @test B(reply)
        end
    end

    @testset "replies that must NOT stop the loop" begin
        for reply in ("Not quite — I'll keep going.",      # `\b` guards this
                      "Nothing is broken, continuing.",
                      "Now running the tests.",
                      "yes",
                      "I still need to update the docs.",
                      "There is more to do: the sidebar work is unfinished.",
                      "")
            @test !B(reply)
        end
    end

    @testset "the old exact-match rule was the bug" begin
        old(t) = strip(replace(lowercase(strip(t)), r"[.!]+$" => "")) == "no"
        for reply in ("No, everything is done.", "No.\n\nThe tests pass.", "**No**")
            @test !old(reply)      # old said "keep going"
            @test B(reply)         # new correctly bails
        end
    end
end
