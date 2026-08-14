#!/usr/bin/env bash
# requires: base
# description: Unprivileged app user, linger, home layout and shell environment
#
# No sudo on purpose. Everything system-level is done by setup.sh as root; this
# account can only affect its own home directory, and every repo under it has a
# remote. That is what makes it safe to let an agent run unattended here.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

os_require_systemd

sys_user_create "$APP_USER"
sys_enable_linger "$APP_USER"

# ------------------------------------------------------------------ ssh access
user_dir "$APP_HOME/.ssh" 0700

# Seed the app user's authorized_keys from root's, which the container creation
# step populated. Without this you can only reach the account by logging in as
# root first — and `ssh $APP_USER@host` is the better route anyway, because it
# creates a real systemd login session, so `systemctl --user` just works.
if [[ $SEED_AUTHORIZED_KEYS == 1 ]]; then
    if [[ -s /root/.ssh/authorized_keys ]]; then
        if [[ -s $APP_HOME/.ssh/authorized_keys ]] &&
           cmp -s /root/.ssh/authorized_keys "$APP_HOME/.ssh/authorized_keys"; then
            ok "$APP_USER authorized_keys already matches root's"
        else
            install -m 0600 -o "$APP_USER" -g "$APP_USER" \
                /root/.ssh/authorized_keys "$APP_HOME/.ssh/authorized_keys"
            ok "seeded $APP_USER authorized_keys from root"
        fi
    else
        warn "/root/.ssh/authorized_keys is empty — $APP_USER will have no SSH access
    (reach it with 'machinectl shell $APP_USER@' from root instead)"
    fi
else
    skip "SEED_AUTHORIZED_KEYS=0 — not copying root's keys"
fi

# ------------------------------------------------------------------- home tree
user_dir "$APP_HOME/code"
# Both halves of the npm prefix must exist up front: `npm i -g
# --strict-allow-scripts` stats $prefix/lib before it would create it and dies
# with ENOENT if it is missing (npm 11 and 12 alike).
user_dir "$NPM_PREFIX/bin"
user_dir "$NPM_PREFIX/lib"
# Claude Code's installer creates ~/.local/share/claude itself, but only if it
# can write to ~/.local — which user_dir is what guarantees.
user_dir "$NPM_PREFIX/share"
ok "home directories in place"

# --------------------------------------------------------- shell environment
# XDG_RUNTIME_DIR is what makes `systemctl --user` work over a plain SSH session.
bashrc="$APP_HOME/.bashrc"
[[ -f $bashrc ]] || install -m 0644 -o "$APP_USER" -g "$APP_USER" /dev/null "$bashrc"
ensure_line "$bashrc" 'export PATH="$HOME/.local/bin:$PATH"'      "$APP_USER:$APP_USER"
ensure_line "$bashrc" 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' "$APP_USER:$APP_USER"
