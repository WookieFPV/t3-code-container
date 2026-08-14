#!/usr/bin/env bash
# requires: base
# description: GitHub CLI, from the vendor repo where the distribution lags
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

os_detect

case $OS_FAMILY in
debian)
    # Debian 12 ships gh 2.23 (Feb 2023). Upstream is used instead so
    # `gh auth login` and its device flow are current — that is the whole
    # account setup path.
    KEYRING=/etc/apt/keyrings/githubcli-archive-keyring.gpg

    # Pinned signing keys for https://cli.github.com/packages.
    # Cross-check against
    # https://github.com/cli/cli/blob/trunk/docs/install_linux.md before
    # changing these.
    #   2C61...6059  rsa4096, created 2022-09-06, EXPIRES 2026-09-05
    #   7F38...3325  rsa4096, created 2026-04-07 — the rollover key
    # Both are shipped in the keyring today; when the first expires apt falls
    # back to the second, so the rollover needs no action.
    GH_KEYS=(
        2C6106201985B60E6C7AC87323F3D4EA75716059
        7F38BBB59D064DBCB3D84D725612B36462313325
    )

    # Already a binary keyring upstream, so no dearmor.
    fetch_keyring https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        "$KEYRING" "GitHub CLI" "${GH_KEYS[@]}"

    repo_add_deb822 github-cli https://cli.github.com/packages stable main "$KEYRING" || true

    # pkg_install would skip an already-present Debian gh, so compare against
    # the candidate and upgrade when upstream has something newer.
    pkg_upgrade_to_candidate gh
    ;;
rhel|arch)
    # Both ship a current gh in their own repositories.
    pkg_install gh
    ;;
esac

require_cmd gh
log "$(gh --version | head -1)"
