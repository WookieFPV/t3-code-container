#!/usr/bin/env bash
# The single entry point every role sources.
#
# Roles run as separate bash processes (see roles_run), so this is also what
# gives them their configuration: it re-reads the same profile setup.sh read,
# which is why running one role with --only produces exactly what running the
# whole profile would.
#
# Precedence, lowest to highest:
#   defaults here  <  profiles/<name>.sh  <  environment  <  command line
# Profiles therefore assign with `: "${VAR:=...}"`, never `VAR=...`, so an
# environment override survives.

set -euo pipefail

: "${REPO_DIR:?REPO_DIR must be set before sourcing lib/common.sh}"

source "$REPO_DIR/lib/log.sh"
source "$REPO_DIR/lib/os.sh"
source "$REPO_DIR/lib/fs.sh"
source "$REPO_DIR/lib/keys.sh"
source "$REPO_DIR/lib/pkg.sh"
source "$REPO_DIR/lib/sys.sh"
source "$REPO_DIR/lib/roles.sh"

# ---------------------------------------------------------------- profile
if [[ -n ${PROFILE_FILE:-} ]]; then
    [[ -f $PROFILE_FILE ]] || die "profile not found: $PROFILE_FILE"
    # shellcheck disable=SC1090
    source "$PROFILE_FILE"
fi

# --------------------------------------------------------------- defaults
# The unprivileged account that runs the installed tooling.
#
# Deliberately has no sudo: setup.sh (as root) owns all system state, so an
# agent running as this user cannot damage the OS install. Nothing in these
# roles needs root anyway — user systemd units, outbound-only networking,
# ports above 1024, and global npm installs into the user's own prefix.
: "${APP_USER:=devuser}"
: "${APP_HOME:=/home/$APP_USER}"

# User-owned npm prefix, so `npm i -g` never needs root.
: "${NPM_PREFIX:=$APP_HOME/.local}"

# Systemd timers use local time, so this decides when nightly jobs fire.
: "${TIMEZONE:=Etc/UTC}"
: "${LOCALE:=en_US.UTF-8}"

# Copy root's authorized_keys to the app user, so the key given at container
# creation reaches the account you actually work in. Set to 0 on a shared box.
: "${SEED_AUTHORIZED_KEYS:=1}"

# npm 12 blocks dependency install-time lifecycle scripts outright (npm 11, the
# one Node 24 bundles, only warns). Packages with native code need theirs to
# build. This is a comma-separated allowlist written to the app user's .npmrc,
# and shared config rather than node-role config because the roles that install
# such packages have to agree with it — see roles/t3/install.sh.
: "${NPM_ALLOW_SCRIPTS:=}"

: "${PROFILE_DESCRIPTION:=}"

export APP_USER APP_HOME NPM_PREFIX TIMEZONE LOCALE SEED_AUTHORIZED_KEYS \
       NPM_ALLOW_SCRIPTS

# ---------------------------------------------------------------- helpers
# as_user CMD... — run a command as APP_USER in a clean environment.
#
# `env -i` is deliberate. If setup.sh is launched from a shell inside an agent
# or an `npm exec`, the environment carries npm_config_* along with it —
# npm_config_prefix=/usr, npm_config_cache=/root/.npm, npm_config_userconfig.
# Those override the app user's own .npmrc and send npm at root-owned paths, so
# `npm i -g` fails with EACCES. Inheriting nothing avoids the whole class.
as_user() {
    runuser -u "$APP_USER" -- \
        env -i \
            HOME="$APP_HOME" \
            USER="$APP_USER" \
            LOGNAME="$APP_USER" \
            SHELL=/bin/bash \
            TERM="${TERM:-dumb}" \
            LANG="${LANG:-C.UTF-8}" \
            BUN_INSTALL="$APP_HOME/.bun" \
            PATH="$NPM_PREFIX/bin:$APP_HOME/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            XDG_RUNTIME_DIR="/run/user/$(id -u "$APP_USER" 2>/dev/null || echo 0)" \
            "$@"
}

# require_cmd CMD... — fail with something actionable rather than inside a pipe.
# Roles use this for tools an earlier role installed, so running one role on a
# box that never ran the others says which one to run.
require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null ||
            die "$c is not installed — run './setup.sh --only base' first"
    done
}
