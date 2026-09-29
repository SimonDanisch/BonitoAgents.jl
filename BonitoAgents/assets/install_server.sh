#!/usr/bin/env bash
# BonitoAgents server installer: idempotent, Linux + systemd.
# Run as a regular user (sudo is invoked internally for privileged steps):
#
#   bash BonitoAgents/assets/install_server.sh
#
# It asks for what it needs (the domain, the admin, optional mail); every answer
# can also be given as an option, and `--no-prompt` makes a missing required one
# an error instead of a question.
#
# Sets the server up behind a login proxy, so nothing of BonitoAgents itself is
# reachable from the network:
#   * Caddy terminates HTTPS (Let's Encrypt, renewed by itself) and routes the
#     dashboard through Authelia's login, `/w` through the per-worker credentials
#     ("Add worker" on the dashboard issues one per machine), and the worker
#     installer and invite links to anyone (they carry their own proof).
#   * Authelia is the login: a password plus a second factor (an authenticator
#     app or a security key), with brute-force lockout.
#   * BonitoAgents listens on 127.0.0.1 and takes the proxy's word for who a
#     request is from. It owns the proxy's configuration: the Caddyfile (worker
#     credentials), Authelia's users database (accounts, and their passwords:
#     Authelia's own password reset is off) and Authelia's configuration with
#     its secrets, and renders them whenever it starts. This script only writes
#     what they are rendered from: proxy.json, the first admin, mail settings.
#
# The one thing no script can do is make this machine reachable on ports 80 and
# 443 under its DNS name (a public IP, DNS records, the router forwarding both
# ports). The installer checks that before Let's Encrypt is asked for a
# certificate, and stops with a clear message if it is not so.
#
# Re-run it to update: services are stopped first; secrets, accounts and the
# mail settings are kept, the previous answers are the defaults, and binaries
# are only replaced when their version changed.
#
# Options:
#   --domain NAME          the dashboard's host name, e.g. team.example.com
#   --auth-domain NAME     the login portal's host name (default: auth.<--domain>); it must
#                          sit under --domain's parent, which the login cookie covers
#   --admin NAME           the first admin account (default: the installing user)
#   --admin-email ADDR     its email address
#   --acme-email ADDR      contact for Let's Encrypt (optional: certificate notices)
#   --acme-staging         certificates from Let's Encrypt's staging CA: for trying an
#                          install out without running into its rate limits (browsers
#                          warn about them)
#   --tls internal         certificates from Caddy's own CA instead of Let's Encrypt:
#                          no public domain or open ports needed (a LAN, or a test on
#                          one machine), but every browser and worker has to trust
#                          Caddy's root certificate (printed at the end)
#   --port PORT            BonitoAgents' port on 127.0.0.1 (default: 8038)
#   --https-port PORT      Caddy's HTTPS port (default: 443)
#   --http-port PORT       Caddy's HTTP port (default: 80; Let's Encrypt checks port 80)
#   --authelia-port PORT   Authelia's port on 127.0.0.1 (default: 9091)
#   --smtp-host HOST       lets Authelia send mail, so the one-time code that
#   --smtp-port PORT       confirms a new second factor reaches people directly
#   --smtp-user USER       (default port 587). Without it Authelia writes that code
#   --smtp-password PASS   to a file on this machine, which admins read on the
#   --smtp-sender ADDR     dashboard and pass on.
#   --no-smtp              drop mail settings kept from a previous install
#   --caddy-version V      default: the latest release
#   --authelia-version V   default: the latest release
#   --skip-port-check      for networks where this machine cannot reach its own
#                          public address (no NAT hairpinning); Let's Encrypt then
#                          reports a closed port itself.
#   --instance NAME        a separate install next to the default one: its own
#                          services (bonitoagents-NAME-*), data and binaries. Give it
#                          its own ports too.
#   --no-update            leave the monorepo's Julia environment as it is
#   --no-prompt            ask nothing (for scripted installs)
set -euo pipefail

# ── Options ───────────────────────────────────────────────────────────────────
DOMAIN=""
AUTH_DOMAIN=""
ADMIN=""
ADMIN_EMAIL=""
ACME_EMAIL=""
ACME_STAGING=0
TLS=""
PORT=""
HTTPS_PORT=""
HTTP_PORT=""
AUTHELIA_PORT=""
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASSWORD=""
SMTP_SENDER=""
NO_SMTP=0
CADDY_VERSION=""
AUTHELIA_VERSION=""
SKIP_PORT_CHECK=0
INSTANCE=""
UPDATE=1
PROMPT=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)            DOMAIN="$2";            shift 2 ;;
        --auth-domain)       AUTH_DOMAIN="$2";       shift 2 ;;
        --admin)             ADMIN="$2";             shift 2 ;;
        --admin-email)       ADMIN_EMAIL="$2";       shift 2 ;;
        --acme-email)        ACME_EMAIL="$2";        shift 2 ;;
        --acme-staging)      ACME_STAGING=1;         shift ;;
        --tls)               TLS="$2";               shift 2 ;;
        --port)              PORT="$2";              shift 2 ;;
        --https-port)        HTTPS_PORT="$2";        shift 2 ;;
        --http-port)         HTTP_PORT="$2";         shift 2 ;;
        --authelia-port)     AUTHELIA_PORT="$2";     shift 2 ;;
        --smtp-host)         SMTP_HOST="$2";         shift 2 ;;
        --smtp-port)         SMTP_PORT="$2";         shift 2 ;;
        --smtp-user)         SMTP_USER="$2";         shift 2 ;;
        --smtp-password)     SMTP_PASSWORD="$2";     shift 2 ;;
        --smtp-sender)       SMTP_SENDER="$2";       shift 2 ;;
        --no-smtp)           NO_SMTP=1;              shift ;;
        --caddy-version)     CADDY_VERSION="$2";     shift 2 ;;
        --authelia-version)  AUTHELIA_VERSION="$2";  shift 2 ;;
        --skip-port-check)   SKIP_PORT_CHECK=1;      shift ;;
        --instance)          INSTANCE="$2";          shift 2 ;;
        --no-update)         UPDATE=0;               shift ;;
        --no-prompt)         PROMPT=0;               shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
ok()   { echo "    ok   : $*"; }
info() { echo "    info : $*"; }
fail() { echo "" >&2; echo "ERROR: $*" >&2; exit 1; }

# ── Paths + service user ──────────────────────────────────────────────────────
# The services run as the human who invoked the installer: they own the
# monorepo and the juliaup install, so there are no /home permission issues.
SERVICE_USER="${SUDO_USER:-$USER}"
if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
    fail "cannot determine a non-root user for the services. Run as a regular user; the script sudo's when needed."
fi
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
[[ -d "$SERVICE_HOME" ]] || fail "$SERVICE_USER's home not found"

[[ -z "$INSTANCE" || "$INSTANCE" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    fail "--instance must be lowercase letters, digits and '-' (got '$INSTANCE')"
NAME="bonitoagents${INSTANCE:+-$INSTANCE}"
UNIT_SERVER="$NAME-server"
UNIT_AUTHELIA="$NAME-authelia"
UNIT_CADDY="$NAME-caddy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVER_BIN="$MONOREPO_DIR/BonitoAgents/bin/bonitoagents-server"
DATA_DIR="/var/lib/$NAME"
STATE_DIR="$DATA_DIR/state"
CADDY_DIR="$DATA_DIR/caddy"
AUTHELIA_DIR="$DATA_DIR/authelia"
BIN_DIR="/usr/local/lib/$NAME/bin"
JULIA_BIN="$(command -v julia || true)"
# juliaup puts julia on PATH only inside the user's interactive shell, not under
# sudo or a bare environment: fall back to its well-known locations.
if [[ -z "$JULIA_BIN" ]]; then
    for cand in "$SERVICE_HOME/.juliaup/bin/julia" "$SERVICE_HOME/.local/bin/julia"; do
        [[ -x "$cand" ]] && { JULIA_BIN="$cand"; break; }
    done
fi

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "no Caddy/Authelia builds for this CPU: $(uname -m)" ;;
esac

# ── Answers ───────────────────────────────────────────────────────────────────
# A previous install's answers are the defaults (proxy.json is written below, one
# `"key": value` per line).
previous() {
    sudo test -f "$STATE_DIR/proxy.json" || return 0
    sudo sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$STATE_DIR/proxy.json"
}
PREV_SMTP=false
sudo test -f "$STATE_DIR/smtp.json" && PREV_SMTP=true

# Questions need a terminal; without one (or with --no-prompt) nothing is asked.
{ : < /dev/tty; } 2> /dev/null || PROMPT=0
ask() {   # ask VAR "question" [default]
    local var="$1" question="$2" default="${3:-}" reply
    [[ $PROMPT -eq 1 && -z "${!var}" ]] || return 0
    if [[ -n "$default" ]]; then
        read -r -p "    $question [$default]: " reply < /dev/tty
        printf -v "$var" '%s' "${reply:-$default}"
    else
        read -r -p "    $question: " reply < /dev/tty
        printf -v "$var" '%s' "$reply"
    fi
}
ask_secret() {   # ask_secret VAR "question"
    local var="$1" question="$2" reply
    [[ $PROMPT -eq 1 && -z "${!var}" ]] || return 0
    read -r -s -p "    $question: " reply < /dev/tty
    echo
    printf -v "$var" '%s' "$reply"
}
yes_no() {   # yes_no "question" default(y|n) -> status
    local reply
    read -r -p "    $1 [$([[ $2 == y ]] && echo Y/n || echo y/N)]: " reply < /dev/tty
    reply="${reply:-$2}"
    [[ "$reply" =~ ^[Yy] ]]
}

if [[ $PROMPT -eq 1 ]]; then
    echo "==> BonitoAgents server setup (Enter takes the value in brackets)"
    ask DOMAIN "Dashboard domain, e.g. team.example.com" "$(previous domain)"
fi
[[ -n "$DOMAIN" ]] || fail "the dashboard's domain is required: --domain team.example.com"
if [[ $PROMPT -eq 1 ]]; then
    # auth.<domain> by default: the login cookie then covers exactly the
    # dashboard, and it works for any domain, including a dynamic-DNS name.
    prev_auth="$(previous auth_domain)"
    [[ "$(previous domain)" == "$DOMAIN" && -n "$prev_auth" ]] || prev_auth="auth.$DOMAIN"
    ask AUTH_DOMAIN "Login portal domain" "$prev_auth"
    prev_admin="$(previous admin)"
    ask ADMIN "Admin account" "${prev_admin:-$SERVICE_USER}"
    ask ADMIN_EMAIL "Admin email (optional)"
    ask ACME_EMAIL "Email for Let's Encrypt notices (optional)" "${ADMIN_EMAIL:-$(previous acme_email)}"
    if [[ -z "$SMTP_HOST" && $NO_SMTP -eq 0 ]]; then
        if [[ "$PREV_SMTP" == true ]]; then
            yes_no "Keep the current mail settings" y || NO_SMTP=1
        fi
        if [[ "$PREV_SMTP" != true || $NO_SMTP -eq 1 ]] &&
           yes_no "Send mail through an SMTP server (for second-factor codes)" n; then
            NO_SMTP=0
            ask SMTP_HOST "SMTP host"
            ask SMTP_PORT "SMTP port" 587
            ask SMTP_USER "SMTP user"
            ask_secret SMTP_PASSWORD "SMTP password"
            ask SMTP_SENDER "Sender address" "$ADMIN_EMAIL"
        fi
    fi
fi
# What was not given takes the previous install's value, else the default.
default() {   # default VAR key fallback
    local var="$1" key="$2" fallback="$3" prev
    [[ -n "${!var}" ]] && return 0
    prev="$(previous "$key")"
    printf -v "$var" '%s' "${prev:-$fallback}"
}
[[ -n "$AUTH_DOMAIN" ]] || AUTH_DOMAIN="auth.$DOMAIN"
default ADMIN admin "$SERVICE_USER"
default ACME_EMAIL acme_email ""
default TLS tls acme
default PORT port 8038
default HTTPS_PORT https_port 443
default HTTP_PORT http_port 80
default AUTHELIA_PORT authelia_port 9091
[[ -n "$SMTP_PORT" ]] || SMTP_PORT=587
ACME_CA=""
[[ $ACME_STAGING -eq 1 ]] && ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory"

# Authelia's login cookie has to cover both host names.
COOKIE_DOMAIN="${AUTH_DOMAIN#*.}"
[[ "$DOMAIN" == "$COOKIE_DOMAIN" || "$DOMAIN" == *".$COOKIE_DOMAIN" ]] ||
    fail "the dashboard ($DOMAIN) and the login portal ($AUTH_DOMAIN) must share a parent domain ($COOKIE_DOMAIN) for the login cookie"
[[ "$ADMIN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail "the admin account must be letters, digits, '.', '_' and '-' (got '$ADMIN')"
[[ "$ADMIN_EMAIL$ACME_EMAIL$SMTP_SENDER" != *[\"\\\']* ]] ||
    fail "email addresses must not contain quotes or backslashes"
[[ "$TLS" == acme || "$TLS" == internal ]] || fail "--tls is 'acme' (Let's Encrypt) or 'internal' (got '$TLS')"
for p in "$PORT" "$HTTPS_PORT" "$HTTP_PORT" "$AUTHELIA_PORT"; do
    [[ "$p" =~ ^[0-9]+$ ]] || fail "ports are numbers (got '$p')"
done
# Mail: new settings, the previous install's (kept in smtp.json), or none.
if [[ -n "$SMTP_HOST" ]]; then
    [[ -n "$SMTP_SENDER" ]] || fail "--smtp-host needs --smtp-sender too"
    SMTP_MODE=new
elif [[ "$PREV_SMTP" == true && $NO_SMTP -eq 0 ]]; then
    SMTP_MODE=keep
else
    SMTP_MODE=none
fi
SMTP_ON=$([[ $SMTP_MODE == none ]] && echo false || echo true)
ORIGIN="https://$DOMAIN$([[ $HTTPS_PORT == 443 ]] || echo ":$HTTPS_PORT")"

echo ""
echo "==> BonitoAgents server installer${INSTANCE:+ (instance $INSTANCE)}"
echo "    Monorepo     : $MONOREPO_DIR"
echo "    Service user : $SERVICE_USER"
echo "    Dashboard    : $ORIGIN"
echo "    Login portal : https://$AUTH_DOMAIN$([[ $HTTPS_PORT == 443 ]] || echo ":$HTTPS_PORT")"
echo "    Admin        : $ADMIN"
echo "    Certificates : $([[ $TLS == internal ]] && echo "Caddy's own CA" || echo "Let's Encrypt${ACME_CA:+ (staging)}")"
echo "    Mail         : $([[ $SMTP_MODE == none ]] && echo "none (codes go to a file admins read)" || echo "$SMTP_MODE")"

# ── Sanity checks ─────────────────────────────────────────────────────────────
step "Sanity checks"
[[ -f "$SERVER_BIN" ]] || fail "$SERVER_BIN not found: run from the cloned repo"
[[ -n "$JULIA_BIN" ]]  || fail "julia not found (checked PATH and $SERVICE_HOME/.juliaup/bin): install Julia (juliaup) first"
for tool in sudo curl tar sha256sum sha512sum getent ss systemctl timeout; do
    command -v "$tool" > /dev/null || fail "$tool not found"
done
chmod +x "$MONOREPO_DIR/BonitoAgents/bin/"*
ok "julia: $("$JULIA_BIN" --version)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Stop the services before any change ───────────────────────────────────────
step "Stop existing services"
for svc in "$UNIT_CADDY" "$UNIT_AUTHELIA" "$UNIT_SERVER"; do
    if sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
        sudo systemctl stop "$svc"
        ok "stopped $svc"
    fi
done

# ── Reachability ──────────────────────────────────────────────────────────────
step "Reachability"
for p in "$HTTP_PORT" "$HTTPS_PORT" "$PORT" "$AUTHELIA_PORT"; do
    holder="$(sudo ss -Hltnp "sport = :$p" | head -1 || true)"
    [[ -z "$holder" ]] || fail "port $p is already in use on this machine: $holder"
done
ok "ports $HTTP_PORT, $HTTPS_PORT, $PORT and $AUTHELIA_PORT are free here"
# Before anything asks Let's Encrypt for a certificate: a failed ACME attempt
# only says "timeout", and repeated failures are rate-limited for an hour.
# Caddy's own CA needs neither DNS nor open ports.
if [[ $TLS == acme ]]; then
    PUBLIC_IP="$(curl -fsS4 --max-time 10 https://api.ipify.org || true)"
    [[ -n "$PUBLIC_IP" ]] || fail "could not determine this machine's public IPv4 address (https://api.ipify.org)"
    ok "public address: $PUBLIC_IP"
    for name in "$DOMAIN" "$AUTH_DOMAIN"; do
        ips="$(getent ahostsv4 "$name" | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
        [[ -n "$ips" ]] || fail "$name does not resolve. Add a DNS A record for it pointing at $PUBLIC_IP."
        [[ " $ips" == *" $PUBLIC_IP "* ]] ||
            fail "$name resolves to $ips, but this machine's public address is $PUBLIC_IP. Point its A record here (and wait for DNS to catch up)."
        ok "$name → $PUBLIC_IP"
    done
else
    info "Caddy's own CA: no DNS or open ports needed"
fi

# ── Caddy + Authelia binaries ─────────────────────────────────────────────────
latest_tag() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

step "Caddy"
[[ -n "$CADDY_VERSION" ]] || CADDY_VERSION="$(latest_tag caddyserver/caddy || true)"
CADDY_VERSION="${CADDY_VERSION#v}"
[[ -n "$CADDY_VERSION" ]] || fail "could not find Caddy's latest release (GitHub API); pass --caddy-version"
if [[ -x "$BIN_DIR/caddy" ]] && "$BIN_DIR/caddy" version 2>/dev/null | grep -q "^v$CADDY_VERSION "; then
    ok "v$CADDY_VERSION already installed"
else
    f="caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz"
    base="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}"
    curl -fsSL -o "$TMP/$f" "$base/$f"
    curl -fsSL -o "$TMP/caddy.sums" "$base/caddy_${CADDY_VERSION}_checksums.txt"
    (cd "$TMP" && grep " $f\$" caddy.sums | sha512sum -c --status) ||
        fail "Caddy v$CADDY_VERSION: $f does not match its published checksum"
    tar -xzf "$TMP/$f" -C "$TMP" caddy
    sudo install -d -m 755 "$BIN_DIR"
    sudo install -m 755 "$TMP/caddy" "$BIN_DIR/caddy"
    ok "v$CADDY_VERSION installed (checksum verified)"
fi

step "Authelia"
[[ -n "$AUTHELIA_VERSION" ]] || AUTHELIA_VERSION="$(latest_tag authelia/authelia || true)"
AUTHELIA_VERSION="${AUTHELIA_VERSION#v}"
[[ -n "$AUTHELIA_VERSION" ]] || fail "could not find Authelia's latest release (GitHub API); pass --authelia-version"
if [[ -x "$BIN_DIR/authelia" ]] && "$BIN_DIR/authelia" --version 2>/dev/null | grep -q "v$AUTHELIA_VERSION\b"; then
    ok "v$AUTHELIA_VERSION already installed"
else
    f="authelia-v${AUTHELIA_VERSION}-linux-${ARCH}.tar.gz"
    base="https://github.com/authelia/authelia/releases/download/v${AUTHELIA_VERSION}"
    curl -fsSL -o "$TMP/$f" "$base/$f"
    curl -fsSL -o "$TMP/authelia.sums" "$base/checksums.sha256"
    (cd "$TMP" && grep " $f\$" authelia.sums | sha256sum -c --status) ||
        fail "Authelia v$AUTHELIA_VERSION: $f does not match its published checksum"
    tar -xzf "$TMP/$f" -C "$TMP" authelia
    sudo install -d -m 755 "$BIN_DIR"
    sudo install -m 755 "$TMP/authelia" "$BIN_DIR/authelia"
    ok "v$AUTHELIA_VERSION installed (checksum verified)"
fi

# ── Port 80 answers from outside ──────────────────────────────────────────────
# A throwaway Caddy answers a random token on the HTTP port; fetching it through
# the domain on port 80 proves DNS, the router and the firewall all lead here.
if [[ $TLS == internal ]]; then
    :
elif [[ $SKIP_PORT_CHECK -eq 1 ]]; then
    info "port check skipped (--skip-port-check)"
else
    step "Port 80 reaches this machine"
    token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    cat > "$TMP/check.caddy" << EOF
{
	admin off
	auto_https off
}
:$HTTP_PORT {
	respond /bonitoagents-reachability "$token"
}
EOF
    sudo "$BIN_DIR/caddy" run --config "$TMP/check.caddy" --adapter caddyfile > "$TMP/check.log" 2>&1 &
    check_pid=$!
    sleep 2
    got="$(curl -fsS --max-time 10 "http://$DOMAIN/bonitoagents-reachability" || true)"
    sudo kill "$check_pid" 2> /dev/null || true
    wait "$check_pid" 2> /dev/null || true
    [[ "$got" == "$token" ]] ||
        fail "http://$DOMAIN/ does not reach this machine on port 80. Forward ports 80 and 443 to it (router), open them in its firewall, or pass --skip-port-check if this machine cannot reach its own public address (no NAT hairpinning)."
    ok "http://$DOMAIN/ answers from this machine"
fi

# ── Data dirs ─────────────────────────────────────────────────────────────────
step "Data dir: $DATA_DIR"
sudo mkdir -p "$STATE_DIR" "$DATA_DIR/projects" "$CADDY_DIR/data" "$CADDY_DIR/config" "$AUTHELIA_DIR"
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
sudo chmod 750 "$DATA_DIR"
ok "owned by $SERVICE_USER"
# An install from before the login proxy had one secret shared by every worker;
# each worker now has its own credential ("Add worker").
if sudo test -f "$STATE_DIR/worker_secret"; then
    sudo rm -f "$STATE_DIR/worker_secret"
    info "retired the old shared worker secret: reinstall each worker with \"Add worker\""
fi

# ── Julia env ─────────────────────────────────────────────────────────────────
# Always the MONOREPO ROOT's Project.toml + Manifest.toml; the per-package
# Project.toml files only declare deps and are never a runtime env. update()
# rather than resolve(): it re-pins git deps (Bonito, BonitoBook, BonitoWidgets)
# against their `rev`'s current HEAD, and picks up compat bounds tightened upstream.
if [[ $UPDATE -eq 1 ]]; then
    step "Julia env (monorepo root)"
    "$JULIA_BIN" "--project=$MONOREPO_DIR" --startup-file=no -e 'import Pkg; Pkg.update()'
    ok "updated"
fi

# ── The first admin ───────────────────────────────────────────────────────────
# The server owns the accounts (accounts.json) and renders Authelia's users
# database from them. Only a fresh install gets its admin here; the password is
# generated by Authelia and printed once at the end.
step "Admin account"
ACCOUNTS="$STATE_DIR/accounts.json"
ADMIN_PASSWORD=""
if sudo test -s "$ACCOUNTS"; then
    ok "keeping the existing accounts"
else
    out="$("$BIN_DIR/authelia" crypto hash generate argon2 --random --random.length 20)"
    ADMIN_PASSWORD="$(printf '%s\n' "$out" | sed -n 's/^Random Password: *//p')"
    hash="$(printf '%s\n' "$out" | sed -n 's/^Digest: *//p')"
    [[ -n "$ADMIN_PASSWORD" && -n "$hash" ]] || fail "authelia did not generate a password: $out"
    printf '[{"name":"%s","display_name":"%s","email":"%s","groups":["admins"],"disabled":false,"password_hash":"%s"}]\n' \
        "$ADMIN" "$ADMIN" "$ADMIN_EMAIL" "$hash" | sudo tee "$ACCOUNTS" > /dev/null
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$ACCOUNTS"
    sudo chmod 600 "$ACCOUNTS"
    ok "created $ADMIN"
fi

# ── What the server renders the proxy's configuration from ────────────────────
step "proxy.json"
sudo tee "$STATE_DIR/proxy.json" > /dev/null << EOF
{
  "domain": "$DOMAIN",
  "auth_domain": "$AUTH_DOMAIN",
  "admin": "$ADMIN",
  "port": $PORT,
  "authelia_port": $AUTHELIA_PORT,
  "https_port": $HTTPS_PORT,
  "http_port": $HTTP_PORT,
  "tls": "$TLS",
  "acme_ca": "$ACME_CA",
  "caddy_bin": "$BIN_DIR/caddy",
  "authelia_bin": "$BIN_DIR/authelia",
  "caddyfile": "$CADDY_DIR/Caddyfile",
  "users_file": "$AUTHELIA_DIR/users.yml",
  "acme_email": "$ACME_EMAIL"
}
EOF
sudo chown "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR/proxy.json"
ok "written"

step "Mail"
json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
case $SMTP_MODE in
    new)
        printf '{"host": %s, "port": %s, "username": %s, "password": %s, "sender": %s}\n' \
            "$(json_str "$SMTP_HOST")" "$SMTP_PORT" "$(json_str "$SMTP_USER")" \
            "$(json_str "$SMTP_PASSWORD")" "$(json_str "$SMTP_SENDER")" |
            sudo tee "$STATE_DIR/smtp.json" > /dev/null
        sudo chown "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR/smtp.json"
        sudo chmod 600 "$STATE_DIR/smtp.json"
        # Authelia starts without checking the mail server (a mail outage must not
        # lock everyone out), so a wrong host or port shows here or not at all.
        if timeout 5 bash -c ': > "/dev/tcp/$1/$2"' _ "$SMTP_HOST" "$SMTP_PORT" 2> /dev/null; then
            ok "sending through $SMTP_HOST:$SMTP_PORT"
        else
            info "$SMTP_HOST:$SMTP_PORT does not answer from here: mail fails until it does" \
                 "(Authelia starts anyway; only confirming a new second factor needs mail)"
        fi ;;
    keep) ok "keeping the current settings" ;;
    none)
        sudo rm -f "$STATE_DIR/smtp.json"
        ok "none: Authelia writes its codes to $AUTHELIA_DIR/notifications.txt" ;;
esac

# ── systemd services ──────────────────────────────────────────────────────────
step "systemd services"
sudo tee "/etc/systemd/system/$UNIT_SERVER.service" > /dev/null << EOF
[Unit]
Description=BonitoAgents dashboard server${INSTANCE:+ ($INSTANCE)} (localhost only; Caddy + Authelia in front)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=PATH=$(dirname "$JULIA_BIN"):$BIN_DIR:/usr/local/bin:/usr/bin:/bin
ExecStart=$SERVER_BIN --port $PORT --state-dir $STATE_DIR --working-dir $DATA_DIR/projects
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
# ProtectHome stays off: the service runs as the install user and needs its own
# juliaup lockfile and Julia depot under ~/.julia.
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
# Julia JIT requires writable+executable pages: MemoryDenyWriteExecute stays off.
# ProtectSystem=strict leaves the whole tree read-only, /home included: the depot
# (precompile caches, the juliaup lockfile) has to be named here.
ReadWritePaths=$DATA_DIR $SERVICE_HOME/.julia

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$UNIT_AUTHELIA.service" > /dev/null << EOF
[Unit]
Description=BonitoAgents login${INSTANCE:+ ($INSTANCE)} (Authelia)
After=network-online.target $UNIT_SERVER.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=$BIN_DIR/authelia --config $AUTHELIA_DIR/configuration.yml
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$AUTHELIA_DIR

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$UNIT_CADDY.service" > /dev/null << EOF
[Unit]
Description=BonitoAgents HTTPS proxy${INSTANCE:+ ($INSTANCE)} (Caddy)
After=network-online.target $UNIT_SERVER.service $UNIT_AUTHELIA.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=XDG_DATA_HOME=$CADDY_DIR/data
Environment=XDG_CONFIG_HOME=$CADDY_DIR/config
# The Caddyfile is rendered by BonitoAgents; --watch rereads it on every change.
# Its admin API is off (the Caddyfile says so): it would let anyone on this
# machine reconfigure Caddy and read the key it adds to every request.
ExecStart=$BIN_DIR/caddy run --config $CADDY_DIR/Caddyfile --adapter caddyfile --watch
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$CADDY_DIR
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$UNIT_SERVER" "$UNIT_AUTHELIA" "$UNIT_CADDY" > /dev/null 2>&1
ok "installed + enabled"

# ── Start: the server first, it renders the proxy's configuration ─────────────
step "Start $UNIT_SERVER"
RENDERED=("$CADDY_DIR/Caddyfile" "$AUTHELIA_DIR/users.yml" "$AUTHELIA_DIR/configuration.yml")
# Set the previous renders aside, so the wait below sees this start's.
for f in "${RENDERED[@]}"; do
    sudo test -f "$f" && sudo mv "$f" "$f.previous"
done
sudo systemctl start "$UNIT_SERVER"
printf "    wait : the server renders the proxy's configuration (a first start precompiles, minutes)"
rendered() { for f in "${RENDERED[@]}"; do sudo test -s "$f" || return 1; done; }
for _ in $(seq 1 600); do
    rendered && break
    sudo systemctl is-active --quiet "$UNIT_SERVER" ||
        { echo; fail "the server stopped: journalctl -u $UNIT_SERVER -e"; }
    printf "."
    sleep 1
done
echo
rendered || fail "the server did not render the proxy's configuration within 10 minutes: journalctl -u $UNIT_SERVER -e"
sudo rm -f "${RENDERED[@]/%/.previous}"
ok "active; configuration rendered"

step "Validate the proxy configuration"
sudo -u "$SERVICE_USER" "$BIN_DIR/authelia" validate-config --config "$AUTHELIA_DIR/configuration.yml" ||
    fail "Authelia rejects $AUTHELIA_DIR/configuration.yml (see above)"
sudo -u "$SERVICE_USER" env XDG_DATA_HOME="$CADDY_DIR/data" XDG_CONFIG_HOME="$CADDY_DIR/config" \
    "$BIN_DIR/caddy" validate --config "$CADDY_DIR/Caddyfile" --adapter caddyfile > /dev/null ||
    fail "Caddy rejects $CADDY_DIR/Caddyfile (see above)"
ok "Authelia and Caddy accept it"

step "Start Authelia and Caddy"
sudo systemctl start "$UNIT_AUTHELIA" "$UNIT_CADDY"
sleep 3
for svc in "$UNIT_AUTHELIA" "$UNIT_CADDY"; do
    sudo systemctl is-active --quiet "$svc" || fail "$svc failed to start: journalctl -u $svc -e"
done
ok "active"

# ── The dashboard answers, through the login ──────────────────────────────────
step "HTTPS"
if [[ $TLS == internal ]]; then
    # Straight to this machine, trusting Caddy's CA for this one request.
    fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -k \
                   --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" "$ORIGIN/" 2> /dev/null || true; }
else
    fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$ORIGIN/" 2> /dev/null || true; }
fi
code=""
for _ in $(seq 1 60); do
    code="$(fetch)"
    [[ "$code" =~ ^(302|303|401)$ ]] && break
    sleep 2
done
if [[ "$code" =~ ^(302|303|401)$ ]]; then
    ok "$ORIGIN answers, and wants a login first ($code)"
else
    info "$ORIGIN is not answering yet (last status: ${code:-none}); Caddy keeps retrying the certificate: journalctl -u $UNIT_CADDY -f"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoAgents: $ORIGIN"
echo "============================================================"
echo ""
if [[ -n "$ADMIN_PASSWORD" ]]; then
    echo "  Admin account : $ADMIN"
    echo "  Password      : $ADMIN_PASSWORD"
    echo "                  (shown only now; \"New password\" on the dashboard replaces it)"
    echo ""
fi
echo "  The first login sets up a second factor (an authenticator app or a security"
echo "  key), confirmed with a one-time code from Authelia."
if [[ "$SMTP_ON" != true ]]; then
    echo "  Without mail that code is written to $AUTHELIA_DIR/notifications.txt"
    echo "  (for your own first login: sudo cat it); afterwards admins find the latest"
    echo "  one under \"Login codes\" on the dashboard."
fi
if [[ $TLS == internal ]]; then
    echo ""
    echo "  Certificates come from Caddy's own CA. Browsers and workers must trust its"
    echo "  root certificate (add it to each machine's system trust store):"
    echo "    $CADDY_DIR/data/caddy/pki/authorities/local/root.crt"
fi
echo ""
echo "  People: \"Invites\" on the dashboard makes a link for one new account."
echo "  Workers: \"Add worker\" on the dashboard issues a credential and prints the"
echo "  install command for the new machine. Workers from an install before the"
echo "  login proxy must be reinstalled that way."
echo ""
echo "  Logs: journalctl -u $UNIT_SERVER -f"
echo "        journalctl -u $UNIT_AUTHELIA -f"
echo "        journalctl -u $UNIT_CADDY -f"
echo ""
echo "  Remove: bash $SCRIPT_DIR/uninstall_server.sh${INSTANCE:+ --instance $INSTANCE}"
echo "          (keeps projects, chats and accounts; --purge deletes them too)"
