#!/usr/bin/env bash
#
# Post-process an AppBundler macOS `tarball` bundle so it actually launches on
# end-user Macs. Two defects make the raw bundle un-runnable on a stock Mac:
#
#  1. Broken code signatures (SIGKILL "Code Signature Invalid / Invalid Page").
#     AppBundler only signs the DMG/MSIX targets — the `tarball` target ships
#     with whatever signature state the relocatable-ification (rpath rewriting
#     etc.) left the bundled Mach-O binaries in. Those signatures pass a static
#     `codesign --verify` but FAIL macOS's *runtime* page validation, so the
#     bundled `julia` is SIGKILLed at launch with no output. Re-signing every
#     Mach-O ad-hoc (`codesign --force --sign -`) recomputes the code hashes
#     from the shipped bytes and drops hardened-runtime library validation,
#     which makes them run. install.sh already strips the com.apple.quarantine
#     xattr, so ad-hoc signatures are sufficient (no notarization needed).
#
#  2. Missing REPL precompile helper. Julia's REPL stdlib precompile workload
#     `include`s share/julia/test/testhelpers/FakePTYs.jl. A bundle whose
#     share/julia/test was stripped cannot precompile REPL on first launch, so
#     the whole app dependency chain fails to precompile. We restore it from the
#     toolchain Julia on PATH when it's absent (no-op when it's present).
#
# The ad-hoc signing is the real fix; the notarized/Developer-ID path would be
# better long-term but needs Apple signing secrets in CI. Both fixes are also
# arguably AppBundler's job (SimonDanisch/AppBundler.jl) — this is the in-repo
# workaround until the tarball target learns to sign + keep the test helpers.
#
# Usage: macos-fix-bundle.sh <bundle.tar.gz>   (run on macOS; edits in place)
set -euo pipefail

tarball="${1:?usage: macos-fix-bundle.sh <bundle.tar.gz>}"
[ -f "$tarball" ] || { echo "error: no such tarball: $tarball" >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "error: codesign not found (run on macOS)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Extracting $(basename "$tarball")"
tar -xzf "$tarball" -C "$work"

# TarPack guarantees a single top-level folder inside the archive.
bundle="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "$bundle" ] && [ -x "$bundle/bin/julia" ] \
    || { echo "error: no bin/julia inside the tarball" >&2; exit 1; }
echo "==> Bundle: $(basename "$bundle")"

# ── 1) Restore Julia's REPL precompile test helpers if stripped ───────────────
testdir="$bundle/share/julia/test"
if [ -e "$testdir/testhelpers/FakePTYs.jl" ]; then
    echo "==> share/julia/test present — no restore needed"
else
    ref="$(julia --startup-file=no -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia", "test"))' 2>/dev/null || true)"
    if [ -n "$ref" ] && [ -d "$ref" ]; then
        echo "==> Restoring share/julia/test from toolchain Julia ($ref)"
        rm -rf "$testdir"
        mkdir -p "$(dirname "$testdir")"
        cp -R "$ref" "$testdir"
    else
        echo "WARNING: share/julia/test missing and no reference Julia on PATH;" >&2
        echo "         REPL precompile may fail on first launch." >&2
    fi
fi

# ── 2) Ad-hoc re-sign every Mach-O binary ─────────────────────────────────────
# Shared libraries (.dylib / .so): sign all of them EXCEPT the pkgimage caches
# under compiled/ — those are content-validated by Julia; re-signing them would
# invalidate the cache and force a recompile on first launch. `-type f` skips
# the version/ABI symlink aliases (we sign the real files only).
echo "==> Ad-hoc signing shared libraries"
find "$bundle" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' \) \
    ! -path '*/compiled/*' -print0 \
    | xargs -0 -P4 -n16 codesign --force --sign -

# Mach-O executables without a lib extension (the Julia launcher binary + any
# artifact/helper executables). Scan only the dirs that hold them and filter to
# real Mach-O so we skip the shell launcher script.
echo "==> Ad-hoc signing executables"
for d in "$bundle/bin" "$bundle/libexec" "$bundle"/share/julia/artifacts/*/bin; do
    [ -d "$d" ] || continue
    find "$d" -type f -perm +111 ! -name '*.dylib' ! -name '*.so' ! -name '*.so.*' -print0
done | while IFS= read -r -d '' f; do
    case "$(file -b "$f" 2>/dev/null)" in
        Mach-O*) codesign --force --sign - "$f" ;;
    esac
done

# ── 3) Smoke test: the bundled Julia must actually run now ─────────────────────
echo "==> Smoke test: launching the re-signed bundle Julia"
"$bundle/bin/julia" --startup-file=no -e 'print("    bundle julia OK: "); println(VERSION)'

# ── 4) Repack in place, preserving the single top-level folder ─────────────────
echo "==> Repacking $(basename "$tarball")"
rm -f "$tarball"
tar -czf "$tarball" -C "$(dirname "$bundle")" "$(basename "$bundle")"
echo "==> Done."
