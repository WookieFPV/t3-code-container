#!/usr/bin/env bash
# Install, then install again, and assert the second run changed nothing.
#
#   sudo ./test/install-check.sh --only base
#   sudo ./test/install-check.sh --profile minimal
#
# Idempotency is the property this repo claims. The bash implementation had to
# assert it by grepping its own output for "installing:" and "wrote /", because
# nothing else knew whether a step had acted. Ansible tracks that per task, so
# the assertion is now the thing Ansible already prints: changed=0 in the recap
# of the second run.
#
# Destructive by design — it creates users and installs packages. Run it in a
# throwaway container, which is what CI does.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID -eq 0 ]] || { echo "run as root — this installs packages" >&2; exit 2; }
[[ $# -gt 0 ]] || { echo "usage: $0 <provision.sh arguments...>" >&2; exit 2; }

second=$(mktemp)
trap 'rm -f "$second"' EXIT

echo "### first run: provision.sh $*"
"$REPO_DIR/provision.sh" "$@" || { echo "FAIL: first run exited non-zero" >&2; exit 1; }

echo
echo "### second run (must be a no-op): provision.sh $*"
"$REPO_DIR/provision.sh" "$@" 2>&1 | tee "$second"
rc=${PIPESTATUS[0]}
[[ $rc -eq 0 ]] || { echo "FAIL: second run exited $rc" >&2; exit 1; }

echo
# The recap line looks like:
#   localhost : ok=42 changed=0 unreachable=0 failed=0 skipped=7 ...
recap=$(grep -E '^[^ ]+ +: +ok=' "$second" | tail -1)
[[ -n $recap ]] || { echo "FAIL: no play recap in the second run's output" >&2; exit 1; }

changed=$(sed -n 's/.*changed=\([0-9]\+\).*/\1/p' <<<"$recap")
failed=$(sed -n 's/.*failed=\([0-9]\+\).*/\1/p' <<<"$recap")

echo "recap: $recap"

if [[ ${failed:-1} -ne 0 ]]; then
    echo "FAIL: the second run had failed tasks" >&2
    exit 1
fi

if [[ ${changed:-1} -ne 0 ]]; then
    echo "FAIL: the second run was not a no-op — changed=$changed" >&2
    echo "      the tasks that reported a change:" >&2
    # Ansible's yaml callback prints "changed: [localhost]" under the task name,
    # so the task name is the last "TASK [...]" line before each of them.
    awk '
        /^TASK \[/ { task = $0 }
        /^changed: \[/ { print "      " task }
    ' "$second" | sort -u >&2
    exit 1
fi

echo "PASS: converged — the second run changed nothing"
