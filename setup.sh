#!/usr/bin/env bash
# Provision this machine from a profile. Safe to re-run at any time.
#
# Runs anywhere systemd does — an LXC container, a VM, a cloud VPS. Nothing
# here knows about Proxmox; creating the container is a separate, optional step
# (pve/create-container.sh) that runs on the hypervisor.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export REPO_DIR

PROFILES_DIR="$REPO_DIR/profiles"

usage() {
    cat <<'EOF'
Usage: ./setup.sh [options] [role...]

Options:
  -p, --profile NAME   which profile to install       (default: $PROFILE or t3)
  -r, --roles  a,b,c   install these roles instead of the profile's list;
                       dependencies are resolved and added
  -o, --only   a,b,c   run exactly these roles, without pulling in their
                       dependencies — for repairing one step on a box that is
                       already provisioned. Bare role arguments mean the same.
  -n, --dry-run        print the resolved plan and exit
  -l, --list           list available profiles and roles
  -L, --log   FILE     also append everything to FILE — including the quiet
                       apt/npm output that never reaches the terminal
  -h, --help           this

Examples:
  ./setup.sh                             # the default profile, everything
  ./setup.sh --profile dev-node
  ./setup.sh --roles base,user,node      # an ad-hoc profile
  ./setup.sh --only claude               # re-run one role
  ./setup.sh node t3                     # same, positional
  ./setup.sh --log /var/log/setup.log    # keep a full record of every run
  TIMEZONE=Europe/Berlin ./setup.sh      # any setting can be overridden

Settings come from, lowest precedence first: lib/common.sh defaults, the
profile, then the environment. `--list` shows what each profile is for.
EOF
}

profile=${PROFILE:-t3}
LOG_FILE=${LOG_FILE:-}
roles_arg=()
only_arg=()
dry_run=0
do_list=0

# split_list "a,b c" -> one role per line. Accepts commas or spaces so that
# both `--only a,b` and `--only a b` (via positionals) do the obvious thing.
split_list() { tr ', ' '\n\n' <<<"$1" | grep -v '^$' || true; }

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile) profile=${2:?--profile needs a name}; shift 2 ;;
        -r|--roles)   mapfile -t -O "${#roles_arg[@]}" roles_arg < <(split_list "${2:?--roles needs a list}"); shift 2 ;;
        -o|--only)    mapfile -t -O "${#only_arg[@]}"  only_arg  < <(split_list "${2:?--only needs a list}");  shift 2 ;;
        -n|--dry-run) dry_run=1; shift ;;
        -l|--list)    do_list=1; shift ;;
        -L|--log)     LOG_FILE=${2:?--log needs a file}; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -*)           printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        # The old interface selected modules by their numeric prefix. Say so
        # rather than failing with "unknown role: 40".
        [0-9]*)
            printf 'error: modules are selected by name now, not by number.\n' >&2
            printf '  05 -> user   10 -> base   15 -> gh    16 -> github-ssh\n' >&2
            printf '  20 -> node   30 -> bun    40 -> t3    45 -> claude\n' >&2
            printf '  50 -> t3-service          55 -> first-login\n\n' >&2
            printf '  ./setup.sh --only t3 t3-service\n' >&2
            exit 2 ;;
        *)            only_arg+=("$1"); shift ;;
    esac
done

# ---------------------------------------------------------------- --log FILE
# Tee everything — stdout and stderr — into LOG_FILE as well as the terminal.
# The terminal keeps its colours; the file gets the same lines stripped of
# ANSI escapes. run_quiet (lib/log.sh) separately appends the output it hides
# from the terminal, so the file really has everything.
if [[ -n $LOG_FILE ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '\n==== %s ====\n' "$(date '+%F %T %Z')" >> "$LOG_FILE"
    exec > >(tee >(sed -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
    # tee is still draining the pipe when the script exits; close our end and
    # wait, or the tail of the run would be lost.
    trap 'exec 1>&- 2>&-; wait 2>/dev/null || true' EXIT
    export LOG_FILE
fi

PROFILE_FILE="$PROFILES_DIR/$profile.sh"
export PROFILE_FILE

# Checked here rather than in common.sh so the message can list the choices;
# common.sh has no idea a profile directory exists.
if [[ ! -f $PROFILE_FILE ]]; then
    printf 'error: no such profile: %s\n  available: %s\n' "$profile" \
        "$(cd "$PROFILES_DIR" && ls ./*.sh | sed 's/\.sh$//; s|^\./||' | tr '\n' ' ')" >&2
    exit 2
fi

# Sourcing common.sh also sources the profile, which is what defines ROLES.
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

# ------------------------------------------------------------------- --list
if [[ $do_list == 1 ]]; then
    header "profiles"
    for f in "$PROFILES_DIR"/*.sh; do
        n=$(basename "$f" .sh)
        # shellcheck disable=SC1090  # every profile in the directory, by design
        d=$( (unset PROFILE_DESCRIPTION; . "$f" >/dev/null 2>&1; echo "${PROFILE_DESCRIPTION:-}") )
        printf '    %-12s %s\n' "$n" "$d"
    done
    header "roles"
    while read -r r; do
        printf '    %-14s %s\n' "$r" "$(roles_describe "$r")"
        req=$(roles_requires "$r")
        if [[ -n $req ]]; then
            printf '    %-14s   requires: %s\n' "" "$req"
        fi
    done < <(roles_all)
    exit 0
fi

# ------------------------------------------------------------------ the plan
# `mapfile < <(roles_resolve ...)` would swallow a failure: the process
# substitution runs in a subshell, so a die() inside it leaves plan empty and
# the run continues. Command substitution propagates the exit status.
resolve_into_plan() {
    local out
    out=$(roles_resolve "$@") || exit 1
    [[ -n $out ]] || die "nothing to do"
    mapfile -t plan <<<"$out"
}

if [[ ${#only_arg[@]} -gt 0 ]]; then
    # No dependency expansion: --only is for repairing one step, and pulling in
    # `base` every time someone re-runs `--only claude` would make that useless.
    plan=("${only_arg[@]}")
    for r in "${plan[@]}"; do
        roles_exists "$r" || die "unknown role: $r
    Available: $(roles_all | tr '\n' ' ')"
    done
    plan_kind="only (dependencies not resolved)"
elif [[ ${#roles_arg[@]} -gt 0 ]]; then
    resolve_into_plan "${roles_arg[@]}"
    plan_kind="roles from the command line"
else
    [[ ${ROLES+set} == set && ${#ROLES[@]} -gt 0 ]] ||
        die "profile '$profile' defines no ROLES"
    resolve_into_plan "${ROLES[@]}"
    plan_kind="profile '$profile'"
fi

header "plan"
# The profile is always sourced (it carries the settings), but its description
# only describes the plan when the plan came from its role list.
if [[ $plan_kind == profile* && -n $PROFILE_DESCRIPTION ]]; then
    log "$plan_kind — $PROFILE_DESCRIPTION"
else
    log "$plan_kind"
fi
log "user: $APP_USER    timezone: $TIMEZONE    locale: $LOCALE"
log ""
for r in "${plan[@]}"; do
    printf '    %-14s %s\n' "$r" "$(roles_describe "$r")"
done

if [[ $dry_run == 1 ]]; then
    log ""
    log "--dry-run: nothing was changed"
    exit 0
fi

[[ $EUID -eq 0 ]] || die "run as root (the roles create users and install packages)"
os_tier

# ------------------------------------------------------------------- install
for r in "${plan[@]}"; do
    roles_run "$r" "$(roles_describe "$r")"
done

header "done"
cat <<EOF
Provisioning complete — re-run this any time; every role converges.

EOF
# When create-container.sh drove us over `pct exec`, the reader is sitting on
# the hypervisor, not in the container — the shell commands below need a
# `pct enter` first or they run against the host.
enter_line=""
[[ -n ${PVE_CTID:-} ]] &&
    enter_line="    pct enter $PVE_CTID              # from the Proxmox host
"
if [[ -x $NPM_PREFIX/bin/first-login ]]; then
    cat <<EOF
What is left needs a human at a browser: GitHub and t3 both use OAuth device
codes. 'first-login' walks through those and does everything around them:

$enter_line    machinectl shell $APP_USER@      # or: ssh $APP_USER@<host>
    first-login

See docs/design.md for what it does and the by-hand version.
EOF
else
    cat <<EOF
Log in as the app user to start working:

$enter_line    machinectl shell $APP_USER@      # or: ssh $APP_USER@<host>
EOF
fi
