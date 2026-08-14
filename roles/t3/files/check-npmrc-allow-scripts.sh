#!/usr/bin/env bash
# check-npmrc-allow-scripts.sh NPMRC DEP[,DEP...] — verify that the app user's
# .npmrc really allows install scripts for the given packages.
#
# This is the check that catches the most expensive failure in the whole repo,
# so it is a script you can run by hand rather than a condition buried in a
# playbook:
#
#   ./roles/t3/files/check-npmrc-allow-scripts.sh ~/.npmrc node-pty,msgpackr-extract
#
# Why the file and not just the variable. `t3 service install` and the in-app
# self-update both build a pinned runtime with a project-scoped
#
#   npm install --prefix <staging> --no-fund --no-audit t3@<version>
#
# and npm 12 rejects --allow-scripts outright for a project-scoped install like
# that ("Add the entries to the allowScripts field in package.json, or to
# .npmrc, instead"). So the allowlist has to be in .npmrc; a flag on our own
# command line covers only the installs this repo types itself.
#
# The two diverge on any box whose .npmrc was written by a run where the
# allowlist was empty: the file keeps the `prefix=` line it got then, only the
# node role would add the rest, and a --tags t3 run that skips node never
# revisits it. The global `npm i -g` still succeeds because it passes the flag,
# so every other check reads healthy and the breakage surfaces much later as a
# server that crash-loops on a node-pty it never compiled.
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 NPMRC DEP[,DEP...]"

npmrc=$1 required=$2

# Last assignment wins in an npmrc, so read the same value npm would.
allowed=$(sed -n 's/^allow-scripts=//p' "$npmrc" 2>/dev/null | tail -n 1)

missing=()
for dep in ${required//,/ }; do
    [[ ,$allowed, == *,$dep,* ]] || missing+=("$dep")
done

if [[ ${#missing[@]} -gt 0 ]]; then
    die "$npmrc allows install scripts for '${allowed:-nothing}', which does not
    include: ${missing[*]}
    Without them node-pty never runs node-gyp and t3code.service crash-loops at
    startup, however healthy 't3 service install' looks. Re-run
        ./provision.sh --only node,t3
    to have the node role write the line."
fi

printf '%s allows install scripts for: %s\n' "$npmrc" "$allowed"
