#!/usr/bin/env bash
# requires: user
# description: Bun, via the official installer
#
# No distribution packages it, so this is the vendor's install script into
# ~/.bun. Distro-independent as a result — the only requirements are curl and
# unzip, which the base role installs.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

require_cmd curl unzip

if [[ -x $APP_HOME/.bun/bin/bun ]]; then
    ok "bun $(as_user bun --version) already installed"
    log "upgrading in place"
    as_user bun upgrade || warn "bun upgrade failed; keeping the existing version"
else
    log "installing bun for $APP_USER"
    as_user bash -c 'curl -fsSL https://bun.sh/install | bash'
fi

# The installer writes these to .bashrc itself, but only when it can see one it
# recognises; setting them here means a re-provision repairs a hand-edited file.
bashrc="$APP_HOME/.bashrc"
ensure_line "$bashrc" 'export BUN_INSTALL="$HOME/.bun"'      "$APP_USER:$APP_USER"
ensure_line "$bashrc" 'export PATH="$BUN_INSTALL/bin:$PATH"' "$APP_USER:$APP_USER"
