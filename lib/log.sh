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
