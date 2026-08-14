#!/usr/bin/env bash
# Everything that has to happen once, as the app user, after setup.sh.
#
# Two of these steps need a human at a browser (GitHub and t3 both use OAuth
# device flows, and neither can be scripted without pasting a long-lived token
# into the box — which is worse). Everything *around* those two — SSH key,
# key upload, git identity, getting the server to pick the authorization up —
# is done here so there is nothing left to remember or get wrong.
#
# Safe to re-run: every step checks whether it is already done.
set -uo pipefail

step()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
log()   { printf '    %s\n' "$*"; }
ok()    { printf '    \033[32mok\033[0m %s\n' "$*"; }
warn()  { printf '    \033[33mwarn\033[0m %s\n' "$*" >&2; }
die()   { printf '\n\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# The app user owns this script, so its own owner is the account to switch to —
# `id -un` here would just say root, which is the thing being refused.
[[ $EUID -ne 0 ]] || die "run this as the app user, not root:
    machinectl shell $(stat -c '%U' "${BASH_SOURCE[0]}")@"

command -v gh >/dev/null || die "gh is not on PATH — run setup.sh first"
command -v t3 >/dev/null || die "t3 is not on PATH — run setup.sh first"

# Both logins read a one-time code back from the terminal, so without a TTY this
# would hang inside gh rather than fail here.
[[ -t 0 && -t 1 ]] || die "no terminal — run this from an interactive session:
    ssh $(id -un)@<container>, or 'machinectl shell $(id -un)@' from root"

SSH_KEY=$HOME/.ssh/id_ed25519
SSH_KEY_TITLE=${SSH_KEY_TITLE:-$(hostname -s)}

# ---------------------------------------------------------------- github auth
step "GitHub account"
if gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "already signed in as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
    log "A one-time code appears below. Open the URL on any device with a"
    log "browser, enter the code, and come back here."
    log ""
    log "The 'Failed opening a web browser' line is expected on a headless"
    log "container — the code above it is the part that matters."
    log ""
    # --skip-ssh-key: the key is generated and uploaded below instead, so its
    # name is derived from the hostname rather than typed at a prompt.
    # admin:public_key is normally requested as part of gh's own key flow, which
    # skipping opts out of — ask for it explicitly or the upload 404s.
    gh auth login \
        --hostname github.com \
        --git-protocol ssh \
        --skip-ssh-key \
        --scopes admin:public_key \
        --web || die "gh auth login failed"
    ok "signed in as $(gh api user --jq .login)"
fi

# ------------------------------------------------------------------- ssh key
step "SSH key for git"
if [[ -f $SSH_KEY ]]; then
    ok "$SSH_KEY exists"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -C "$(id -un)@$(hostname -s)" \
        >/dev/null || die "ssh-keygen failed"
    ok "generated $SSH_KEY"
fi

# GitHub returns "<type> <base64>" with no comment, so compare those two fields.
pub=$(cut -d' ' -f1,2 "$SSH_KEY.pub")
if gh api user/keys --jq '.[].key' 2>/dev/null | grep -qxF "$pub"; then
    ok "key already on the GitHub account"
elif gh ssh-key add "$SSH_KEY.pub" --title "$SSH_KEY_TITLE"; then
    ok "uploaded as '$SSH_KEY_TITLE'"
else
    warn "could not upload the key. If this was a scope error:
        gh auth refresh -h github.com -s admin:public_key
    then re-run this script."
fi

# StrictHostKeyChecking=yes rather than the default 'ask': the github-ssh role
# pinned the host key, so a prompt here would mean the pinning did not work.
# ssh exits 1 on a successful GitHub auth (there is no shell), hence the grep.
if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -T git@github.com 2>&1 |
        grep -q 'successfully authenticated'; then
    ok "ssh git@github.com works"
else
    warn "ssh to github.com did not authenticate — 'ssh -T git@github.com' to see why"
fi

# -------------------------------------------------------------- git identity
step "git identity"
if [[ -n $(git config --global user.email || true) ]]; then
    ok "already set: $(git config --global user.name) <$(git config --global user.email)>"
else
    login=$(gh api user --jq .login)
    uid=$(gh api user --jq .id)
    name=$(gh api user --jq '.name // .login')
    email=$(gh api user --jq '.email // ""')
    # A private account email comes back null; the noreply address is what
    # GitHub itself uses for web commits and it always attributes correctly.
    [[ -n $email ]] || email="$uid+$login@users.noreply.github.com"
    git config --global user.name "$name"
    git config --global user.email "$email"
    ok "set to $name <$email>"
fi

# --------------------------------------------------------------------- t3
# `t3 connect status` is a state dump, not a check: it exits 0 whether or not
# anything was ever authorized, so gate on what it prints. "Authorization:" is
# `missing` before, and names the stored credential after.
connect_status() { t3 connect status 2>/dev/null; }

step "t3 authorization"
if connect_status | grep -q 'Authorization: missing'; then
    log "A URL and a one-time code appear below. Open the URL on any device"
    log "with a browser, enter the code, and come back here."
    log ""
    log "One prompt needs the right answer:"
    log ""
    log "  * Answer YES to installing the relay client (cloudflared). It"
    log "    defaults to no, and nothing else installs it — without it the"
    log "    tunnel can never come up, however healthy the status looks."
    log ""
    # --headless because the alternative is an OAuth callback on
    # http://127.0.0.1:<port>, which resolves only inside this container. t3
    # auto-detects it inside an SSH session, but `machinectl shell` is not SSH.
    #
    # `connect link` rather than bare `t3 connect`: the latter ends by offering
    # to set up the background service, which the t3-service role installed as
    # t3code.service. A second server unit against one ~/.t3 is the failure this
    # setup goes out of its way to avoid.
    t3 connect link --headless || die "t3 connect link failed"
    ok "authorized"
else
    ok "already authorized"
fi

# t3's own background setup, if it ever ran, would land here alongside t3's
# installed unit; so would a t3.service left by an older version of this repo.
mapfile -t stray < <(
    systemctl --user list-unit-files --no-legend 't3*' 2>/dev/null |
        awk '{print $1}' |
        grep -vxE 't3code\.service|t3-update\.service|t3-update\.timer' || true
)
if [[ ${#stray[@]} -gt 0 ]]; then
    warn "unexpected t3 unit(s): ${stray[*]}
    The server is t3code.service and there must be exactly one — two of them
    share one ~/.t3 and one tunnel, which breaks the app while every local
    check still reads healthy. Re-run './setup.sh --only t3-service' as root to reconcile, or:
        systemctl --user disable --now ${stray[*]}"
fi

# ------------------------------------------------------------------- service
step "t3code.service"
systemctl --user cat t3code.service >/dev/null 2>&1 ||
    die "t3code.service is not installed — run './setup.sh --only t3-service' as root first."

# The environment link is provisioned by the server on its next start, so a
# freshly authorized box needs one restart. Only then: a restart drops the
# tunnel and any live Claude sessions, so it is not something to do on every run.
if connect_status | grep -q 'Environment link: provisioned'; then
    systemctl --user start t3code.service || die "t3code.service failed to start —
    tail -n 50 $HOME/.t3/userdata/logs/boot-service.log"
else
    log "restarting so the server picks up the authorization"
    systemctl --user restart t3code.service || die "t3code.service failed to start —
    tail -n 50 $HOME/.t3/userdata/logs/boot-service.log"
    for _ in {1..20}; do
        connect_status | grep -q 'Environment link: provisioned' && break
        sleep 0.5
    done
fi

if systemctl --user is-active --quiet t3code.service; then
    ok "running"
    runtime=$HOME/.t3/userdata/server-runtime.json
    for _ in {1..20}; do
        [[ -s $runtime ]] && break
        sleep 0.5
    done
    [[ -s $runtime ]] && log "listening on $(jq -r .origin "$runtime" 2>/dev/null || cat "$runtime")"
else
    warn "not active — systemctl --user status t3code.service, and
    tail -n 50 $HOME/.t3/userdata/logs/boot-service.log (the unit logs to a
    file, not the journal)"
fi

if connect_status | grep -q 'Environment link: provisioned'; then
    ok "environment link provisioned"
else
    warn "environment link still missing. The tunnel is what the app connects
    through, so this is worth chasing:
        t3 connect status
        grep 'Relay client' $HOME/.t3/userdata/logs/boot-service.log | tail"
fi

# -------------------------------------------------------------- claude code
step "Claude Code"
log "Claude is installed but not logged in; that happens inside the app."

# The claude role seeded these; say so here, because this is the moment someone
# would otherwise wonder why the box is not on the account default — and the
# two commands that change it are not discoverable from a login prompt.
settings=$HOME/.claude/settings.json
if [[ -s $settings ]] && seeded=$(jq -er '
    select(.model != null or .effortLevel != null)
    | "\(.model // "the default model") at \(.effortLevel // "default") effort"
' "$settings" 2>/dev/null) && [[ -n $seeded ]]; then
    log ""
    log "It starts on $seeded — change it in the session with"
    log "/model and /effort, which write back to $settings."
fi

read -r -p "    Launch claude now to log in? [Y/n] " reply
case ${reply:-y} in
    [Yy]*) claude ;;
    *)     log "later: run 'claude'" ;;
esac

step "done"
cat <<EOF
    Clone what you want to work on into ~/code:

        gh repo clone <owner>/<repo> ~/code/<repo>

    Check the stack any time:

        systemctl --user status t3code.service
        t3 connect status
        systemctl --user list-timers t3-update.timer
        tail -f ~/.t3/userdata/logs/boot-service.log   # the server's own log
EOF
