#!/usr/bin/env bash
#
# test-gatelink-tunnel.sh — checks that the root wrapper rejects bad input and
# unapproved portals, and stops openconnect when the app's stdin lifeline
# closes or the wrapper is told to stop. Runs unprivileged against a fake
# openconnect.
#
set -euo pipefail

WRAPPER="$(cd "$(dirname "$0")" && pwd)/gatelink-tunnel"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
export GATELINK_TEST_NONROOT=1 GATELINK_HELPER_BASE="$BASE" GATELINK_TUNNEL_PIDFILE="$BASE/pid"

cat > "$BASE/openconnect" <<'FAKE'
#!/bin/bash
IFS= read -r cookie
echo "cookie=${cookie}" > "${GATELINK_HELPER_BASE}/seen"
echo $$ > "${GATELINK_HELPER_BASE}/oc.pid"
while :; do sleep 0.1; done
FAKE
printf '#!/bin/sh\n' > "$BASE/vpnc-script"
printf 'vpn.example.com\n' > "$BASE/allowed-gateways"
chmod +x "$BASE/openconnect" "$BASE/vpnc-script"

fail() { echo "FAIL: $*" >&2; exit 1; }

wait_for() { # condition, seconds
    local i
    for ((i = 0; i < $2 * 10; i++)); do eval "$1" && return 0; sleep 0.1; done
    return 1
}

start() { # opens the lifeline on fd 4 and starts the wrapper
    rm -f "$BASE/seen" "$BASE/oc.pid" "$BASE/fifo"
    mkfifo "$BASE/fifo"
    "$WRAPPER" connect --host vpn.example.com --fingerprint pin-sha256:AbC= < "$BASE/fifo" &
    WRAPPER_PID=$!
    exec 4>"$BASE/fifo"
    echo "authcookie=abc" >&4
    wait_for '[[ -s "$BASE/oc.pid" ]]' 5 || fail "openconnect did not start"
    OC_PID="$(cat "$BASE/oc.pid")"
}

# 1. Bad input and unapproved portals are refused before openconnect starts.
rejects() { # description, wrapper arguments...
    local why="$1" status=0
    shift
    echo "authcookie=abc" | "$WRAPPER" "$@" >/dev/null 2>&1 || status=$?
    [[ "$status" -eq 64 ]] || fail "accepted $why (exit $status)"
    [[ ! -e "$BASE/oc.pid" ]] || fail "openconnect started for $why"
}
rm -f "$BASE/oc.pid"
rejects "an unapproved portal" connect --host attacker.example --fingerprint pin-sha256:AbC=
rejects "a host that is an option" connect --host -oProxy=x --fingerprint pin-sha256:AbC=
rejects "a host with a path" connect --host vpn.example.com/x --fingerprint pin-sha256:AbC=
rejects "a fingerprint that is an option" connect --host vpn.example.com --fingerprint --script=/tmp/x
rejects "an extra option" connect --host vpn.example.com --fingerprint pin-sha256:AbC= --script /tmp/x
rejects "a removed command" status
echo "ok: bad input and unapproved portals are refused"

# 2. openconnect gets the cookie; closing the lifeline stops it.
start
grep -qx "cookie=authcookie=abc" "$BASE/seen" || fail "cookie not passed to openconnect"
kill -0 "$OC_PID" || fail "openconnect exited early"
exec 4>&-
wait_for '! kill -0 "$OC_PID" 2>/dev/null' 5 || fail "openconnect still running after the lifeline closed"
wait_for '! kill -0 "$WRAPPER_PID" 2>/dev/null' 5 || fail "wrapper still running after the lifeline closed"
echo "ok: lifeline EOF stops the tunnel"

# 3. SIGTERM to the wrapper (the app's process.terminate()) stops openconnect.
start
kill -TERM "$WRAPPER_PID"
wait_for '! kill -0 "$OC_PID" 2>/dev/null' 5 || fail "openconnect still running after SIGTERM"
exec 4>&-
echo "ok: SIGTERM stops the tunnel"
