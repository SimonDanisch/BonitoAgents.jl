#!/usr/bin/env bash
# BonitoAgents server uninstaller — reverses install_server.sh.
#
#   bash BonitoAgents/assets/uninstall_server.sh [options]
#
# Stops + disables + removes the systemd unit. The data dir
# /var/lib/bonitoagents (workers.json / projects.json, project mirrors, and the
# worker secret at state/worker_secret) is removed by default — pass
# --keep-state to preserve it so a fresh install reuses the same secret +
# workers without re-registering each worker. The legacy config dir
# /etc/bonitoagents (only present from pre-CLI installs; current installs keep
# the secret in the data dir and bake the public URL into the systemd unit) is
# also removed. The monorepo checkout is never touched.
#
# Options:
#   --keep-state   Preserve /var/lib/bonitoagents (workers.json, project
#                  mirrors, worker secret) and the legacy /etc/bonitoagents.
#   --yes          Skip the confirmation prompt.
set -euo pipefail

KEEP_STATE=0
ASSUME_YES=0
DATA_DIR="/var/lib/bonitoagents"
CONFIG_DIR="/etc/bonitoagents"
SERVICE="bonitoagents-server"
UNIT_PATH="/etc/systemd/system/${SERVICE}.service"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-state) KEEP_STATE=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

command -v sudo > /dev/null || { echo "ERROR: sudo not found"; exit 1; }

echo "==> BonitoAgents server uninstaller"
echo "    Service : ${SERVICE}"
echo "    Data    : ${DATA_DIR}    $([[ $KEEP_STATE -eq 1 ]] && echo '(KEEP)' || echo '(REMOVE)')"
echo "    Config  : ${CONFIG_DIR}     $([[ $KEEP_STATE -eq 1 ]] && echo '(KEEP)' || echo '(REMOVE)')"
echo "    Unit    : ${UNIT_PATH}"

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -ne 1 ]]; then
    echo ""
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── Stop + disable ────────────────────────────────────────────────────────────
step "Stop + disable service"
if sudo systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    sudo systemctl stop "$SERVICE"
    ok "stopped"
else
    info "not running"
fi
if sudo systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
    sudo systemctl disable "$SERVICE" > /dev/null 2>&1
    ok "disabled"
else
    info "not enabled"
fi

# ── Remove unit ───────────────────────────────────────────────────────────────
step "Remove systemd unit"
if [[ -f "$UNIT_PATH" ]]; then
    sudo rm -f "$UNIT_PATH"
    sudo systemctl daemon-reload
    ok "removed $UNIT_PATH"
else
    info "no unit at $UNIT_PATH"
fi

# ── Remove data + config ──────────────────────────────────────────────────────
if [[ $KEEP_STATE -eq 1 ]]; then
    step "Preserve state (--keep-state)"
    info "$DATA_DIR retained"
    info "$CONFIG_DIR retained"
else
    step "Remove data dir"
    if [[ -d "$DATA_DIR" ]]; then
        sudo rm -rf "$DATA_DIR"
        ok "removed $DATA_DIR"
    else
        info "no data at $DATA_DIR"
    fi
    step "Remove config dir"
    if [[ -d "$CONFIG_DIR" ]]; then
        sudo rm -rf "$CONFIG_DIR"
        ok "removed $CONFIG_DIR"
    else
        info "no config at $CONFIG_DIR"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoAgents server uninstalled."
echo "============================================================"
echo ""
echo "  The monorepo checkout itself was NOT touched. To remove it:"
echo "    rm -rf /path/to/your/BonitoAgents-checkout"
echo ""
echo "  To reinstall:    bash BonitoAgents/assets/install_server.sh"
