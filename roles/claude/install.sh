#!/usr/bin/env bash
# requires: user
# description: Claude Code, plus optional seeded model/effort defaults
#
# Not an npm package — it ships its own installer and self-updating versions
# directory, so it is deliberately not part of any nightly npm update.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

# What Claude Code starts on in a fresh container. Empty means "leave the
# account default alone", which is the right neutral behaviour for this repo;
# a profile that wants something else sets these.
#
# Model IDs age faster than anything else here. `/model` in a session lists what
# the account can actually reach, and a name it cannot use falls back to the
# account default rather than failing loudly — so check there after changing it,
# not by re-reading the file.
: "${CLAUDE_MODEL:=}"
# low | medium | high | xhigh
: "${CLAUDE_EFFORT_LEVEL:=}"

require_cmd curl

# The installer writes the binary to ~/.local/bin and its versions directory to
# ~/.local/share/claude, creating either on demand — so it needs to own ~/.local
# itself, not just its children.
user_dir "$NPM_PREFIX/bin"
user_dir "$NPM_PREFIX/share"

if [[ -x $APP_HOME/.local/bin/claude ]]; then
    ok "claude $(as_user claude --version 2>/dev/null || echo '(version unknown)')"
    log "checking for updates"
    as_user claude update || warn "claude update failed; keeping the existing version"
else
    log "installing Claude Code for $APP_USER"
    as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
fi

# --------------------------------------------------------------- defaults
if [[ -z $CLAUDE_MODEL && -z $CLAUDE_EFFORT_LEVEL ]]; then
    skip "no CLAUDE_MODEL / CLAUDE_EFFORT_LEVEL set — using the account default"
    exit 0
fi

# Seeded per key, never overwritten. /model and /effort inside a session write
# back to this same file, so a value already present is a choice somebody made
# in the app and re-running setup must not undo it — provisioning sets a
# starting point, it does not own the file. Delete the key there (or the whole
# file) and the next run puts the profile default back.
#
# User scope rather than a project .claude/: this is about the machine's
# starting point, and it has to apply in a repo cloned an hour from now.
settings="$APP_HOME/.claude/settings.json"
user_dir "$APP_HOME/.claude"

merged=$(mktemp) || die "mktemp failed"
trap 'rm -f "$merged" "$merged.next"' EXIT

require_cmd jq

# `type == "object"` covers both failure shapes in one test: jq exits 5 on a
# file it cannot parse, and -e exits 1 when the filter says false, so a valid
# JSON array or bare string lands here too.
if [[ -s $settings ]] && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    # Anything could have written this file; a hand-edit that lost a comma must
    # not take the provisioning run down with it, and merging into it blind
    # would replace it with our two keys alone.
    warn "$settings is not a JSON object — leaving it alone.
    Fix or delete it, then re-run './setup.sh --only claude'."
    exit 0
fi

if [[ -s $settings ]]; then cp "$settings" "$merged"; else printf '{}\n' >"$merged"; fi

for pair in "model=$CLAUDE_MODEL" "effortLevel=$CLAUDE_EFFORT_LEVEL"; do
    key=${pair%%=*} value=${pair#*=}
    [[ -n $value ]] || continue
    # jq -e exits 1 on null, which is both an absent key and one cleared in the
    # app — the two cases we want to treat the same.
    if current=$(jq -er --arg k "$key" '.[$k]' "$merged" 2>/dev/null); then
        ok "$key already set to $current — left alone"
    else
        jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$merged" >"$merged.next" ||
            die "jq failed while setting $key"
        mv "$merged.next" "$merged"
        log "$key -> $value"
    fi
done

install_file "$merged" "$settings" 0644 "$APP_USER:$APP_USER" || true
