#!/usr/bin/env bash
# Nightly update of t3: the global CLI, and the pinned runtime t3code.service
# actually runs.
#
# t3 can update itself, but only when asked — `serverUpdateServer` is a
# WebSocket method the app calls, not a background check. Nothing updates this
# box unattended unless something here does, hence the timer.
#
# The work is handed to `t3 service update` rather than done by hand: it builds
# the new version's pinned runtime under ~/.t3/runtime/versions/<v> in a staging
# directory, validates it, publishes it with an atomic rename, rewrites the unit
# and restarts. A half-finished install never becomes the one systemd points at.
#
# Runs as the app user via t3-update.timer. The npm prefix is user-owned
# (~/.local), so no privilege escalation is involved.
set -uo pipefail

UNIT=t3code.service
STATE_DIR="${T3CODE_HOME:-$HOME/.t3}/userdata"
DB="$STATE_DIR/state.sqlite"
BACKUP_DIR="$STATE_DIR/pre-update"

current_version() {
    npm ls -g --depth=0 --json 2>/dev/null | node -e \
        'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).dependencies.t3.version)}catch(e){console.log("unknown")}})'
}

before=$(current_version)
echo "t3 CLI version before update: $before"

# The allowlist is not repeated here: ~/.npmrc (node role) is the single source
# of truth, and npm 12 reads it for global installs too. Strict mode stays,
# because it turns any *other* blocked script into a hard error — the signal we
# want if a future t3 release adds a native dependency. It stops the update
# instead of quietly shipping a half-built tree.
if ! npm install -g t3@latest --strict-allow-scripts; then
    echo "npm install failed; leaving $UNIT untouched" >&2
    exit 1
fi

after=$(current_version)
echo "t3 CLI version after update: $after"

if [[ "$before" == "$after" ]]; then
    echo "Already up to date; not touching $UNIT"
    exit 0
fi

# npm reporting a new version only means it rewrote package metadata. An install
# killed partway through leaves a tree that looks right and dies on exec, and
# `t3 service update` is about to be run *with that binary*. Make it prove
# itself while the server is still up on the old pinned runtime.
if ! t3 --version >/dev/null 2>&1; then
    echo "t3 $after is installed but does not run; leaving $UNIT on the old runtime" >&2
    echo "Recover with: npm install -g t3@$before --strict-allow-scripts" >&2
    exit 1
fi

# `t3 service update` reinstalls and restarts; it does not snapshot the database
# the way an in-app update does (that path trials the new version and rolls the
# migration back). Take our own snapshot so a bad release is recoverable.
# Stop first: copying a live SQLite file races its WAL and the copy can come out
# unusable, and the update is downtime either way.
echo "Stopping $UNIT to snapshot the database"
systemctl --user stop "$UNIT"

if [[ -f $DB ]]; then
    if mkdir -p "$BACKUP_DIR" &&
       cp -f "$DB" "$BACKUP_DIR/state.sqlite" &&
       printf '%s\n' "$before" > "$BACKUP_DIR/version"; then
        # -wal/-shm are absent after a clean shutdown; copy them if they linger.
        for sidecar in "$DB-wal" "$DB-shm"; do
            [[ -f $sidecar ]] && cp -f "$sidecar" "$BACKUP_DIR/$(basename "$sidecar")"
        done
        echo "Database snapshot: $BACKUP_DIR (t3 $before)"
    else
        # A snapshot is a safety net, not a precondition. Say so loudly and
        # carry on rather than leaving the server stopped.
        echo "warning: could not snapshot $DB; updating without a rollback point" >&2
    fi
fi

echo "Updating $before -> $after"
if ! t3 service update; then
    # The unit and its old pinned runtime are still on disk and still valid;
    # the one thing we must not do is leave the box down.
    echo "'t3 service update' failed; restarting $UNIT on the old runtime" >&2
    systemctl --user start "$UNIT"
    exit 1
fi

# `t3 service update` starts the unit itself. Confirm rather than assume.
if systemctl --user is-active --quiet "$UNIT"; then
    echo "Updated to $after; $UNIT is active"
else
    echo "warning: $UNIT is not active after the update; starting it" >&2
    systemctl --user start "$UNIT"
fi
