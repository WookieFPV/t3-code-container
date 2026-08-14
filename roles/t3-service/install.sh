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
    and the allow-scripts line in $APP_HOME/.npmrc (node role)."
fi

as_user systemctl --user list-timers t3-update.timer --no-pager
