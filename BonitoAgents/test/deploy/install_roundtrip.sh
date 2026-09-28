#!/usr/bin/env bash
# The server installer, for real, on this machine: install, check, install again
# (an update), check nothing was lost, uninstall, check nothing was left behind.
#
#   bash BonitoAgents/test/deploy/install_roundtrip.sh
#
# It runs `install_server.sh` as a separate instance (its own services, data,
# binaries and ports: nothing of an install already on this machine is touched)
# with Caddy's own CA, so it needs no domain and no open ports. It uses sudo, and
# the first start of the server precompiles, which takes minutes.
#
# The login itself (Authelia's form, second factor, what each account sees) is
# the e2e items' job (`e2e:proxy_*`): they run the same rendered configuration.
# What only this covers is the installer: downloads and checksums, systemd units,
# start order, re-runs and removal.
set -uo pipefail

INSTANCE=roundtrip
DOMAIN=bonitoagents-roundtrip.localhost
PORT=18938 HTTPS_PORT=18943 HTTP_PORT=18980 AUTHELIA_PORT=18991
NAME="bonitoagents-$INSTANCE"
STATE="/var/lib/$NAME/state"
ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../assets" && pwd)"
ORIGIN="https://$DOMAIN:$HTTPS_PORT"

failures=0
check() {   # check "what" command...
    local what="$1"; shift
    if "$@"; then echo "  PASS  $what"; else echo "  FAIL  $what"; failures=$((failures + 1)); fi
}
# Straight to this machine, trusting Caddy's CA for the request.
status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -k --resolve "$1:$HTTPS_PORT:127.0.0.1" "$2" 2> /dev/null; }
body()   { curl -sS --max-time 10 -k --resolve "$1:$HTTPS_PORT:127.0.0.1" "$2" 2> /dev/null; }
in_list() { local x="$1"; shift; [[ " $* " == *" $x "* ]]; }
secrets_digest() { sudo sh -c "cd $STATE && sha256sum proxy_key authelia_jwt_secret authelia_session_secret authelia_storage_key accounts.json url_key"; }

install() {
    bash "$ASSETS/install_server.sh" --instance "$INSTANCE" --domain "$DOMAIN" --admin roundtrip \
        --tls internal --port "$PORT" --https-port "$HTTPS_PORT" --http-port "$HTTP_PORT" \
        --authelia-port "$AUTHELIA_PORT" --no-update --no-prompt
}

checks() {
    for unit in server authelia caddy; do
        check "$NAME-$unit is running" sudo systemctl is-active --quiet "$NAME-$unit"
    done
    check "the dashboard wants a login" in_list "$(status "$DOMAIN" "$ORIGIN/")" 302 303 401
    check "the login portal answers" in_list "$(status "auth.$DOMAIN" "https://auth.$DOMAIN:$HTTPS_PORT/")" 200
    check "the worker installer is public" test "$(status "$DOMAIN" "$ORIGIN/install.sh")" = 200
    check "the worker installer points here" grep -q "$ORIGIN" <(body "$DOMAIN" "$ORIGIN/install.sh")
    check "/w refuses a worker without a credential" in_list "$(status "$DOMAIN" "$ORIGIN/w")" 401 403
    check "the server refuses a forged identity" grep -q "only through its login proxy" \
        <(curl -sS --max-time 10 -H "Remote-User: roundtrip" -H "Remote-Groups: admins" "http://127.0.0.1:$PORT/")
    check "Caddy's admin API is off" bash -c "! curl -s --max-time 3 http://127.0.0.1:2019/config/ > /dev/null"
    check "the proxy's files are private" test "$(sudo stat -c %a "/var/lib/$NAME/caddy/Caddyfile")" = 600
}

echo "==> 1. install"
log1="$(mktemp)"
if ! install 2>&1 | tee "$log1"; then echo "  FAIL  the install itself"; failures=$((failures + 1)); fi
checks
check "the first install prints the admin's password" grep -q "Password      :" "$log1"
before="$(secrets_digest)"

echo "==> 2. install again (an update)"
log2="$(mktemp)"
if ! install 2>&1 | tee "$log2"; then echo "  FAIL  the second install"; failures=$((failures + 1)); fi
checks
check "secrets and accounts are kept" test "$(secrets_digest)" = "$before"
check "no new admin password" bash -c "! grep -q 'Password      :' $log2"

echo "==> 3. uninstall"
bash "$ASSETS/uninstall_server.sh" --instance "$INSTANCE" --yes
for unit in server authelia caddy; do
    check "$NAME-$unit is gone" bash -c "! systemctl cat $NAME-$unit > /dev/null 2>&1"
done
check "its data is gone" test ! -e "/var/lib/$NAME"
check "its binaries are gone" test ! -e "/usr/local/lib/$NAME"
check "nothing listens on its ports" bash -c "! sudo ss -Hltn | grep -qE ':($PORT|$HTTPS_PORT|$HTTP_PORT|$AUTHELIA_PORT)\b'"

echo ""
if [[ $failures -eq 0 ]]; then echo "==> round trip passed"; else echo "==> $failures check(s) failed"; fi
exit $((failures > 0))
