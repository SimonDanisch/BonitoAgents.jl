# The line diff behind an edit's static diff view (`diff_ops`, code_view.jl):
# applied to the old lines it gives the new ones, and it is a SHORTEST script,
# checked against a brute-force LCS on random texts.
@testitem "unit:code_view_diff" tags = [:unit] begin
    using Test
    using BonitoAgents
    using Random
    const BT = BonitoAgents

    function apply_ops(old, new, ops)
        a, b = BT.code_lines(old), BT.code_lines(new)
        out = String[]
        i = j = 1
        for op in split(ops)
            k, n = op[1], parse(Int, op[2:end])
            if k == '='
                for _ in 1:n
                    a[i] == b[j] || return nothing
                    push!(out, a[i]); i += 1; j += 1
                end
            elseif k == '-'
                i += n
            else
                for _ in 1:n
                    push!(out, b[j]); j += 1
                end
            end
        end
        (i == length(a) + 1 && j == length(b) + 1) || return nothing
        return out
    end
    function lcs(a, b)
        L = zeros(Int, length(a) + 1, length(b) + 1)
        for i in eachindex(a), j in eachindex(b)
            L[i + 1, j + 1] = a[i] == b[j] ? L[i, j] + 1 : max(L[i, j + 1], L[i + 1, j])
        end
        return L[end, end]
    end
    changed(ops) = sum((parse(Int, op[2:end]) for op in split(ops) if op[1] != '='); init = 0)

    rng = Xoshiro(20261020)
    for _ in 1:2000
        old = join(rand(rng, ["a", "b", "c", "d", ""], rand(rng, 0:12)), "\n")
        new = join(rand(rng, ["a", "b", "c", "d", ""], rand(rng, 0:12)), "\n")
        ops = BT.diff_ops(old, new)
        @test apply_ops(old, new, ops) == BT.code_lines(new)
        la, lb = BT.code_lines(old), BT.code_lines(new)
        @test changed(ops) == length(la) + length(lb) - 2 * lcs(la, lb)
    end

    @test BT.diff_ops("a\nb\nc", "a\nx\nc") == "=1 -1 +1 =1"
    @test BT.diff_ops("", "x\ny") == "+2"                  # a new file: additions only
    @test BT.diff_ops("x\ny", "") == "-2"
    @test BT.diff_ops("same", "same") == "=1"
    @test BT.diff_ops("a\nb\n", "a\nb\nc\n") == "=2 +1 =1"  # the trailing newline's empty line
    # Past `max_d` differences the changed middle is all removed, then all added.
    @test BT.diff_ops(join(1:20, "\n"), join(21:40, "\n"); max_d = 3) == "-20 +20"
    @test BT.diff_counts("=3 -2 +4 =1") == (2, 4)
    @test BT.diff_counts(BT.DiffView("a\nb", "a\nc\nd")) == (1, 2)
end
