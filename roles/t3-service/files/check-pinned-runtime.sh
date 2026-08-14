#!/usr/bin/env bash
# check-pinned-runtime.sh T3_HOME — verify that the runtime t3code.service will
# actually boot can load node-pty.
#
# `t3 service install` exits 0 as soon as the unit is written and the runtime is
# staged. A runtime whose node-pty install script was blocked stages perfectly
# and only fails when the server starts: NodePtyModuleLoadError, systemd
# restarts it five times, then "start request repeated too quickly", and the
# unit sits in failed. From outside that looks like a clean provision — right up
# until `t3 connect status` says "Environment link: pending server startup"
# forever.
#
# t3's own validation is `node <entry> --version`, which does not load node-pty
# and so passes. node-pty ships prebuilds for darwin and win32 only, so on Linux
# the native module exists exactly when the build ran. Load it the way the
# server does, from the runtime the launcher will actually execute.
#
# Run it directly when a container comes up unreachable:
#
#   ./check-pinned-runtime.sh ~/.t3
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

[[ $# -eq 1 ]] || die "usage: $0 T3_HOME"

t3_home=$1
state="$t3_home/runtime/service-state.json"

command -v node >/dev/null || die "node is not on PATH"

active=$(node -p \
    "JSON.parse(require('fs').readFileSync('$state','utf8')).activeVersion ?? ''" \
    2>/dev/null) || active=""

if [[ -z $active ]]; then
    warn "could not read activeVersion from $state — skipping the node-pty check"
    exit 0
fi

module="$t3_home/runtime/versions/$active/node_modules/node-pty"

if node -e "require('$module')" 2>/dev/null; then
    printf 'pinned runtime %s loads node-pty\n' "$active"
    exit 0
fi

die "the pinned runtime $active cannot load node-pty, so t3code.service will
    crash-loop at startup however healthy 'service install' looked.
    Almost always a blocked npm install script: check that ~/.npmrc carries
    'allow-scripts=node-pty,msgpackr-extract' (the node role writes it), then
    rebuild the module in place:
        npm rebuild node-pty --prefix $t3_home/runtime/versions/$active
    and restart with 'systemctl --user restart t3code.service'."
