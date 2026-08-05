#!/usr/bin/env bash
# BonitoAgents server installer — idempotent.
# Run as a regular user (sudo is invoked internally for privileged steps):
#
#   bash BonitoAgents/assets/install_server.sh [options]
#
# The systemd service runs as the user invoking sudo (so it can access
# their juliaup install + the monorepo without permission gymnastics).
# Re-run the script to update — service is stopped first, so we never
# leave half-applied state behind.
#
# Options:
#   --public-url URL   URL workers use to reach this server
#                      (default: http://<auto-detected-ip>:PORT)
#   --secret SECRET    worker shared secret (auto-generated if omitted)
#   --port PORT        bind port (default: 8038)
#
# TLS / reverse proxy are out of scope — put cloudflared or similar in front.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PUBLIC_URL=""
SECRET=""
PORT=8038

# Script lives at BonitoAgents/assets/install_server.sh → monorepo is two levels up
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-url) PUBLIC_URL="$2"; shift 2 ;;
        --secret)     SECRET="$2";     shift 2 ;;
        --port)       PORT="$2";       shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

# ── Service user ──────────────────────────────────────────────────────────────
# Service runs as the human who invoked the installer — they own the monorepo
# and the juliaup install, so no /home traversal permission issues.
SERVICE_USER="${SUDO_USER:-$USER}"
if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
    echo "ERROR: cannot determine non-root user for the service." >&2
    echo "       Run as a regular user; the script will sudo when needed:" >&2
    echo "         bash $0 ..." >&2
    exit 1
fi
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
[[ -d "$SERVICE_HOME" ]] || { echo "ERROR: $SERVICE_USER's home not found"; exit 1; }

DATA_DIR="/var/lib/bonitoagents"
CONFIG_DIR="/etc/bonitoagents"
SERVER_BIN="$MONOREPO_DIR/BonitoAgents/bin/bonitoagents-server"
JULIA_BIN="$(command -v julia || true)"
# `command -v` only sees PATH, but the service user installs Julia via juliaup
# (~/.juliaup/bin/julia), which is on PATH only inside their interactive shell —
# not when the installer runs under sudo / a bare environment. Fall back to the
# well-known juliaup / juliaup-symlink locations in the service user's home.
if [[ -z "$JULIA_BIN" ]]; then
    for cand in "$SERVICE_HOME/.juliaup/bin/julia" "$SERVICE_HOME/.local/bin/julia"; do
        [[ -x "$cand" ]] && { JULIA_BIN="$cand"; break; }
    done
fi

echo "==> BonitoAgents server installer"
echo "    Monorepo     : $MONOREPO_DIR"
echo "    Service user : $SERVICE_USER"

# ── Sanity checks ─────────────────────────────────────────────────────────────
step "Sanity checks"
[[ -f "$SERVER_BIN" ]] || { echo "ERROR: $SERVER_BIN not found — run from the cloned repo"; exit 1; }
[[ -n "$JULIA_BIN" ]]  || { echo "ERROR: julia not found (checked PATH and $SERVICE_HOME/.juliaup/bin) — install Julia (juliaup) first"; exit 1; }
command -v sudo > /dev/null || { echo "ERROR: sudo not found"; exit 1; }
chmod +x "$MONOREPO_DIR/BonitoAgents/bin/"*
ok "julia: $("$JULIA_BIN" --version)"

# ── Stop service before any changes ───────────────────────────────────────────
# Either the old service is running (if we abort before this point) or it's
# stopped and we own the update fully — never half-and-half.
step "Stop existing service (if running)"
if sudo systemctl is-active --quiet bonitoagents-server 2>/dev/null; then
    sudo systemctl stop bonitoagents-server
    ok "stopped"
else
    ok "not running"
fi

# ── Data dir ──────────────────────────────────────────────────────────────────
step "Data dir: $DATA_DIR"
sudo mkdir -p "$DATA_DIR/state" "$DATA_DIR/projects"
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
sudo chmod 750 "$DATA_DIR"
ok "owned by $SERVICE_USER"

# ── Julia env ─────────────────────────────────────────────────────────────────
# Always operate against the MONOREPO ROOT's Project.toml + Manifest.toml.
# The per-package Project.toml files (BonitoAgents/Project.toml etc.) are
# metadata for declaring deps and must NEVER be used as a runtime env.
step "Julia env (monorepo root)"
# resolve() first: the per-package Project.tomls evolve (e.g. a new stdlib dep),
# so the root Manifest can be out of sync — instantiate() alone would then fail
# to precompile ("package X does not have Y in its dependencies").
"$JULIA_BIN" "--project=$MONOREPO_DIR" --startup-file=no \
    -e 'import Pkg; Pkg.resolve(); Pkg.instantiate()'
ok "resolved + instantiated"

# ── Worker secret ─────────────────────────────────────────────────────────────
# The server persists its secret at $DATA_DIR/state/worker_secret and reuses it
# across restarts (no env vars). Seed it so existing workers keep authenticating:
# an explicit --secret wins; otherwise migrate a pre-CLI secret from the old
# $CONFIG_DIR/server.env if present; otherwise leave it to the server to generate.
step "Worker secret"
SECRET_FILE="$DATA_DIR/state/worker_secret"
if [[ -n "$SECRET" ]]; then
    printf '%s' "$SECRET" | sudo tee "$SECRET_FILE" > /dev/null
    ok "set from --secret"
elif sudo test -s "$SECRET_FILE"; then
    ok "reusing $SECRET_FILE"
elif sudo test -f "$CONFIG_DIR/server.env"; then
    OLD=$(sudo grep '^BONITOAGENTS_WORKER_SECRET=' "$CONFIG_DIR/server.env" | cut -d= -f2- || true)
    if [[ -n "$OLD" ]]; then
        printf '%s' "$OLD" | sudo tee "$SECRET_FILE" > /dev/null
        ok "migrated from old $CONFIG_DIR/server.env"
    fi
else
    info "none yet — the server generates one on first start"
fi
sudo test -f "$SECRET_FILE" && { sudo chown "$SERVICE_USER:$SERVICE_USER" "$SECRET_FILE"; sudo chmod 600 "$SECRET_FILE"; }

# ── Public URL ────────────────────────────────────────────────────────────────
step "Public URL"
if [[ -z "$PUBLIC_URL" ]]; then
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    PUBLIC_URL="http://${LOCAL_IP:-127.0.0.1}:$PORT"
    info "auto-detected — pass --public-url to override (e.g. cloudflare tunnel hostname)"
fi
ok "$PUBLIC_URL"

# ── systemd service ───────────────────────────────────────────────────────────
step "systemd service: bonitoagents-server"
sudo tee /etc/systemd/system/bonitoagents-server.service > /dev/null << EOF
[Unit]
Description=BonitoAgents dashboard server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=PATH=$(dirname "$JULIA_BIN"):/usr/local/bin:/usr/bin:/bin
ExecStart=$SERVER_BIN --host 0.0.0.0 --port $PORT --public-url $PUBLIC_URL --state-dir $DATA_DIR/state --working-dir $DATA_DIR/projects
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

# Hardening — see systemd.exec(5).
# ProtectHome is intentionally NOT set: the service runs as the install user
# and needs to read/write its own juliaup lockfile (~/.julia/juliaup/) and
# the Julia depot (~/.julia/). Since we run as that user anyway, blocking
# /home would only stop access to *other* users' homes — irrelevant here.
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
LockPersonality=true
# Julia JIT requires writable+executable pages — MemoryDenyWriteExecute stays off
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable bonitoagents-server > /dev/null 2>&1 || true
ok "installed + enabled"

# ── Start ─────────────────────────────────────────────────────────────────────
step "Start bonitoagents-server"
sudo systemctl start bonitoagents-server
sleep 2
if sudo systemctl is-active --quiet bonitoagents-server; then
    ok "active"
else
    echo "ERROR: service failed to start." >&2
    echo "  journalctl -u bonitoagents-server -e" >&2
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoAgents server running at $PUBLIC_URL"
echo "============================================================"
echo ""
echo "  Worker install (run on each agent machine):"
echo "    Linux / macOS:  curl -fsSL $PUBLIC_URL/install.sh | sh"
echo "    Windows (PS):   irm $PUBLIC_URL/install.ps1 | iex"
echo ""
echo "  Logs:    journalctl -u bonitoagents-server -f"
echo "  Config:  $CONFIG_DIR/server.env"
echo "  State:   $DATA_DIR"
