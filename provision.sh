#!/usr/bin/env bash
# Provision this machine from a profile. Safe to re-run at any time.
#
# Runs anywhere systemd does — an LXC container, a VM, a cloud VPS. Nothing here
# knows about Proxmox; creating the container is a separate, optional step
# (pve/create-container.sh) that runs on the hypervisor.
#
# This is a bootstrap, not the provisioning logic. All it does is make sure
# ansible-core is installed and then hand over to a playbook, which is where
# every decision actually lives. It exists because Ansible's normal shape —
# a control node with an inventory of SSH targets — is the wrong one for a
# container that does not have an address yet, and because "check out this repo
# and run one command as root" is worth keeping.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAYBOOK_DIR="$REPO_DIR/playbooks"

die() { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: ./provision.sh [options] [-- ansible-playbook options]

Options:
  -p, --profile NAME   which profile to install       (default: $PROFILE or t3)
  -o, --only   a,b,c   run exactly these roles, without their dependencies —
                       for repairing one step on a box that is already
                       provisioned. Bare arguments mean the same.
  -e, --extra  K=V     override any setting (repeatable)
  -n, --dry-run        report what would change, without changing it
  -l, --list           list available profiles and roles
  -L, --log   FILE     also append everything to FILE
  -h, --help           this

Examples:
  ./provision.sh                              # the default profile, everything
  ./provision.sh --profile dev-node
  ./provision.sh --only claude                # re-run one role
  ./provision.sh node t3                      # same, positional
  ./provision.sh -e timezone=Europe/Berlin    # any setting can be overridden
  ./provision.sh --dry-run

Settings come from, lowest precedence first: inventory/group_vars/all.yml, the profile
playbook, then -e. `--list` shows what each profile is for.

Note on --dry-run: it is Ansible's --check --diff, so it reports honestly on
packages, files and services — but the vendor install scripts (bun, Claude
Code) and `t3 service install` cannot be simulated and are reported as skipped
rather than as the work they would do.
EOF
}

profile=${PROFILE:-t3}
LOG_FILE=${LOG_FILE:-}
only=()
extra=()
passthrough=()
dry_run=0
do_list=0

split_list() { tr ', ' '\n\n' <<<"$1" | grep -v '^$' || true; }

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile) profile=${2:?--profile needs a name}; shift 2 ;;
        -o|--only)    mapfile -t -O "${#only[@]}" only < <(split_list "${2:?--only needs a list}"); shift 2 ;;
        -e|--extra)   extra+=(-e "${2:?--extra needs KEY=VALUE}"); shift 2 ;;
        -n|--dry-run) dry_run=1; shift ;;
        -l|--list)    do_list=1; shift ;;
        -L|--log)     LOG_FILE=${2:?--log needs a file}; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; passthrough=("$@"); break ;;
        -*)           printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        # The bash implementation this replaced selected roles the same way.
        *)            only+=("$1"); shift ;;
    esac
done

# ------------------------------------------------------------------- --log
# Tee everything into LOG_FILE as well as the terminal. The terminal keeps its
# colours; the file gets the same lines stripped of ANSI escapes.
if [[ -n $LOG_FILE ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '\n==== %s ====\n' "$(date '+%F %T %Z')" >> "$LOG_FILE"
    exec > >(tee >(sed -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
    # tee is still draining the pipe when the script exits; close our end and
    # wait, or the tail of the run would be lost.
    trap 'exec 1>&- 2>&-; wait 2>/dev/null || true' EXIT
fi

# ------------------------------------------------------------------ --list
profile_description() {
    sed -n 's/^# description: *//p' "$1" | head -1
}

if [[ $do_list == 1 ]]; then
    printf '\n\033[1;34m==> profiles\033[0m\n'
    for f in "$PLAYBOOK_DIR"/*.yml; do
        printf '    %-12s %s\n' "$(basename "$f" .yml)" "$(profile_description "$f")"
    done
    printf '\n\033[1;34m==> roles\033[0m\n'
    for d in "$REPO_DIR"/roles/*/; do
        n=$(basename "$d")
        printf '    %-14s %s\n' "$n" \
            "$(sed -n 's/^ *description: *//p' "$d/meta/main.yml" 2>/dev/null | head -1)"
    done
    printf '\n    Roles are selected with --only; the list above is every role in the\n'
    printf '    repository, not every role in a given profile. To see one profile:\n'
    printf '        ansible-playbook playbooks/<profile>.yml --list-tags\n\n'
    exit 0
fi

playbook="$PLAYBOOK_DIR/$profile.yml"
if [[ ! -f $playbook ]]; then
    die "no such profile: $profile
    available: $(cd "$PLAYBOOK_DIR" && ls ./*.yml | sed 's/\.yml$//; s|^\./||' | tr '\n' ' ')"
fi

[[ $EUID -eq 0 ]] || die "run as root (the roles create users and install packages)"

# ------------------------------------------------------- ansible-core itself
# Installed from the distribution rather than pip: it is the only dependency
# this bootstrap has, and a distribution package needs no virtualenv, no
# network beyond the configured mirrors, and no decision about where it lives.
install_ansible() {
    log "installing ansible-core"
    if   command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible-core
    elif command -v dnf >/dev/null; then
        dnf -q install -y ansible-core
    elif command -v pacman >/dev/null; then
        # `ansible`, not `ansible-core`, and only here. ansible-core ships the
        # apt and dnf modules but not pacman — that one lives in
        # community.general — so `ansible.builtin.package` cannot resolve a
        # package manager on Arch without it. Arch's `ansible` package bundles
        # the collections, which is cheaper than a galaxy install and keeps
        # this bootstrap network-independent beyond the distribution mirrors.
        #
        # -Syu, not -Sy. Arch does not support partial upgrades: refreshing the
        # index without also upgrading leaves packages built against library
        # versions that are no longer installed, and asks the mirror for files
        # it has already replaced.
        pacman -Syu --needed --noconfirm ansible
    elif command -v apk >/dev/null; then
        # Reached only so the message is useful. The playbook refuses Alpine
        # anyway — every long-running part of this setup is a systemd user unit.
        die "Alpine is not supported: there is no systemd, and the app user's
    linger session, the server and the update timer are all systemd user units.
    Supporting it means rewriting those as OpenRC services running as root,
    which is a different design, not a port."
    else
        die "no supported package manager found (apt, dnf, pacman).
    Install ansible-core by hand, then re-run this."
    fi
}

command -v ansible-playbook >/dev/null || install_ansible
command -v ansible-playbook >/dev/null ||
    die "ansible-core installed but ansible-playbook is still not on PATH"

# ------------------------------------------------------------------- run it
args=()
[[ ${#only[@]} -gt 0 ]] && args+=(--tags "$(IFS=,; echo "${only[*]}")")
[[ $dry_run == 1 ]] && args+=(--check --diff)
args+=("${extra[@]}" "${passthrough[@]}")

# npm_config_* in the inherited environment outranks the app user's own .npmrc
# and sends `npm i -g` at root-owned paths (EACCES). This matters whenever
# provisioning is launched from inside an agent session or an `npm exec`, which
# is exactly how it gets re-run on a box that is already working. Drop the whole
# class here; inventory/group_vars/all.yml then sets the three that decide where npm
# writes to the values this box actually wants.
unset "${!npm_config_@}" 2>/dev/null || true

cd "$REPO_DIR"
# ANSIBLE_CONFIG rather than relying on the cwd: ansible ignores an ansible.cfg
# in a world-writable directory, and /opt/provision after a `pct push` has been
# exactly that often enough to be worth removing as a variable.
export ANSIBLE_CONFIG="$REPO_DIR/ansible.cfg"
exec ansible-playbook "$playbook" "${args[@]}"
