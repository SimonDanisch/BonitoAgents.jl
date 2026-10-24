# Manual Windows probe — run from an INTERACTIVE terminal:
#
#     julia --project=Jail Jail/test/manual_win_probe.jl
#
# (or, from the repo root with the Jail env active, `include` this file.)
#
# Why manual: Sandboxie attaches boxed *console* processes to the launcher's
# console session. When launched from a non-interactive/headless parent (e.g.
# an automation harness) there is no console session, so Sandboxie fails with
# SBIE2205 / STATUS_NOT_SAME_DEVICE (C00000D4) and the boxed console child never
# runs. From a real terminal that attach should succeed. This script exercises
# the real `jail()` and reports whether the whitelist is enforced.

using Jail

work    = mktempdir()
outside = mktempdir()
src     = joinpath(work, "src.txt"); write(src, "seed\n")
ok      = joinpath(work,    "ok.txt")
evil    = joinpath(outside, "evil.txt")

println("whitelist work dir : ", work)
println("outside dir        : ", outside)

# Write INSIDE the whitelist — should reach the host.
run(jail(Cmd(["cmd", "/c", "copy \"$src\" \"$ok\""]); whitelist = [work]))
inside_ok = isfile(ok)
println("inside-whitelist write landed on host?  ", inside_ok, inside_ok ? "  (PASS)" : "  (FAIL)")

# Write OUTSIDE the whitelist — Sandboxie should redirect it into the box, so
# the host path stays absent.
copied = success(jail(Cmd(["cmd", "/c", "copy \"$src\" \"$evil\""]); whitelist = [work]))
println("copy outside the whitelist reported success? ", copied)
outside_blocked = !isfile(evil)
println("outside-whitelist write blocked on host? ", outside_blocked, outside_blocked ? "  (PASS)" : "  (FAIL)")

rm(work;    recursive = true, force = true)
rm(outside; recursive = true, force = true)

println(inside_ok && outside_blocked ?
        "\nRESULT: jail() works end-to-end from this terminal." :
        "\nRESULT: still blocked here — console attach likely failing even interactively.")
