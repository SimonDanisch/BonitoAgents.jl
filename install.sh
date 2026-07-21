#!/bin/sh
# BonitoAgents desktop installer (Linux and macOS).
#
#   curl -fsSL https://agents.bonito.sh/install.sh | sh
#
# Downloads the prebuilt release bundle for this machine, installs it under the
# user's data dir (no sudo), exposes a `bonito-agents` command, and starts the
# desktop app: a local dashboard server + a worker for this machine, opened in
# your browser. Re-run any time to auto-update to the latest release; it skips
# the download when you are already on the newest version.
#
# Per-user state (chats, projects, depot cache) lives under the platform data
# dir and is NEVER touched by install/update/uninstall:
#   Linux:  ~/.local/share/BonitoAgents
#   macOS:  ~/Library/Application Support/BonitoAgents
#
# Options (after `| sh -s --`):
#   --no-run        install/update only; do not start the app afterwards
#   --force         reinstall even if already on the latest version
#   --uninstall     remove the app + command (per-user state is left intact)
#   --prefix DIR    install location (default: platform data dir/BonitoAgents-app)
#   --bin-dir DIR   where to place the launcher symlink (default: ~/.local/bin)
#   -h, --help      show this help
#
# Env overrides:
#   BONITOAGENTS_REPO      owner/name of the releases repo
#   BONITOAGENTS_RELEASE   release tag to install, or "latest" (default)
#   BONITOAGENTS_TARBALL   install a local *.tar.gz instead of downloading (for testing)
set -eu

REPO="${BONITOAGENTS_REPO:-SimonDanisch/BonitoAgents.jl}"
RELEASE="${BONITOAGENTS_RELEASE:-latest}"
APP_NAME="bonitoagents"           # name of the launcher inside the bundle
CMD_NAME="bonito-agents"          # the command we put on PATH

DO_RUN=1
DO_UNINSTALL=0
FORCE=0
PREFIX=""
BIN_DIR=""

say()  { printf '%s\n' "$*"; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
BonitoAgents desktop installer (Linux and macOS).

  curl -fsSL https://agents.bonito.sh/install.sh | sh

Downloads the prebuilt release bundle for this machine, installs it under the
user's data dir (no sudo), exposes a `bonito-agents` command, and starts the
desktop app (local server + worker + dashboard in your browser). Re-run to
auto-update to the latest release.

Options (after `| sh -s --`):
  --no-run        install/update only; do not start the app afterwards
  --force         reinstall even if already on the latest version
  --uninstall     remove the app + command (per-user state is left intact)
  --prefix DIR    install location (default: <data dir>/BonitoAgents-app)
  --bin-dir DIR   where to place the launcher symlink (default: ~/.local/bin)
  -h, --help      show this help

Env overrides: BONITOAGENTS_REPO, BONITOAGENTS_RELEASE (tag or "latest"),
BONITOAGENTS_TARBALL (install a local *.tar.gz instead of downloading).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-run)     DO_RUN=0; shift ;;
        --force)      FORCE=1; shift ;;
        --uninstall)  DO_UNINSTALL=1; shift ;;
        --prefix)     PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --prefix=*)   PREFIX="${1#*=}"; shift ;;
        --bin-dir)    BIN_DIR="${2:?--bin-dir needs a value}"; shift 2 ;;
        --bin-dir=*)  BIN_DIR="${1#*=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# ── Platform detection ────────────────────────────────────────────────────────
os="$(uname -s)"
arch="$(uname -m)"
case "$arch" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported architecture: $arch (need x86_64 or aarch64)" ;;
esac
case "$os" in
    Linux)  osname=linux; DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}" ;;
    Darwin) osname=macos; DATA_HOME="$HOME/Library/Application Support" ;;
    *) die "unsupported OS: $os. On Windows use install.ps1 (see the README)." ;;
esac

# Install dir is DISTINCT from the app's own state dir ("$DATA_HOME/BonitoAgents"),
# so wiping/replacing the app never touches chats or projects.
: "${PREFIX:=$DATA_HOME/BonitoAgents-app}"
: "${BIN_DIR:=$HOME/.local/bin}"
LAUNCHER="$PREFIX/bin/$APP_NAME"
REL_MARK="$PREFIX/.release"        # records the release tag we installed

# ── Uninstall ─────────────────────────────────────────────────────────────────
if [ "$DO_UNINSTALL" -eq 1 ]; then
    info "Removing BonitoAgents from $PREFIX"
    rm -rf "$PREFIX"
    rm -f "$BIN_DIR/$CMD_NAME" "$BIN_DIR/$APP_NAME"
    rm -f "$DATA_HOME/applications/$CMD_NAME.desktop"
    rm -f "$DATA_HOME/icons/hicolor/512x512/apps/$CMD_NAME.png"
    say "Done. (Per-user state under $DATA_HOME/BonitoAgents was left intact.)"
    exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve the newest release tag by following GitHub's /releases/latest redirect
# (tokenless, version-free). Prints the tag on success; empty on failure.
resolve_latest_tag() {
    have curl || return 0
    eff="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
           "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
    case "$eff" in
        */tag/*) printf '%s' "${eff##*/tag/}" ;;
        *) : ;;   # no tag in the URL — leave empty, caller falls back to reinstall
    esac
}

# ── Resolve the target version + download URL ─────────────────────────────────
asset="bonitoagents-${osname}-${arch}.tar.gz"
if [ -n "${BONITOAGENTS_TARBALL:-}" ]; then
    TARGET_TAG="local"
elif [ "$RELEASE" = "latest" ]; then
    TARGET_TAG="$(resolve_latest_tag)"
    url="https://github.com/$REPO/releases/latest/download/$asset"
else
    TARGET_TAG="$RELEASE"
    url="https://github.com/$REPO/releases/download/$RELEASE/$asset"
fi

# ── Already up to date? ───────────────────────────────────────────────────────
installed_tag=""
[ -f "$REL_MARK" ] && installed_tag="$(cat "$REL_MARK" 2>/dev/null || true)"

if [ "$FORCE" -eq 0 ] && [ -x "$LAUNCHER" ] && [ -n "$TARGET_TAG" ] && \
   [ "$TARGET_TAG" != "local" ] && [ "$installed_tag" = "$TARGET_TAG" ]; then
    info "BonitoAgents $installed_tag is already up to date."
else
    # ── Download ──────────────────────────────────────────────────────────────
    stage_parent="$(dirname "$PREFIX")"
    mkdir -p "$stage_parent"
    stage="$stage_parent/.bonitoagents-stage.$$"
    tarball="$stage_parent/.bonitoagents-dl.$$.tar.gz"
    rm -rf "$stage" "$tarball"
    # shellcheck disable=SC2064
    trap "rm -rf '$stage' '$tarball'" EXIT INT TERM

    if [ -n "${BONITOAGENTS_TARBALL:-}" ]; then
        info "Using local bundle: $BONITOAGENTS_TARBALL"
        [ -f "$BONITOAGENTS_TARBALL" ] || die "no such file: $BONITOAGENTS_TARBALL"
        cp "$BONITOAGENTS_TARBALL" "$tarball"
    else
        if [ -n "$installed_tag" ]; then
            info "Updating BonitoAgents ${installed_tag} → ${TARGET_TAG:-latest} ($osname-$arch)"
        else
            info "Downloading BonitoAgents ${TARGET_TAG:-latest} ($osname-$arch)"
        fi
        if have curl; then
            curl -fSL --progress-bar "$url" -o "$tarball" \
                || die "download failed: $url"
        elif have wget; then
            wget -q --show-progress "$url" -O "$tarball" \
                || die "download failed: $url"
        else
            die "need curl or wget on PATH to download the release"
        fi
    fi

    # ── Extract ───────────────────────────────────────────────────────────────
    info "Extracting"
    mkdir -p "$stage"
    tar -xzf "$tarball" -C "$stage" || die "extraction failed (corrupt download?)"
    bundle="$(find "$stage" -maxdepth 1 -type d -name 'bonitoagents-*' | head -n 1)"
    [ -n "$bundle" ] && [ -x "$bundle/bin/$APP_NAME" ] \
        || die "bundle is missing bin/$APP_NAME — aborting"

    # On macOS, strip the quarantine xattr so Gatekeeper doesn't block the
    # unsigned launcher/julia (harmless/no-op on Linux and when already clean).
    if [ "$osname" = "macos" ] && have xattr; then
        xattr -dr com.apple.quarantine "$bundle" 2>/dev/null || true
    fi

    # ── Install (replace atomically on the same filesystem) ───────────────────
    info "Installing to $PREFIX"
    printf '%s' "$TARGET_TAG" > "$bundle/.release"
    rm -rf "$PREFIX"
    mkdir -p "$(dirname "$PREFIX")"
    mv "$bundle" "$PREFIX"
    rm -rf "$stage" "$tarball"
    trap - EXIT INT TERM

    # ── Command on PATH ───────────────────────────────────────────────────────
    mkdir -p "$BIN_DIR"
    ln -sf "$LAUNCHER" "$BIN_DIR/$CMD_NAME"
    ln -sf "$LAUNCHER" "$BIN_DIR/$APP_NAME"   # also expose the bundle's own name

    # ── Desktop entry + icon (Linux/freedesktop only) ─────────────────────────
    if [ "$osname" = "linux" ] && [ -f "$PREFIX/meta/gui/$APP_NAME.desktop" ]; then
        apps="$DATA_HOME/applications"
        icons="$DATA_HOME/icons/hicolor/512x512/apps"
        mkdir -p "$apps" "$icons"
        [ -f "$PREFIX/meta/icon.png" ] && cp "$PREFIX/meta/icon.png" "$icons/$CMD_NAME.png"
        sed -e "s|@EXEC@|$BIN_DIR/$CMD_NAME|g" \
            -e "s|@ICON@|$icons/$CMD_NAME.png|g" \
            "$PREFIX/meta/gui/$APP_NAME.desktop" > "$apps/$CMD_NAME.desktop"
        have update-desktop-database && update-desktop-database "$apps" 2>/dev/null || true
    fi

    info "Installed BonitoAgents ${TARGET_TAG} — command: $CMD_NAME"
fi

# ── Ensure BIN_DIR is on PATH for future shells ───────────────────────────────
case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;   # already reachable — nothing to do
    *)
        # Append a guarded PATH line to each shell rc that exists; if none do,
        # create ~/.profile (read by POSIX login shells) as the fallback.
        rcs=""
        for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
            [ -e "$rc" ] && rcs="$rcs $rc"
        done
        [ -n "$rcs" ] || { : > "$HOME/.profile"; rcs=" $HOME/.profile"; }
        added=""
        for rc in $rcs; do
            if ! grep -qs 'BonitoAgents installer: add ' "$rc"; then
                {
                    printf '\n# BonitoAgents installer: add %s to PATH\n' "$BIN_DIR"
                    printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$BIN_DIR" "$BIN_DIR"
                } >> "$rc"
                added="$added $rc"
            fi
        done
        [ -n "$added" ] && warn "added $BIN_DIR to PATH in$added — open a new shell (or run 'export PATH=\"$BIN_DIR:\$PATH\"') to use '$CMD_NAME'."
        ;;
esac

# ── Launch ────────────────────────────────────────────────────────────────────
if [ "$DO_RUN" -eq 1 ]; then
    info "Starting BonitoAgents — the dashboard will open in your browser (Ctrl+C to stop)."
    exec "$BIN_DIR/$CMD_NAME"
else
    say ""
    say "Start it any time with:  $CMD_NAME"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "  (or: $BIN_DIR/$CMD_NAME)";; esac
fi
