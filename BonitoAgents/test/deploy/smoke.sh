#!/usr/bin/env bash
# From any machine: is a deployed server reachable, and locked the way it should be?
#
#   bash BonitoAgents/test/deploy/smoke.sh https://team.example.com [--staging]
#
# `--staging`: the install used Let's Encrypt's staging CA (`install_server.sh
# --acme-staging`), whose certificates no browser trusts; they are checked for
# the right issuer instead.
#
# Covers what only a real deployment can: DNS, the router, the certificate. The
# login itself is then worth one manual pass (the admin's first login with the
# second factor, an invite, a worker added with "Add worker").
set -uo pipefail

ORIGIN="${1:?usage: smoke.sh https://team.example.com [--staging]}"
ORIGIN="${ORIGIN%/}"
STAGING=0; [[ "${2:-}" == --staging ]] && STAGING=1
HOST="${ORIGIN#https://}"; HOST="${HOST%%/*}"
CURL=(curl -sS --max-time 15); [[ $STAGING -eq 1 ]] && CURL+=(-k)

failures=0
check() {   # check "what" command...
    local what="$1"; shift
    if "$@"; then echo "  PASS  $what"; else echo "  FAIL  $what"; failures=$((failures + 1)); fi
}
status()   { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$1" 2> /dev/null; }
location() { "${CURL[@]}" -o /dev/null -w '%{redirect_url}' "$1" 2> /dev/null; }
in_list()  { local x="$1"; shift; [[ " $* " == *" $x "* ]]; }

issuer="$(echo | openssl s_client -connect "$HOST" -servername "${HOST%%:*}" 2> /dev/null |
          openssl x509 -noout -issuer 2> /dev/null)"
if [[ $STAGING -eq 1 ]]; then
    check "the certificate is from Let's Encrypt's staging CA ($issuer)" grep -qiE "staging|fake" <<< "$issuer"
else
    check "the certificate is from Let's Encrypt ($issuer)" grep -qi "let's encrypt" <<< "$issuer"
    check "the certificate is trusted" test "$(status "$ORIGIN/install.sh")" = 200
fi
check "plain HTTP goes to HTTPS" in_list "$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "http://${HOST%%:*}/")" 301 302 308
check "the dashboard wants a login" in_list "$(status "$ORIGIN/")" 302 303 401
login="$(location "$ORIGIN/")"
check "which is Authelia's portal ($login)" test -n "$login"
[[ -n "$login" ]] && check "the portal answers" test "$(status "$login")" = 200
check "the worker installer is public" test "$(status "$ORIGIN/install.sh")" = 200
check "and points here" grep -q "$ORIGIN" <("${CURL[@]}" "$ORIGIN/install.sh")
check "/w refuses a worker without a credential" in_list "$(status "$ORIGIN/w")" 401 403
check "no invite without its link" test "$(status "$ORIGIN/invite/$(printf '0%.0s' {1..64})")" = 404

echo ""
if [[ $failures -eq 0 ]]; then echo "==> $ORIGIN looks right"; else echo "==> $failures check(s) failed"; fi
exit $((failures > 0))
