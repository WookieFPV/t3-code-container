#!/usr/bin/env bash
# Every check CI's lint job runs, runnable here with one command.
#
#   ./test/lint.sh
#
# CI runs this same script rather than its own copy of the commands, so the two
# cannot drift. That is the point: this repository has now been pushed twice
# with a lint failure that takes seconds to catch locally and a CI round trip to
# find out about, both times because the linters existed only in the workflow.
#
# It provisions what it needs: any of the four tools that is not already on
# PATH is installed into .venv-lint/ beside the repository (gitignored) and used
# from there. First run costs a minute; afterwards it is about ten seconds.
#
#   --no-bootstrap   fail instead of creating .venv-lint (what CI uses, where
#                    the tools are already installed)
#
# Install it as a pre-commit hook with:
#
#   git config core.hooksPath .githooks
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VENV="$REPO_DIR/.venv-lint"
TOOLS=(yamllint ansible-lint ansible-playbook ansible shellcheck)

bootstrap=1
[[ ${1:-} == --no-bootstrap ]] && bootstrap=0

bold() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; }

cd "$REPO_DIR" || { fail "cannot enter $REPO_DIR"; exit 2; }

# ansible reads the config from the current directory, but only when that
# directory is not world-writable — and it silently ignores it when it is. Name
# it explicitly so a checkout with odd permissions cannot change what is linted.
export ANSIBLE_CONFIG="$REPO_DIR/ansible.cfg"

# ---------------------------------------------------------------- the tools
have_all() {
    local t
    for t in "${TOOLS[@]}"; do command -v "$t" >/dev/null || return 1; done
}

if ! have_all && [[ -x $VENV/bin/yamllint ]]; then
    PATH="$VENV/bin:$PATH"
fi

if ! have_all; then
    if [[ $bootstrap == 0 ]]; then
        printf 'error: missing linters and --no-bootstrap was given.\n' >&2
        printf '  need: %s\n' "${TOOLS[*]}" >&2
        exit 2
    fi

    bold "installing the linters into .venv-lint (first run only)"
    # Debian splits ensurepip into python3-venv, which is often absent. Fall
    # back to a venv without pip and bootstrap pip into it, which needs no root.
    if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
        rm -rf "$VENV"
        python3 -m venv --without-pip "$VENV" ||
            { fail "could not create $VENV"; exit 2; }
        curl -fsSL https://bootstrap.pypa.io/pip/get-pip.py |
            "$VENV/bin/python" - --quiet ||
            { fail "could not bootstrap pip into $VENV"; exit 2; }
    fi
    # The shellcheck-py wheel ships the real binary, so the whole set comes
    # from one place and no distribution package is required.
    #
    # Note: a comment line here must not *begin* with that tool's name — it
    # reads `# <name> ...` as one of its own directives and errors out.
    "$VENV/bin/pip" install --quiet \
        ansible-core ansible-lint yamllint shellcheck-py ||
        { fail "could not install the linters"; exit 2; }
    PATH="$VENV/bin:$PATH"
fi

have_all || { fail "linters still missing after bootstrap: ${TOOLS[*]}"; exit 2; }

# ------------------------------------------------------------------ checks
failed=()
check() {   # check NAME CMD...
    local name=$1; shift
    bold "$name"
    if "$@"; then
        printf '\033[32mok\033[0m %s\n' "$name"
    else
        failed+=("$name")
        fail "$name"
    fi
}

# --severity=warning: the info level is style advice and blocking a merge on it
# trains people to stop reading the output.
shellcheck_all() {
    shellcheck --severity=warning --external-sources --source-path=SCRIPTDIR \
        provision.sh pve/*.sh test/*.sh roles/*/files/*.sh
}

syntax_check_playbooks() {
    local p rc=0
    for p in playbooks/*.yml; do
        printf '    %s\n' "$p"
        ansible-playbook "$p" --syntax-check >/dev/null || rc=1
    done
    return $rc
}

# Ansible only reads group_vars/ when it sits beside the inventory or beside the
# playbook. At the repository root it is ignored *silently*, and every setting
# in it is undefined — which syntax-check and ansible-lint both pass happily.
settings_resolve() {
    local out
    out=$(ansible -i inventory/local.yml localhost \
        -m debug -a "msg={{ app_user }}|{{ npm_prefix }}|{{ npm_major }}" 2>&1) || {
        printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out" | grep -q 'devuser|/home/devuser/.local|12' || {
        printf '%s\n' "$out"; return 1; }
}

# --only is the reason the playbooks carry per-role tags instead of declaring
# role dependencies. If a dependency ever creeps into a meta/main.yml,
# --tags claude silently starts running base and user too.
only_selects_one_role() {
    local tasks
    tasks=$(ansible-playbook playbooks/t3.yml --tags claude --list-tasks 2>&1) || return 1
    grep -q 'claude : Install Claude Code' <<<"$tasks" || return 1
    ! grep -qE '^ +(base|user|node) : ' <<<"$tasks"
}

check "shellcheck"                shellcheck_all
check "unit tests"                "$REPO_DIR/test/unit.sh"
check "yamllint"                  yamllint .
check "playbook syntax"           syntax_check_playbooks
check "shared settings resolve"   settings_resolve
check "--only selects one role"   only_selects_one_role
check "ansible-lint"              ansible-lint

# ------------------------------------------------------------------ report
if [[ ${#failed[@]} -gt 0 ]]; then
    printf '\n\033[31m%d check(s) failed:\033[0m %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mall checks passed\033[0m\n'
