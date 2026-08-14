#!/usr/bin/env bash
# requires: user
# description: Install the guided one-time account setup on the app user's PATH
#
# Kept as a script the human runs rather than something setup.sh calls: it needs
# a TTY and a browser on some other device, so it cannot run unattended, and it
# belongs to the app user rather than to root.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

user_dir "$NPM_PREFIX/bin"

install_file "$ROLE_DIR/files/first-login.sh" \
    "$NPM_PREFIX/bin/first-login" 0755 "$APP_USER:$APP_USER" || true
