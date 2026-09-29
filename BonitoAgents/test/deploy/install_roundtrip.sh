#!/usr/bin/env bash
# The server installer, for real, on this machine: install, check, install again
# (an update), check nothing was lost; uninstall, check the data stayed, install
# once more over it; then uninstall with --purge, check nothing was left behind.
# Then the same server behind a tunnel: a first run that stops halfway still
# keeps its answers, a second run needs none, Caddy comes and goes with the mode.
#
#   bash BonitoAgents/test/deploy/install_roundtrip.sh
#
# It runs `install_server.sh` as a separate instance (its own services, data,
# binaries and ports: nothing of an install already on this machine is touched)
# with Caddy's own CA or a tunnel, so it needs no domain and no open ports. It
# uses sudo, and the first start of the server precompiles, which takes minutes.
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
check "the first install prints the admin's setup link" grep -qE "$ORIGIN/invite/[0-9a-f]{64}" "$log1"
check "…which the server filed with the invites" sudo test ! -e "$STATE/setup_link.json"
before="$(secrets_digest)"

echo "==> 2. install again (an update)"
log2="$(mktemp)"
if ! install 2>&1 | tee "$log2"; then echo "  FAIL  the second install"; failures=$((failures + 1)); fi
checks
check "secrets and accounts are kept" test "$(secrets_digest)" = "$before"
check "no new setup link" bash -c "! grep -q '/invite/' $log2"

removed() {
    for unit in server authelia caddy; do
        check "$NAME-$unit is gone" bash -c "! systemctl cat $NAME-$unit > /dev/null 2>&1"
    done
    check "its binaries are gone" test ! -e "/usr/local/lib/$NAME"
    check "nothing listens on its ports" bash -c "! sudo ss -Hltn | grep -qE ':($PORT|$HTTPS_PORT|$HTTP_PORT|$AUTHELIA_PORT)\b'"
}

echo "==> 3. uninstall: the services go, the data stays"
bash "$ASSETS/uninstall_server.sh" --instance "$INSTANCE" --yes
removed
check "projects, accounts and secrets are kept" test "$(secrets_digest)" = "$before"

echo "==> 4. install again over the kept data"
log3="$(mktemp)"
if ! install 2>&1 | tee "$log3"; then echo "  FAIL  the install over kept data"; failures=$((failures + 1)); fi
checks
check "secrets and accounts are the same" test "$(secrets_digest)" = "$before"
check "no new setup link" bash -c "! grep -q '/invite/' $log3"

echo "==> 5. uninstall --purge: nothing is left"
bash "$ASSETS/uninstall_server.sh" --instance "$INSTANCE" --purge --yes
removed
check "its data is gone" test ! -e "/var/lib/$NAME"

# ── Behind a tunnel ───────────────────────────────────────────────────────────
# What a tunnel sees: the server's plain port on 127.0.0.1, one host name.
local_status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2> /dev/null; }
tunnel_checks() {
    for unit in server authelia; do
        check "$NAME-$unit is running" sudo systemctl is-active --quiet "$NAME-$unit"
    done
    check "no Caddy behind a tunnel" bash -c "! systemctl cat $NAME-caddy > /dev/null 2>&1"
    check "the dashboard wants a login" test "$(local_status "http://127.0.0.1:$PORT/")" = 302
    check "…on the login page under the same name" grep -q "Location: https://$DOMAIN/authelia/" \
        <(curl -sS -D - -o /dev/null --max-time 10 "http://127.0.0.1:$PORT/")
    check "the login page answers" test "$(local_status "http://127.0.0.1:$PORT/authelia/")" = 200
    check "a forged identity changes nothing" test \
        "$(local_status -H "Remote-User: roundtrip" -H "Remote-Groups: admins" "http://127.0.0.1:$PORT/")" = 302
    check "the worker installer is public, and points at the tunnel" \
        grep -q "https://$DOMAIN" <(curl -sS --max-time 10 "http://127.0.0.1:$PORT/install.sh")
    check "the answers are saved" sudo grep -q '"tls": "tunnel"' "$STATE/proxy.json"
}
tunnel_install() {
    bash "$ASSETS/install_server.sh" --instance "$INSTANCE" "$@" --no-update --no-prompt
}

echo "==> 6. behind a tunnel: a first run that stops halfway keeps its answers"
python3 -m http.server "$PORT" --bind 127.0.0.1 > /dev/null 2>&1 &
squatter=$!
sleep 1
log4="$(mktemp)"
tunnel_install --tls tunnel --domain "$DOMAIN" --admin roundtrip --port "$PORT" \
    --authelia-port "$AUTHELIA_PORT" > "$log4" 2>&1
check "it stops: the tunnel's port is taken" grep -q "port $PORT is already in use" "$log4"
kill "$squatter"; wait "$squatter" 2> /dev/null
check "its answers are saved all the same" sudo grep -q "\"domain\": \"$DOMAIN\"" "$STATE/proxy.json"

echo "==> 7. the next run needs no answers"
log5="$(mktemp)"
if ! tunnel_install 2>&1 | tee "$log5"; then echo "  FAIL  the tunnel install"; failures=$((failures + 1)); fi
tunnel_checks
check "the first install prints the admin's setup link" grep -qE "https://$DOMAIN/invite/[0-9a-f]{64}" "$log5"

echo "==> 8. to Caddy and back: Caddy comes and goes with the mode"
if ! install > /dev/null 2>&1; then echo "  FAIL  the switch to Caddy"; failures=$((failures + 1)); fi
checks
if ! tunnel_install --tls tunnel > /dev/null 2>&1; then echo "  FAIL  the switch back"; failures=$((failures + 1)); fi
tunnel_checks

echo "==> 9. uninstall --purge"
bash "$ASSETS/uninstall_server.sh" --instance "$INSTANCE" --purge --yes
removed
check "its data is gone" test ! -e "/var/lib/$NAME"

echo ""
if [[ $failures -eq 0 ]]; then echo "==> round trip passed"; else echo "==> $failures check(s) failed"; fi
exit $((failures > 0))
