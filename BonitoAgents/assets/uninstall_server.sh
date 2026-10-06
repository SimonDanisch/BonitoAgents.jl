#!/usr/bin/env bash
# BonitoAgents server uninstaller: reverses install_server.sh.
#
#   bash BonitoAgents/assets/uninstall_server.sh [options]
#
# Stops, disables and removes the three systemd units (server, Authelia, Caddy)
# and the Caddy + Authelia binaries in /usr/local/lib/bonitoagents. The data dir
# /var/lib/bonitoagents (projects and chats, workers.json / projects.json,
# accounts, worker credentials, Authelia's secrets and database, Caddy's
# certificates) stays: a reinstall, or running the server without the proxy
# (`bonito-agents server --host 0.0.0.0 --state-dir /var/lib/bonitoagents/state`),
# picks everything up again. Only --purge deletes it, with the legacy config dir
# /etc/bonitoagents (pre-CLI installs). The monorepo checkout is never touched.
#
# Options:
#   --instance NAME  remove the install made with `install_server.sh --instance NAME`
#                    (bonitoagents-NAME-*, /var/lib/bonitoagents-NAME, ...) instead
#   --purge          also delete the data dir: every project, chat and account
#   --keep-state     keep the data dir (the default; accepted for older scripts)
#   --yes            skip the confirmation prompt
set -euo pipefail

KEEP_STATE=1
ASSUME_YES=0
INSTANCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance)   INSTANCE="$2"; shift 2 ;;
        --keep-state) KEEP_STATE=1; shift ;;
        --purge)      KEEP_STATE=0; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ -z "$INSTANCE" || "$INSTANCE" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    { echo "ERROR: --instance must be lowercase letters, digits and '-'" >&2; exit 1; }

NAME="bonitoagents${INSTANCE:+-$INSTANCE}"
DATA_DIR="/var/lib/$NAME"
# The legacy config dir belongs to the default install only.
CONFIG_DIR=""
[[ -n "$INSTANCE" ]] || CONFIG_DIR="/etc/bonitoagents"
BIN_ROOT="/usr/local/lib/$NAME"
# Reverse start order: the proxy goes first, the server last.
SERVICES=("$NAME-caddy" "$NAME-authelia" "$NAME-server")

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }

command -v sudo > /dev/null || { echo "ERROR: sudo not found"; exit 1; }

echo "==> BonitoAgents server uninstaller"
echo "    Services : ${SERVICES[*]}"
echo "    Binaries : ${BIN_ROOT}"
echo "    Data     : ${DATA_DIR}    $([[ $KEEP_STATE -eq 1 ]] && echo '(kept)' || echo '(DELETED: every project, chat and account)')"
[[ -z "$CONFIG_DIR" ]] ||
    echo "    Config   : ${CONFIG_DIR}     $([[ $KEEP_STATE -eq 1 ]] && echo '(kept)' || echo '(DELETED)')"

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -ne 1 ]]; then
    echo ""
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── Stop, disable, remove the units ───────────────────────────────────────────
step "Stop + disable + remove services"
removed_unit=0
for svc in "${SERVICES[@]}"; do
    if sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
        sudo systemctl stop "$svc"
        ok "stopped $svc"
    fi
    if sudo systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        sudo systemctl disable "$svc" > /dev/null 2>&1
        ok "disabled $svc"
    fi
    unit="/etc/systemd/system/${svc}.service"
    if [[ -f "$unit" ]]; then
        sudo rm -f "$unit"
        removed_unit=1
        ok "removed $unit"
    else
        info "no unit at $unit"
    fi
done
[[ $removed_unit -eq 1 ]] && sudo systemctl daemon-reload

# ── Binaries ──────────────────────────────────────────────────────────────────
step "Remove Caddy + Authelia"
if [[ -d "$BIN_ROOT" ]]; then
    sudo rm -rf "$BIN_ROOT"
    ok "removed $BIN_ROOT"
else
    info "none at $BIN_ROOT"
fi

# ── Data + config ─────────────────────────────────────────────────────────────
if [[ $KEEP_STATE -eq 1 ]]; then
    step "Keep the data"
    info "$DATA_DIR kept (--purge deletes it)"
    [[ -z "$CONFIG_DIR" ]] || info "$CONFIG_DIR kept"
else
    step "Remove data dir"
    if [[ -d "$DATA_DIR" ]]; then
        sudo rm -rf "$DATA_DIR"
        ok "removed $DATA_DIR"
    else
        info "no data at $DATA_DIR"
    fi
    # The services' own system user, whose home the data dir was. Kept data
    # keeps it: it owns the files.
    step "Remove the service user"
    if getent passwd "$NAME" > /dev/null; then
        sudo userdel "$NAME"
        ok "removed $NAME"
    else
        info "no user $NAME"
    fi
    step "Remove config dir"
    if [[ -n "$CONFIG_DIR" && -d "$CONFIG_DIR" ]]; then
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
if [[ $KEEP_STATE -eq 1 ]]; then
    echo "  Projects, chats and accounts are kept in $DATA_DIR. To use them:"
    echo "    behind the login proxy again:  bash BonitoAgents/assets/install_server.sh${INSTANCE:+ --instance $INSTANCE}"
    echo "    on a trusted network, no login: BonitoAgents/bin/bonitoagents-server --host 0.0.0.0 \\"
    echo "        --state-dir $DATA_DIR/state --working-dir $DATA_DIR/projects"
    echo "  To delete them too: bash BonitoAgents/assets/uninstall_server.sh --purge${INSTANCE:+ --instance $INSTANCE}"
else
    echo "  To reinstall:    bash BonitoAgents/assets/install_server.sh${INSTANCE:+ --instance $INSTANCE}"
fi
echo ""
echo "  The monorepo checkout itself was NOT touched."
