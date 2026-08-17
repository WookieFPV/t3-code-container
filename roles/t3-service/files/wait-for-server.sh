#!/usr/bin/env bash
# wait-for-server.sh T3_HOME — verify that the server behind t3code.service
# actually came up: a live pid in server-runtime.json, which the server writes
# once it is listening.
#
# `t3 service install` exits 0 as soon as the unit is written and the runtime
# is staged. The unit runs a launcher and the launcher runs the pinned runtime
# as a child, so anything that kills the child — a failed migration, a port
# already bound, an unreadable database — shows as five restarts inside
# StartLimitIntervalSec=300 and then a unit sitting in failed. From outside
# that looks like a clean provision — right up until first-login is the thing
# that discovers it, after an OAuth flow and several minutes. The node-pty
# check (check-pinned-runtime.sh) covers one such cause; this is the general
# case.
#
# server-runtime.json's `pid` is the process that wrote the file, so "exists,
# with a live pid" separates a running server from a started unit.
# Deliberately not a freshness check: `t3 service install` reports no change
# and leaves the unit alone when it is already current, and on that path the
# file legitimately predates this run.
set -uo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 T3_HOME"

t3_home=$1
runtime_json="$t3_home/userdata/server-runtime.json"
service_log="$t3_home/userdata/logs/boot-service.log"

: "${SERVER_WAIT_SECONDS:=45}"

command -v node >/dev/null || die "node is not on PATH"

printf 'waiting for the server to report itself listening (up to %ss)\n' \
    "$SERVER_WAIT_SECONDS"
deadline=$((SECONDS + SERVER_WAIT_SECONDS))
while :; do
    if ! systemctl --user is-active --quiet t3code.service; then
        die "t3code.service is not running after 't3 service install'.
    The install wrote the unit and staged the runtime; the server behind it is
    what did not come up:
        tail -n 50 $service_log
        systemctl --user status t3code.service"
    fi
    # One node process for both facts, so the pid cannot go away between
    # reading the file and signalling it. Signal 0 only checks existence.
    if node -e "
        const s = require('fs').readFileSync('$runtime_json', 'utf8');
        process.kill(JSON.parse(s).pid, 0);
    " 2>/dev/null; then
        origin=$(node -p \
            "JSON.parse(require('fs').readFileSync('$runtime_json','utf8')).origin" \
            2>/dev/null || echo '?')
        printf 'server listening on %s\n' "$origin"
        exit 0
    fi
    if ((SECONDS >= deadline)); then
        die "t3code.service is active but the server never reported itself
    listening (no live pid in $runtime_json after ${SERVER_WAIT_SECONDS}s).
    The unit starts a launcher, which starts the pinned runtime — that is the
    part that did not come up:
        tail -n 50 $service_log
        systemctl --user status t3code.service"
    fi
    sleep 1
done
