#!/usr/bin/env bash
# BonitoAgents server installer: idempotent, Linux + systemd.
# Run as a regular user (sudo is invoked internally for privileged steps):
#
#   bash BonitoAgents/assets/install_server.sh
#
# It asks for what it needs (how the server is reached, its domain, the admin)
# and saves the answers right away, before anything can fail: a
# second run offers them again ("Use these settings?"), and --reconfigure asks
# anew. Every answer can also be given as an option; `--no-prompt` makes a
# missing required one an error instead of a question.
#
# People log in through Authelia: a password plus an authenticator (one-time
# codes; the server registers it and shows it once, so no mail is involved), or a
# passkey added once signed in, with brute-force lockout. BonitoAgents
# listens on 127.0.0.1 and owns the login's configuration: Authelia's users
# database (accounts, and their passwords: Authelia's own password reset is off)
# and Authelia's configuration with its secrets, which it renders whenever it
# starts. This script only writes what they are rendered from: proxy.json, the
# first admin, optional mail settings. Three ways to reach it (`--tls`):
#
#   * tunnel (the default): something in front of this machine brings HTTPS,
#     e.g. a Cloudflare Tunnel, and forwards https://<domain> to
#     http://localhost:8038. That is all it has to do: the server itself asks
#     Authelia about every request and serves the login page under its own name
#     (https://<domain>/authelia). No certificates, DNS records or open ports
#     here; nothing but the server and Authelia runs.
#   * acme: this machine answers on ports 80 and 443 itself. Caddy terminates
#     HTTPS (Let's Encrypt, renewed by itself) and routes the dashboard through
#     Authelia's login, which lives on its own name (auth.<domain>). The
#     machine has to be reachable on both ports under its DNS names (a public
#     IP, DNS records, the router forwarding both ports); the installer checks
#     that before Let's Encrypt is asked for a certificate.
#   * internal: like acme, with certificates from Caddy's own CA: a LAN, or a
#     test on one machine; every browser and worker has to trust its root.
#
# Workers join with a credential "Add worker" on the dashboard issues, one per
# machine: checked by the server behind a tunnel, by Caddy otherwise.
#
# Re-run it to update: services are stopped first; secrets, accounts and the
# mail settings are kept, and binaries are only replaced when their version
# changed.
#
# Options:
#   --tls MODE             tunnel (default), acme or internal: see above
#   --domain NAME          the dashboard's host name, e.g. team.example.com
#   --auth-domain NAME     acme/internal: the login portal's host name (default:
#                          auth.<--domain>); it must sit under --domain's parent,
#                          which the login cookie covers
#   --admin NAME           the first admin account (default: the installing user)
#   --admin-email ADDR     its email address
#   --acme-email ADDR      acme: contact for Let's Encrypt (optional: certificate notices)
#   --acme-staging         acme: certificates from Let's Encrypt's staging CA, for
#                          trying an install out without running into its rate
#                          limits (browsers warn about them)
#   --port PORT            BonitoAgents' port on 127.0.0.1 (default: 8038): what the
#                          tunnel forwards to
#   --https-port PORT      acme/internal: Caddy's HTTPS port (default: 443)
#   --http-port PORT       acme/internal: Caddy's HTTP port (default: 80; Let's Encrypt checks port 80)
#   --authelia-port PORT   Authelia's port on 127.0.0.1 (default: 9091)
#   --smtp-host HOST       lets Authelia send mail: notices about new devices. Not
#   --smtp-port PORT       needed to log in (default port 587); without it Authelia
#   --smtp-user USER       writes them to a file on this machine, which admins read
#   --smtp-password PASS   on the dashboard.
#   --smtp-sender ADDR
#   --no-smtp              drop mail settings kept from a previous install
#   --caddy-version V      default: the latest release
#   --authelia-version V   default: the latest release
#   --skip-port-check      acme: for networks where this machine cannot reach its own
#                          public address (no NAT hairpinning); Let's Encrypt then
#                          reports a closed port itself.
#   --instance NAME        a separate install next to the default one: its own
#                          services (bonitoagents-NAME-*), data and binaries. Give it
#                          its own ports too.
#   --reconfigure          ask everything again (the saved answers are the defaults)
#   --setup-link           a new setup link for the admin (a fresh install makes one):
#                          it sets up their login again, for when it is lost
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
RECONFIGURE=0
SETUP_LINK=0
UPDATE=1
PROMPT=1
GIVEN=0     # answers given as options: no "use the saved settings?" then

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)            DOMAIN="$2";            GIVEN=1; shift 2 ;;
        --auth-domain)       AUTH_DOMAIN="$2";       GIVEN=1; shift 2 ;;
        --admin)             ADMIN="$2";             GIVEN=1; shift 2 ;;
        --admin-email)       ADMIN_EMAIL="$2";       GIVEN=1; shift 2 ;;
        --acme-email)        ACME_EMAIL="$2";        GIVEN=1; shift 2 ;;
        --acme-staging)      ACME_STAGING=1;         GIVEN=1; shift ;;
        --tls)               TLS="$2";               GIVEN=1; shift 2 ;;
        --port)              PORT="$2";              GIVEN=1; shift 2 ;;
        --https-port)        HTTPS_PORT="$2";        GIVEN=1; shift 2 ;;
        --http-port)         HTTP_PORT="$2";         GIVEN=1; shift 2 ;;
        --authelia-port)     AUTHELIA_PORT="$2";     GIVEN=1; shift 2 ;;
        --smtp-host)         SMTP_HOST="$2";         GIVEN=1; shift 2 ;;
        --smtp-port)         SMTP_PORT="$2";         GIVEN=1; shift 2 ;;
        --smtp-user)         SMTP_USER="$2";         GIVEN=1; shift 2 ;;
        --smtp-password)     SMTP_PASSWORD="$2";     GIVEN=1; shift 2 ;;
        --smtp-sender)       SMTP_SENDER="$2";       GIVEN=1; shift 2 ;;
        --no-smtp)           NO_SMTP=1;              GIVEN=1; shift ;;
        --caddy-version)     CADDY_VERSION="$2";     shift 2 ;;
        --authelia-version)  AUTHELIA_VERSION="$2";  shift 2 ;;
        --skip-port-check)   SKIP_PORT_CHECK=1;      shift ;;
        --instance)          INSTANCE="$2";          shift 2 ;;
        --reconfigure)       RECONFIGURE=1;          shift ;;
        --setup-link)        SETUP_LINK=1;           shift ;;
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
# The services run as their own system user, named like the install, whose home
# is the data dir: its own Julia (juliaup) and depot live there. Never as the
# person who installs: a break-in through the dashboard or the login then reaches
# the data dir, not that person's home, keys or sudo. The monorepo stays where it
# was cloned, and the services only read it.
INSTALL_USER="${SUDO_USER:-$USER}"
if [[ -z "$INSTALL_USER" || "$INSTALL_USER" == "root" ]]; then
    fail "cannot determine who installs. Run as a regular user; the script sudo's when needed."
fi
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
[[ -d "$INSTALL_HOME" ]] || fail "$INSTALL_USER's home not found"

[[ -z "$INSTANCE" || "$INSTANCE" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    fail "--instance must be lowercase letters, digits and '-' (got '$INSTANCE')"
NAME="bonitoagents${INSTANCE:+-$INSTANCE}"
SERVICE_USER="$NAME"
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
# The service user's own Julia, installed below at the installer's version.
SERVICE_JULIA="$DATA_DIR/.juliaup/bin/julia"
# The installer's Julia: it updates the monorepo's Manifest and picks the version.
JULIA_BIN="$(command -v julia || true)"
# juliaup puts julia on PATH only inside the user's interactive shell, not under
# sudo or a bare environment: fall back to its well-known locations.
if [[ -z "$JULIA_BIN" ]]; then
    for cand in "$INSTALL_HOME/.juliaup/bin/julia" "$INSTALL_HOME/.local/bin/julia"; do
        [[ -x "$cand" ]] && { JULIA_BIN="$cand"; break; }
    done
fi

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "no Authelia/Caddy builds for this CPU: $(uname -m)" ;;
esac

# ── Answers ───────────────────────────────────────────────────────────────────
# The saved answers (proxy.json, written below as soon as the answers are
# complete, one `"key": value` per line).
SAVED="$STATE_DIR/proxy.json"
previous() {
    sudo test -f "$SAVED" || return 0
    sudo sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$SAVED"
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
yes_no() {   # yes_no "question" default(y|n) -> status
    local reply
    read -r -p "    $1 [$([[ $2 == y ]] && echo Y/n || echo y/N)]: " reply < /dev/tty
    reply="${reply:-$2}"
    [[ "$reply" =~ ^[Yy] ]]
}
# What was not given takes the saved value, else the default.
default() {   # default VAR key fallback
    local var="$1" key="$2" fallback="$3" prev
    [[ -n "${!var}" ]] && return 0
    prev="$(previous "$key")"
    printf -v "$var" '%s' "${prev:-$fallback}"
}

# A run after one that got as far as saving its answers: take them as they are.
USE_SAVED=0
if [[ $PROMPT -eq 1 && $RECONFIGURE -eq 0 && $GIVEN -eq 0 ]] && sudo test -f "$SAVED" &&
   [[ -n "$(previous domain)" ]]; then
    saved_tls="$(previous tls)"
    echo "==> BonitoAgents server setup: the settings from last time ($SAVED)"
    echo "    Dashboard : https://$(previous domain)"
    echo "    Reached   : $(case "$saved_tls" in
        tunnel)   echo "through a tunnel, to http://localhost:$(previous port)" ;;
        internal) echo "directly, with Caddy's own CA" ;;
        *)        echo "directly, on ports 80 and 443 (Let's Encrypt)" ;; esac)"
    echo "    Admin     : $(previous admin)"
    yes_no "Use these settings" y && USE_SAVED=1
    echo
fi

if [[ $PROMPT -eq 1 && $USE_SAVED -eq 0 ]]; then
    echo "==> BonitoAgents server setup (Enter takes the value in brackets)"
    if [[ -z "$TLS" ]]; then
        prev_tls="$(previous tls)"
        echo "    How do people reach this server?"
        echo "      1) through a tunnel (Cloudflare Tunnel or similar) that forwards to http://localhost:${PORT:-8038}"
        echo "      2) directly: this machine answers on ports 80 and 443 (Let's Encrypt)"
        echo "      3) directly, inside a LAN (Caddy's own certificate authority)"
        case "${prev_tls:-tunnel}" in acme) prev_choice=2 ;; internal) prev_choice=3 ;; *) prev_choice=1 ;; esac
        choice=""
        ask choice "Choose 1, 2 or 3" "$prev_choice"
        case "$choice" in
            1) TLS=tunnel ;; 2) TLS=acme ;; 3) TLS=internal ;;
            *) fail "choose 1, 2 or 3 (got '$choice')" ;;
        esac
    fi
    ask DOMAIN "Dashboard domain, e.g. team.example.com" "$(previous domain)"
    if [[ "$TLS" != tunnel ]]; then
        # auth.<domain> by default: the login cookie then covers exactly the
        # dashboard, and it works for any domain, including a dynamic-DNS name.
        prev_auth="$(previous auth_domain)"
        [[ "$(previous domain)" == "$DOMAIN" && -n "$prev_auth" ]] || prev_auth="auth.$DOMAIN"
        ask AUTH_DOMAIN "Login portal domain" "$prev_auth"
    fi
    prev_admin="$(previous admin)"
    ask ADMIN "Admin account" "${prev_admin:-$INSTALL_USER}"
    ask ADMIN_EMAIL "Admin email (optional)" "$(previous admin_email)"
    [[ "$TLS" == acme ]] &&
        ask ACME_EMAIL "Email for Let's Encrypt notices (optional)" "${ADMIN_EMAIL:-$(previous acme_email)}"
fi
default TLS tls tunnel
default DOMAIN domain ""
[[ -n "$DOMAIN" ]] || fail "the dashboard's domain is required: --domain team.example.com"
default ADMIN admin "$INSTALL_USER"
default ADMIN_EMAIL admin_email ""
default PORT port 8038
default AUTHELIA_PORT authelia_port 9091
if [[ "$TLS" == tunnel ]]; then
    # One name: the login page is under it (https://<domain>/authelia).
    AUTH_DOMAIN=""
    ACME_EMAIL=""
    HTTPS_PORT=443
    HTTP_PORT=80
else
    # The saved portal belongs to the saved domain only.
    if [[ -z "$AUTH_DOMAIN" ]]; then
        AUTH_DOMAIN="auth.$DOMAIN"
        [[ "$(previous domain)" == "$DOMAIN" && -n "$(previous auth_domain)" ]] && AUTH_DOMAIN="$(previous auth_domain)"
    fi
    default ACME_EMAIL acme_email ""
    default HTTPS_PORT https_port 443
    default HTTP_PORT http_port 80
fi
[[ -n "$SMTP_PORT" ]] || SMTP_PORT=587
ACME_CA=""
[[ $ACME_STAGING -eq 1 ]] && ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory"

[[ "$TLS" == tunnel || "$TLS" == acme || "$TLS" == internal ]] ||
    fail "--tls is 'tunnel', 'acme' (Let's Encrypt) or 'internal' (got '$TLS')"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || fail "the domain is a host name, e.g. team.example.com (got '$DOMAIN')"
if [[ "$TLS" != tunnel ]]; then
    [[ "$AUTH_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || fail "the login portal's domain is a host name (got '$AUTH_DOMAIN')"
    # Authelia's login cookie has to cover both host names.
    COOKIE_DOMAIN="${AUTH_DOMAIN#*.}"
    [[ "$DOMAIN" == "$COOKIE_DOMAIN" || "$DOMAIN" == *".$COOKIE_DOMAIN" ]] ||
        fail "the dashboard ($DOMAIN) and the login portal ($AUTH_DOMAIN) must share a parent domain ($COOKIE_DOMAIN) for the login cookie"
fi
[[ "$ADMIN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail "the admin account must be letters, digits, '.', '_' and '-' (got '$ADMIN')"
[[ "$ADMIN_EMAIL$ACME_EMAIL$SMTP_SENDER" != *[\"\\\']* ]] ||
    fail "email addresses must not contain quotes or backslashes"
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
ORIGIN="https://$DOMAIN$([[ $HTTPS_PORT == 443 ]] || echo ":$HTTPS_PORT")"
if [[ "$TLS" == tunnel ]]; then
    PORTAL="$ORIGIN/authelia"
else
    PORTAL="https://$AUTH_DOMAIN$([[ $HTTPS_PORT == 443 ]] || echo ":$HTTPS_PORT")"
fi

# ── Save the answers ──────────────────────────────────────────────────────────
# Before anything can go wrong, so a run that stops halfway is not a lost setup:
# the next one offers the same settings again. This is also what the server
# renders the login's configuration from.
step "Service user: $SERVICE_USER"
if getent passwd "$SERVICE_USER" > /dev/null; then
    ok "exists"
else
    sudo useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    ok "created (a system user: no password, no login, home $DATA_DIR)"
fi

step "Data dir: $DATA_DIR"
sudo mkdir -p "$STATE_DIR" "$DATA_DIR/projects" "$AUTHELIA_DIR"
[[ "$TLS" == tunnel ]] || sudo mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config"
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
sudo chmod 750 "$DATA_DIR"
ok "owned by $SERVICE_USER"
if [[ "$TLS" == tunnel ]]; then
    front="$(printf '  "tls": "tunnel",\n')"
else
    front="$(printf '  "auth_domain": "%s",\n  "https_port": %s,\n  "http_port": %s,\n  "tls": "%s",\n  "acme_ca": "%s",\n  "acme_email": "%s",\n  "caddy_bin": "%s",\n  "caddyfile": "%s",' \
        "$AUTH_DOMAIN" "$HTTPS_PORT" "$HTTP_PORT" "$TLS" "$ACME_CA" "$ACME_EMAIL" "$BIN_DIR/caddy" "$CADDY_DIR/Caddyfile")"
fi
sudo tee "$SAVED" > /dev/null << EOF
{
  "domain": "$DOMAIN",
  "admin": "$ADMIN",
  "admin_email": "$ADMIN_EMAIL",
  "port": $PORT,
  "authelia_port": $AUTHELIA_PORT,
$front
  "authelia_bin": "$BIN_DIR/authelia",
  "users_file": "$AUTHELIA_DIR/users.yml"
}
EOF
sudo chown "$SERVICE_USER:$SERVICE_USER" "$SAVED"
ok "settings saved to $SAVED (the next run offers them again)"

echo ""
echo "==> BonitoAgents server installer${INSTANCE:+ (instance $INSTANCE)}"
echo "    Monorepo     : $MONOREPO_DIR"
echo "    Service user : $SERVICE_USER"
echo "    Dashboard    : $ORIGIN"
echo "    Login page   : $PORTAL"
echo "    Admin        : $ADMIN"
case "$TLS" in
    tunnel)   echo "    HTTPS        : a tunnel, forwarding $ORIGIN to http://localhost:$PORT" ;;
    internal) echo "    HTTPS        : Caddy, with its own CA" ;;
    acme)     echo "    HTTPS        : Caddy, with Let's Encrypt${ACME_CA:+ (staging)}" ;;
esac
[[ $SMTP_MODE == none ]] || echo "    Mail         : $SMTP_MODE"

# ── Sanity checks ─────────────────────────────────────────────────────────────
step "Sanity checks"
[[ -f "$SERVER_BIN" ]] || fail "$SERVER_BIN not found: run from the cloned repo"
[[ -n "$JULIA_BIN" ]]  || fail "julia not found (checked PATH and $INSTALL_HOME/.juliaup/bin): install Julia (juliaup) first"
for tool in sudo curl tar sha256sum sha512sum getent ss systemctl timeout; do
    command -v "$tool" > /dev/null || fail "$tool not found"
done
chmod +x "$MONOREPO_DIR/BonitoAgents/bin/"*
sudo -u "$SERVICE_USER" test -x "$SERVER_BIN" -a -r "$MONOREPO_DIR/Project.toml" ||
    fail "$SERVICE_USER cannot read $MONOREPO_DIR. Let others through the folders above it (e.g. chmod o+x $INSTALL_HOME: that opens no listing), or clone the monorepo outside your home"
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
# Behind a tunnel there is no Caddy: one left from an install that had it goes.
if [[ "$TLS" == tunnel && -f "/etc/systemd/system/$UNIT_CADDY.service" ]]; then
    sudo systemctl disable "$UNIT_CADDY" > /dev/null 2>&1 || true
    sudo rm -f "/etc/systemd/system/$UNIT_CADDY.service"
    sudo systemctl daemon-reload
    ok "removed $UNIT_CADDY (a tunnel needs no Caddy)"
fi

# ── Reachability ──────────────────────────────────────────────────────────────
step "Reachability"
if [[ "$TLS" == tunnel ]]; then
    PORTS=("$PORT" "$AUTHELIA_PORT")
else
    PORTS=("$HTTP_PORT" "$HTTPS_PORT" "$PORT" "$AUTHELIA_PORT")
fi
for p in "${PORTS[@]}"; do
    holder="$(sudo ss -Hltnp "sport = :$p" | head -1 || true)"
    [[ -z "$holder" ]] || fail "port $p is already in use on this machine: $holder"
done
ok "ports ${PORTS[*]} are free here"
# Before anything asks Let's Encrypt for a certificate: a failed ACME attempt
# only says "timeout", and repeated failures are rate-limited for an hour.
# Caddy's own CA needs neither DNS nor open ports, and a tunnel brings its own.
if [[ $TLS == acme ]]; then
    PUBLIC_IP="$(curl -fsS4 --max-time 10 https://api.ipify.org || true)"
    [[ -n "$PUBLIC_IP" ]] || fail "could not determine this machine's public IPv4 address (https://api.ipify.org)"
    ok "public address: $PUBLIC_IP"
    for name in "$DOMAIN" "$AUTH_DOMAIN"; do
        ips="$(getent ahostsv4 "$name" | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
        [[ -n "$ips" ]] || fail "$name does not resolve. Add a DNS A record for it pointing at $PUBLIC_IP."
        [[ " $ips" == *" $PUBLIC_IP "* ]] ||
            fail "$name resolves to $ips, but this machine's public address is $PUBLIC_IP. Point its A record here (and wait for DNS to catch up). If a tunnel (e.g. Cloudflare's) brings it here instead, rerun with --tls tunnel."
        ok "$name → $PUBLIC_IP"
    done
elif [[ $TLS == internal ]]; then
    info "Caddy's own CA: no DNS or open ports needed"
else
    info "a tunnel: no DNS, certificates or open ports needed here"
fi

# ── Authelia (+ Caddy) binaries ───────────────────────────────────────────────
latest_tag() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

if [[ "$TLS" != tunnel ]]; then
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
if [[ $TLS != acme ]]; then
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

# An install from before the login had one secret shared by every worker; each
# worker now has its own credential ("Add worker").
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

# The service user's own Julia, the same version as the installer's, and its own
# depot: both in its home, the data dir. What the server needs is precompiled
# here, so its first start is not a long silent wait.
step "Julia for $SERVICE_USER"
as_service() { sudo -u "$SERVICE_USER" env -C "$DATA_DIR" HOME="$DATA_DIR" "$@"; }
JULIA_VERSION="$("$JULIA_BIN" --version | awk '{print $3}')"
[[ -n "$JULIA_VERSION" ]] || fail "could not read the version of $JULIA_BIN"
JULIAUP="$DATA_DIR/.juliaup/bin/juliaup"
if ! sudo test -x "$JULIAUP"; then
    # Its installer refuses a folder that exists, and still exits 0: one left by
    # a run that stopped halfway goes first, and the result is checked.
    sudo rm -rf "$DATA_DIR/.juliaup"
    curl -fsSL https://install.julialang.org |
        as_service sh -s -- --yes --path "$DATA_DIR/.juliaup" --add-to-path no --startup-selfupdate 0
    sudo test -x "$JULIAUP" || fail "juliaup did not install into $DATA_DIR/.juliaup (see above)"
    ok "juliaup installed"
fi
as_service "$JULIAUP" status | grep -Eq "^\s*\*?\s+$JULIA_VERSION\s" || as_service "$JULIAUP" add "$JULIA_VERSION"
as_service "$JULIAUP" default "$JULIA_VERSION"
ok "julia $JULIA_VERSION"
# The server reads the monorepo's git state (which build workers should run).
# git refuses a repository someone else owns unless it is named as safe.
as_service git config --global --get-all safe.directory 2> /dev/null | grep -qxF "$MONOREPO_DIR" ||
    as_service git config --global --add safe.directory "$MONOREPO_DIR"
as_service "$SERVICE_JULIA" "--project=$MONOREPO_DIR" --startup-file=no \
    -e 'import Pkg; Pkg.instantiate(); using BonitoAgents'
ok "packages installed and precompiled"

# ── The first admin ───────────────────────────────────────────────────────────
# The server owns the accounts (accounts.json) and renders Authelia's users
# database from them. Only a fresh install gets its admin here, with a password
# nobody sees: the admin sets up their login with a setup link instead (a
# passkey, or a password and an authenticator), which the server files when it
# starts. `--setup-link` makes a new one.
step "Admin account"
ACCOUNTS="$STATE_DIR/accounts.json"
SETUP_URL=""
if sudo test -s "$ACCOUNTS"; then
    ok "keeping the existing accounts"
else
    out="$("$BIN_DIR/authelia" crypto hash generate argon2 --random --random.length 32)"
    hash="$(printf '%s\n' "$out" | sed -n 's/^Digest: *//p')"
    [[ -n "$hash" ]] || fail "authelia did not generate a password: $out"
    printf '[{"name":"%s","display_name":"%s","email":"%s","groups":["admins"],"disabled":false,"password_hash":"%s"}]\n' \
        "$ADMIN" "$ADMIN" "$ADMIN_EMAIL" "$hash" | sudo tee "$ACCOUNTS" > /dev/null
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$ACCOUNTS"
    sudo chmod 600 "$ACCOUNTS"
    ok "created $ADMIN"
    SETUP_LINK=1
fi
if [[ $SETUP_LINK -eq 1 ]]; then
    token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '{"account": "%s", "token_sha256": "%s", "expires": "%s"}\n' "$ADMIN" \
        "$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)" "$(date -u -d '+7 days' '+%Y-%m-%dT%H:%M:%S')" |
        sudo tee "$STATE_DIR/setup_link.json" > /dev/null
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR/setup_link.json"
    sudo chmod 600 "$STATE_DIR/setup_link.json"
    SETUP_URL="$ORIGIN/invite/$token"
    ok "setup link for $ADMIN made (shown at the end, once; valid for 7 days)"
fi

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
if [[ "$TLS" == tunnel ]]; then
    in_front="the tunnel forwards to it, it asks Authelia"
else
    in_front="Caddy + Authelia in front"
fi
sudo tee "/etc/systemd/system/$UNIT_SERVER.service" > /dev/null << EOF
[Unit]
Description=BonitoAgents dashboard server${INSTANCE:+ ($INSTANCE)} (localhost only; $in_front)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=PATH=$(dirname "$SERVICE_JULIA"):$BIN_DIR:/usr/local/bin:/usr/bin:/bin
ExecStart=$SERVER_BIN --state-dir $STATE_DIR --working-dir $DATA_DIR/projects
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
ProtectSystem=strict
# /home only to read the monorepo, which may live there.
ProtectHome=read-only
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
LockPersonality=true
# Julia JIT requires writable+executable pages: MemoryDenyWriteExecute stays off.
# ProtectSystem=strict leaves the whole tree read-only: the data dir, which holds
# the service user's Julia and depot too, is the one place it writes.
ReadWritePaths=$DATA_DIR

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

UNITS=("$UNIT_SERVER" "$UNIT_AUTHELIA")
if [[ "$TLS" != tunnel ]]; then
    UNITS+=("$UNIT_CADDY")
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
fi
sudo systemctl daemon-reload
sudo systemctl enable "${UNITS[@]}" > /dev/null 2>&1
ok "installed + enabled: ${UNITS[*]}"

# ── Start: the server first, it renders the login's configuration ─────────────
step "Start $UNIT_SERVER"
RENDERED=("$AUTHELIA_DIR/users.yml" "$AUTHELIA_DIR/configuration.yml")
[[ "$TLS" == tunnel ]] || RENDERED+=("$CADDY_DIR/Caddyfile")
# Set the previous renders aside, so the wait below sees this start's.
for f in "${RENDERED[@]}"; do
    sudo test -f "$f" && sudo mv "$f" "$f.previous"
done
sudo systemctl start "$UNIT_SERVER"
printf "    wait : the server renders the login's configuration (a first start precompiles, minutes)"
rendered() { for f in "${RENDERED[@]}"; do sudo test -s "$f" || return 1; done; }
for _ in $(seq 1 600); do
    rendered && break
    sudo systemctl is-active --quiet "$UNIT_SERVER" ||
        { echo; fail "the server stopped: journalctl -u $UNIT_SERVER -e"; }
    printf "."
    sleep 1
done
echo
rendered || fail "the server did not render the login's configuration within 10 minutes: journalctl -u $UNIT_SERVER -e"
sudo rm -f "${RENDERED[@]/%/.previous}"
ok "active; configuration rendered"

step "Validate the configuration"
sudo -u "$SERVICE_USER" "$BIN_DIR/authelia" validate-config --config "$AUTHELIA_DIR/configuration.yml" ||
    fail "Authelia rejects $AUTHELIA_DIR/configuration.yml (see above)"
if [[ "$TLS" != tunnel ]]; then
    sudo -u "$SERVICE_USER" env XDG_DATA_HOME="$CADDY_DIR/data" XDG_CONFIG_HOME="$CADDY_DIR/config" \
        "$BIN_DIR/caddy" validate --config "$CADDY_DIR/Caddyfile" --adapter caddyfile > /dev/null ||
        fail "Caddy rejects $CADDY_DIR/Caddyfile (see above)"
    ok "Authelia and Caddy accept it"
else
    ok "Authelia accepts it"
fi

step "Start ${UNITS[*]:1}"
sudo systemctl start "${UNITS[@]:1}"
sleep 3
for svc in "${UNITS[@]:1}"; do
    sudo systemctl is-active --quiet "$svc" || fail "$svc failed to start: journalctl -u $svc -e"
done
ok "active"

# ── The dashboard answers, through the login ──────────────────────────────────
wants_login() { [[ "$1" =~ ^(302|303|401)$ ]]; }
if [[ "$TLS" == tunnel ]]; then
    step "The server, as the tunnel reaches it"
    code=""
    for _ in $(seq 1 60); do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" 2> /dev/null || true)"
        wants_login "$code" && break
        sleep 2
    done
    wants_login "$code" ||
        fail "http://127.0.0.1:$PORT/ does not ask for a login (last status: ${code:-none}): journalctl -u $UNIT_SERVER -e"
    ok "http://127.0.0.1:$PORT/ answers, and wants a login first ($code)"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/authelia/" 2> /dev/null || true)"
    [[ "$code" == 200 ]] || fail "the login page http://127.0.0.1:$PORT/authelia/ answers ${code:-nothing}: journalctl -u $UNIT_AUTHELIA -e"
    ok "the login page answers"
    step "Through the tunnel"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$ORIGIN/" 2> /dev/null || true)"
    if wants_login "$code"; then
        ok "$ORIGIN answers through the tunnel, and wants a login first ($code)"
    else
        info "$ORIGIN does not lead here yet (status: ${code:-none}). Point the tunnel's public hostname"
        info "$DOMAIN at http://localhost:$PORT (cloudflared: \`service: http://localhost:$PORT\`)."
    fi
else
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
        wants_login "$code" && break
        sleep 2
    done
    if wants_login "$code"; then
        ok "$ORIGIN answers, and wants a login first ($code)"
    else
        info "$ORIGIN is not answering yet (last status: ${code:-none}); Caddy keeps retrying the certificate: journalctl -u $UNIT_CADDY -f"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BonitoAgents: $ORIGIN"
echo "============================================================"
echo ""
if [[ -n "$SETUP_URL" ]]; then
    echo "  Set up your login ($ADMIN), once, within 7 days:"
    echo "    $SETUP_URL"
    echo "  It makes your passkey (Proton Pass, a security key, your phone): from then on"
    echo "  the passkey alone signs you in. Lost access? install_server.sh --setup-link"
    echo ""
fi
if [[ "$TLS" == tunnel ]]; then
    echo "  The tunnel forwards $ORIGIN to http://localhost:$PORT; the login page is"
    echo "  $PORTAL, under the same name. Nothing else needs to be exposed."
    echo ""
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
echo "  login must be reinstalled that way."
echo ""
echo "  Logs: journalctl -u $UNIT_SERVER -f"
echo "        journalctl -u $UNIT_AUTHELIA -f"
[[ "$TLS" == tunnel ]] || echo "        journalctl -u $UNIT_CADDY -f"
echo ""
echo "  Change the settings: bash $SCRIPT_DIR/install_server.sh --reconfigure${INSTANCE:+ --instance $INSTANCE}"
echo "  Remove: bash $SCRIPT_DIR/uninstall_server.sh${INSTANCE:+ --instance $INSTANCE}"
echo "          (keeps projects, chats and accounts; --purge deletes them too)"
