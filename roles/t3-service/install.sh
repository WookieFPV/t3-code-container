#!/usr/bin/env bash
# requires: t3
# description: t3code.service plus the nightly update timer
#
# The server runs under t3's own systemd user unit, installed by
# `t3 service install`. This role installs the nightly update timer and makes
# sure exactly one server unit exists.
#
# Why t3's unit and not one of ours: it points systemd at a per-version pinned
# runtime under ~/.t3/runtime/versions/<v> (staging directory, sentinel, atomic
# rename) rather than at whatever state a global npm install happens to be in,
# and it carries the update protocol the app drives — snapshot, trial, roll back
# a bad migration. It also tracks t3's own changes instead of drifting. See
# docs/design.md.
#
# These are user units (~/.config/systemd/user), not system units, which is why
# they run unprivileged and are managed with `systemctl --user`.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

os_require_systemd

UNIT_DIR="$APP_HOME/.config/systemd/user"
user_dir "$UNIT_DIR"

# Earlier versions of this repo shipped a hand-rolled t3.service. Leaving it
# behind next to t3code.service is the worst outcome available: two servers
# sharing one ~/.t3 — one SQLite database, one secret store, one
# server-runtime.json between two writers — and two cloudflared connectors
# registered for the same tunnel, so the relay sends the app to whichever it
# picks. That fails while every local check still reads healthy.
if [[ -e $UNIT_DIR/t3.service ]]; then
    warn "removing the legacy hand-rolled t3.service — this box runs t3's own
    t3code.service now. Two server units against one ~/.t3 is what breaks the
    app's connection while 'is-active' still says active."
    as_user systemctl --user disable --now t3.service || true
    rm -f "$UNIT_DIR/t3.service"
    as_user systemctl --user daemon-reload || true
    ok "removed t3.service"
fi

install_file "$ROLE_DIR/files/t3-nightly-update.sh" \
    "$NPM_PREFIX/bin/t3-nightly-update.sh" 0755 "$APP_USER:$APP_USER" || true

changed=0
for unit in t3-update.service t3-update.timer; do
    # `if`, not `&& changed=1`: install_file returns 1 to mean "already
    # correct", which is the normal case, and leaving that as a bare AND-list
    # makes the loop's exit status depend on whether the last unit happened to
    # change. Explicit here for the same reason sys_set_locale is.
    if install_file "$ROLE_DIR/files/$unit" "$UNIT_DIR/$unit" 0644 "$APP_USER:$APP_USER"; then
        changed=1
    fi
done

if [[ $changed -eq 1 ]]; then
    log "reloading user systemd manager"
    as_user systemctl --user daemon-reload
fi

as_user systemctl --user enable --now t3-update.timer

# `t3 service install` (and the nightly `t3 service update`) runs
# `loginctl enable-linger` as the app user and aborts if that step exits
# non-zero. Linger is already enabled by the user role, so the command has
# nothing left to do — but whether it *succeeds* hinges on logind's polkit
# authorization, which proved environment-dependent even after installing the
# polkit daemon. Make that specific self-call deterministic: a user-scoped
# `loginctl` shim in the app user's PATH (first there, so t3's spawn of the
# bare command finds it) exits 0 for exactly `enable-linger` with no further
# arguments and forwards everything else to the real binary. The polkit daemon
# is installed too, so the real command still works when something calls it by
# absolute path or a human runs it by hand. Both are ensured *here* rather than
# in base, because a role that needs a package must not depend on another role
# having been re-run since: `./setup.sh --only t3-service` on an
# already-provisioned box has to work.
user_dir "$NPM_PREFIX/bin"
install_file "$ROLE_DIR/files/loginctl" \
    "$NPM_PREFIX/bin/loginctl" 0755 "$APP_USER:$APP_USER" || true
pkg_install polkit

# Installs (or repairs) t3code.service for the t3 version currently on PATH:
# writes the unit, builds the pinned runtime, enables lingering, starts it.
# Idempotent — it returns early when the installed unit already matches this
# version, so re-running costs nothing.
#
# The pinned runtime is a full `npm install` of t3 including a node-gyp build of
# node-pty, so a first run here takes a few minutes.
log "installing t3's background service (t3code.service)"
if as_user t3 service install; then
    as_user t3 service status || true
else
    die "'t3 service install' failed.
    Check the log it writes: $APP_HOME/.t3/userdata/logs/boot-service.log
    A pinned-runtime build needs network, a compiler and python3 (base role),
    and the allow-scripts line in $APP_HOME/.npmrc (node role).
    The app user's 'loginctl' shim should have swallowed the 'enabling
    lingering' step — if the log says that step failed anyway, t3 did not
    resolve 'loginctl' through the app user's PATH; run
    '$NPM_PREFIX/bin/loginctl enable-linger' and
    'systemctl --user status t3code.service' as the app user to see why."
fi

# `t3 service install` exits 0 as soon as the unit is written and the runtime is
# staged. A runtime whose node-pty install script was blocked stages perfectly
# and only fails when the server starts: NodePtyModuleLoadError, systemd
# restarts it five times, then 'start request repeated too quickly' and the unit
# sits in failed. Out here that looks like a clean provision — right up until
# 't3 connect status' says "Environment link: pending server startup" forever.
#
# node-pty ships prebuilds for darwin and win32 only, so on Linux the native
# module exists exactly when the build ran. Load it the way the server does,
# from the runtime the launcher will actually execute.
state=$APP_HOME/.t3/runtime/service-state.json
active=$(as_user node -p \
    "JSON.parse(require('fs').readFileSync('$state','utf8')).activeVersion ?? ''" \
    2>/dev/null) || active=""

if [[ -z $active ]]; then
    warn "could not read activeVersion from $state — skipping the node-pty check"
elif as_user node -e \
    "require('$APP_HOME/.t3/runtime/versions/$active/node_modules/node-pty')" \
    2>/dev/null; then
    ok "pinned runtime $active loads node-pty"
else
    die "the pinned runtime $active cannot load node-pty, so t3code.service will
    crash-loop at startup however healthy 'service install' looked.
    Almost always a blocked npm install script: check that
    $APP_HOME/.npmrc carries 'allow-scripts=node-pty,msgpackr-extract'
    (the node role writes it), then rebuild the module in place:
        npm rebuild node-pty --prefix $APP_HOME/.t3/runtime/versions/$active
    and restart with 'systemctl --user restart t3code.service'."
fi

as_user systemctl --user list-timers t3-update.timer --no-pager
