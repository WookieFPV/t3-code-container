#!/usr/bin/env bash
# Install, then install again, and assert the second run changed nothing.
#
#   sudo ./test/install-check.sh --only base
#   sudo ./test/install-check.sh --profile minimal
#
# Idempotency is the property this repo claims and the one nothing used to
# check. It is asserted from the output rather than by diffing the filesystem,
# because the helpers already say precisely when they act: pkg_install logs
# "installing:", install_file logs "wrote". A converged run emits neither.
#
# Destructive by design — it creates users and installs packages. Run it in a
# throwaway container, which is what CI does.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo "run as root — this installs packages" >&2; exit 2; }
[[ $# -gt 0 ]] || { echo "usage: $0 <setup.sh arguments...>" >&2; exit 2; }

second=$(mktemp)
trap 'rm -f "$second"' EXIT

echo "### first run: setup.sh $*"
"$REPO_DIR/setup.sh" "$@" || { echo "FAIL: first run exited non-zero" >&2; exit 1; }

echo
echo "### second run (must be a no-op): setup.sh $*"
"$REPO_DIR/setup.sh" "$@" 2>&1 | tee "$second"
rc=${PIPESTATUS[0]}
[[ $rc -eq 0 ]] || { echo "FAIL: second run exited $rc" >&2; exit 1; }

echo
# Both patterns are anchored to how the helpers format their output, so an
# unrelated line mentioning "wrote" in prose cannot trip this.
if changes=$(grep -nE '^ +(installing:|.*\bwrote /)' "$second"); then
    echo "FAIL: the second run was not a no-op:" >&2
    printf '%s\n' "$changes" >&2
    exit 1
fi

echo "PASS: converged — the second run installed nothing and wrote nothing"
