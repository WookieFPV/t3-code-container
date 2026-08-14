#!/usr/bin/env bash
# requires: node
# description: The t3 CLI, in the app user's own npm prefix
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

: "${T3_VERSION:=latest}"

# t3 pulls in native dependencies whose install scripts npm 12 blocks by
# default. Without them node-pty never runs `node-gyp rebuild` and you get a t3
# with no working PTY — which fails at runtime, not at install time.
T3_NATIVE_DEPS="node-pty,msgpackr-extract"

# --strict-allow-scripts stats both halves of the npm prefix rather than
# creating them on demand, so they must exist even when this role runs alone.
user_dir "$NPM_PREFIX/bin"
user_dir "$NPM_PREFIX/lib"

# The flag covers our own install; the .npmrc entry covers the ones we never
# type (`t3 service install` and the in-app self-update both build a pinned
# runtime with a project-scoped `npm install --prefix`, which npm 12 refuses to
# accept the flag for). Check rather than assume, because a profile that
# overrode NPM_ALLOW_SCRIPTS without these produces a silently broken server.
for dep in ${T3_NATIVE_DEPS//,/ }; do
    [[ ,$NPM_ALLOW_SCRIPTS, == *,$dep,* ]] ||
        die "NPM_ALLOW_SCRIPTS is '$NPM_ALLOW_SCRIPTS' and does not include '$dep'.
    t3's pinned runtime is built by an install this repo does not run, so the
    allowlist has to be in ~/.npmrc. Set NPM_ALLOW_SCRIPTS=$T3_NATIVE_DEPS in
    your profile and re-run './setup.sh --only node t3'."
done

# --strict-allow-scripts turns any *other* blocked script into a hard error, so
# a t3 release that adds a new native dependency stops the run rather than half
# installing.
log "installing t3@$T3_VERSION"
as_user npm install -g "t3@$T3_VERSION" \
    --allow-scripts="$T3_NATIVE_DEPS" \
    --strict-allow-scripts

ok "t3 $(as_user t3 --version 2>/dev/null || echo installed)"
