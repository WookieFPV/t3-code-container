#!/usr/bin/env bash
# Output helpers. Sourced by every role, so it must stay dependency-free.

header() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
log()    { printf '    %s\n' "$*"; }
ok()     { printf '    \033[32mok\033[0m %s\n' "$*"; }
warn()   { printf '    \033[33mwarn\033[0m %s\n' "$*" >&2; }
die()    { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# skip REASON — a role (or part of one) that does not apply here.
# Distinct from warn: nothing is wrong, this platform just does not need it.
skip()   { printf '    \033[90mskip\033[0m %s\n' "$*"; }

# run_quiet DESC CMD... — run a command whose own output is noise on success
# (apt, npm, installers). Nothing is printed while it works; on failure the
# captured log is replayed to stderr and the run dies with DESC. Callers print
# their own ok/version line after a success.
run_quiet() {
    local desc=$1; shift
    local tmp
    tmp=$(mktemp) || die "mktemp failed"
    if "$@" >"$tmp" 2>&1; then
        rm -f "$tmp"
    else
        cat "$tmp" >&2
        rm -f "$tmp"
        die "$desc failed"
    fi
}
