#!/usr/bin/env bash
# requires: user
# description: Node.js and a user-owned npm prefix
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

# Overridable from a profile or the environment.
: "${NODE_MAJOR:=24}"
# Distributions ship whatever npm Node bundles (11.x for Node 24). npm 12
# blocks install-time lifecycle scripts where 11 only warns, and the roles here
# are written against the blocking behaviour, so pin the major rather than
# inheriting it. Installed into the user prefix, never into /usr.
: "${NPM_MAJOR:=12}"

os_detect

# ------------------------------------------------------------------ the runtime
case $OS_FAMILY in
debian)
    # Debian's own nodejs package is far too old; NodeSource is the vendor repo.
    KEYRING=/usr/share/keyrings/nodesource.gpg

    # Pinned signing key for https://deb.nodesource.com.
    # Cross-check against https://github.com/nodesource/distributions before
    # changing.
    #   6F71...E0B4  rsa2048, created 2016-05-23, "NodeSource <gpg@nodesource.com>"
    NODE_KEYS=(6F71F525282841EEDAF851B42F59B5F99B1BE0B4)

    ARMORED=1 fetch_keyring \
        https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        "$KEYRING" NodeSource "${NODE_KEYS[@]}"

    repo_add_deb822 nodesource \
        "https://deb.nodesource.com/node_${NODE_MAJOR}.x" \
        nodistro main "$KEYRING" || true

    # Not pkg_install: on an image that already carries Debian's own nodejs,
    # "already present" is exactly the wrong answer — NodeSource is here
    # precisely because that one is too old.
    pkg_upgrade_to_candidate nodejs
    ;;
rhel)
    # Fedora ships current Node in its own repos, versioned per major. Prefer
    # the exact major, fall back to the unversioned package.
    if dnf -q list --available "nodejs${NODE_MAJOR}" >/dev/null 2>&1; then
        pkg_install "nodejs${NODE_MAJOR}"
    else
        warn "no nodejs${NODE_MAJOR} package — installing the distribution default"
        pkg_install nodejs npm
    fi
    ;;
arch)
    # Rolling release, so this is current by definition.
    pkg_install nodejs npm
    ;;
esac

require_cmd node npm
have_major=$(node -v | sed 's/^v//; s/\..*//')
if [[ $have_major -lt $NODE_MAJOR ]]; then
    warn "node $(node -v) is older than the requested major ($NODE_MAJOR).
    On a tier 2 distribution this is the newest the repos offer; install a
    newer build by hand if something needs it."
else
    log "node $(node -v), npm $(npm -v)"
fi

# -------------------------------------------------------------- the npm prefix
# Global installs land in the user's own tree instead of /usr, so `npm i -g`
# never needs root.
user_dir "$NPM_PREFIX/bin"
user_dir "$NPM_PREFIX/lib"
ensure_line "$APP_HOME/.npmrc" "prefix=$NPM_PREFIX" "$APP_USER:$APP_USER"

# The allowlist has to live in .npmrc rather than on our own command lines,
# because the installs that matter most are ones nobody types: a tool's own
# service installer or self-updater running
#   npm install --prefix <staging> --no-fund --no-audit <pkg>@<version>
# and npm 12 rejects --allow-scripts outright for a project-scoped install like
# that ("Add the entries to the allowScripts field in package.json, or to
# .npmrc, instead").
if [[ -n $NPM_ALLOW_SCRIPTS ]]; then
    ensure_line "$APP_HOME/.npmrc" "allow-scripts=$NPM_ALLOW_SCRIPTS" "$APP_USER:$APP_USER"
else
    skip "NPM_ALLOW_SCRIPTS is empty — no install scripts allowed"
fi

have_npm=$(as_user npm --version 2>/dev/null || echo 0)
if [[ ${have_npm%%.*} == "$NPM_MAJOR" ]]; then
    ok "npm $have_npm (major $NPM_MAJOR as pinned)"
else
    log "npm $have_npm -> npm@$NPM_MAJOR"
    as_user npm install -g "npm@$NPM_MAJOR"
    ok "npm $(as_user npm --version)"
fi
