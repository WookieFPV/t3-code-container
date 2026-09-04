#!/usr/bin/env bash
# Everything that has to happen once, as the app user, after provisioning.
#
# Two of these steps need a human at a browser (GitHub and t3 both use OAuth
# device flows, and neither can be scripted without pasting a long-lived token
# into the box — which is worse). Everything *around* those two — SSH key,
# key upload, git identity, getting the server to pick the authorization up —
# is done here so there is nothing left to remember or get wrong.
#
# Safe to re-run: every step checks whether it is already done.
set -uo pipefail

# Keep a plain-text copy of the run: the terminal keeps its colours and stays a
# real TTY (gh, t3 and claude read it directly, so it must not become a pipe),
# while every step/ok/warn/error also lands in the file. Default is the app
# user's state dir; FIRST_LOGIN_LOG relocates it, FIRST_LOGIN_LOG= disables.
: "${FIRST_LOGIN_LOG:=$HOME/.local/state/first-login.log}"
LOG_FILE=$FIRST_LOGIN_LOG
if [[ -n $LOG_FILE ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '\n==== %s ====\n' "$(date '+%F %T %Z')" >> "$LOG_FILE"
fi

# emit CHANNEL LINE — print LINE (a printf-style \n/\033 string) to the
# terminal and append a stripped, plain copy to the log.
emit() {
    local channel=$1 line=$2
    if [[ $channel == err ]]; then
        printf '%b\n' "$line" >&2
    else
        printf '%b\n' "$line"
    fi
    [[ -n $LOG_FILE ]] || return 0
    printf '%b\n' "$line" | sed -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

step()  { emit out "\n\033[1;34m==> $*\033[0m"; }
log()   { emit out "    $*"; }
ok()    { emit out "    \033[32mok\033[0m $*"; }
warn()  { emit err "    \033[33mwarn\033[0m $*"; }
die()   { emit err "\n\033[31merror\033[0m $*"; exit 1; }

# The app user owns this script, so its own owner is the account to switch to —
# `id -un` here would just say root, which is the thing being refused.
[[ $EUID -ne 0 ]] || die "run this as the app user, not root:
    machinectl shell $(stat -c '%U' "${BASH_SOURCE[0]}")@"

command -v gh >/dev/null || die "gh is not on PATH — run provision.sh first"
command -v t3 >/dev/null || die "t3 is not on PATH — run provision.sh first"

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
#
# stderr is kept, not dropped: when the CLI fails outright (it does, for
# instance, when it is run from inside a process the server itself spawned and
# the launcher IPC channel is not inherited) every grep below silently finds
# nothing, and the script would report "already authorized" and then a link
# warning for a box whose real problem is that the command never ran.
connect_status() { t3 connect status 2>&1; }

# The environment link is provisioned asynchronously, well after the server is
# listening: the HTTP server is up in about a second, then it reconciles the
# desired link and starts the relay client, which has to reach Cloudflare and
# register its tunnel connections. On a healthy box that lands ~20-30s after
# the restart.
#
# The timeout is not set from that happy path, though, because the server does
# not report anything until it is finished trying. t3 wraps the reconcile in
#
#     Effect.retry({ while: <not 400/401/409>,
#                    schedule: exponential(1s) capped at 30s, upTo 10 minutes })
#
# and only then logs "reconciled" or "Failed to reconcile". Every transport
# failure and every other HTTP status — a relay 403 included — is wrapped as
# EnvironmentHttpInternalServerError, which is not in that stop list, so it is
# retried for the full ten minutes. Waiting two minutes and reporting "no
# outcome logged" therefore said nothing about the box: it was the guaranteed
# result of asking before t3 was done. Wait out t3's own budget instead, plus a
# little slack for the last attempt to finish.
#
# Only the three refusal statuses short-circuit, and wait_for_link returns as
# soon as one of them is logged, so a definite failure is still reported at
# once rather than after ten minutes.
LINK_WAIT_SECONDS=${LINK_WAIT_SECONDS:-660}

# ...but only if the server is actually up. `systemctl restart` returning 0 says
# the unit was started, not that the server behind it survived: the unit runs a
# launcher which starts the pinned runtime, and that can exit, crash-loop or
# come up against a runtime that was never built, all while 'is-active' reads
# fine for a while. Without this check the two failures are indistinguishable
# from the outside — both look like dots on the screen — and waiting two minutes
# for a link is nonsense if nothing is listening.
#
# server-runtime.json is written by the server itself once it is listening, so
# "newer than the marker taken just before the restart, with a live pid in it"
# is the one local fact that distinguishes a running server from a dead unit.
SERVER_WAIT_SECONDS=${SERVER_WAIT_SECONDS:-45}
RUNTIME_JSON=$HOME/.t3/userdata/server-runtime.json
SERVICE_LOG=$HOME/.t3/userdata/logs/boot-service.log

# What the app connects through is the environment link and the managed tunnel
# behind it, in that order: the server provisions the link with a call to the
# relay, and only then launches the relay client for it. So a box with no
# tunnel is almost always a box with no link, and the two want opposite fixes.
# The server writes both outcomes to its own log, so read that rather than
# infer a cause from the absence of a link.
#
# systemd appends to this file across restarts, so scope every read to the
# current boot — a previous boot's success must not answer for this one. The
# server logs "Listening on ..." as it starts, which is the boundary.
LOG_SCAN_LINES=${LOG_SCAN_LINES:-5000}

current_boot_log() {
    [[ -s $SERVICE_LOG ]] || return 1
    tail -n "$LOG_SCAN_LINES" "$SERVICE_LOG" |
        awk '/Listening on http/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'
}

# The reconcile failure line together with its indented cause block. t3 puts
# the HTTP status in there, and that is the one fact separating "could not
# reach the relay" from "the relay said no" — which are not the same bug.
reconcile_failure() {
    awk '
        /Failed to reconcile T3 Connect desired link/ { block = $0 "\n"; grab = 1; next }
        grab && /^[[:space:]]/                       { block = block $0 "\n"; next }
        grab                                         { grab = 0 }
        END { printf "%s", block }
    ' <<<"$1"
}

server_running() {
    local marker=$1 pid
    systemctl --user is-active --quiet t3code.service || return 1
    [[ -s $RUNTIME_JSON && $RUNTIME_JSON -nt $marker ]] || return 1
    pid=$(jq -r '.pid // empty' "$RUNTIME_JSON" 2>/dev/null)
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

# Fails loudly rather than returning, because everything after it is waiting on
# a server that is not there.
wait_for_server() {
    local marker=$1 deadline=$((SECONDS + SERVER_WAIT_SECONDS))
    while ! server_running "$marker"; do
        if ! systemctl --user is-active --quiet t3code.service; then
            [[ -t 1 ]] && printf '\n'
            die "t3code.service is not running after the restart:
    systemctl --user status t3code.service
    tail -n 50 $SERVICE_LOG"
        fi
        if ((SECONDS >= deadline)); then
            [[ -t 1 ]] && printf '\n'
            die "the unit is active but the server never reported itself
    listening (no fresh $RUNTIME_JSON after ${SERVER_WAIT_SECONDS}s). The unit
    starts a launcher, which starts the pinned runtime — that is the part that
    did not come up:
    tail -n 50 $SERVICE_LOG
    systemctl --user status t3code.service
    Rebuild the pinned runtime with './setup.sh --only t3-service' as root."
        fi
        [[ -t 1 ]] && printf '.'
        sleep 1
    done
    [[ -t 1 ]] && printf '\n'
    log "server listening on $(jq -r .origin "$RUNTIME_JSON" 2>/dev/null)"
}

wait_for_link() {
    local deadline=$((SECONDS + LINK_WAIT_SECONDS)) status
    while :; do
        status=$(connect_status)
        if grep -q 'Environment link: provisioned' <<<"$status"; then
            [[ -t 1 ]] && printf '\n'
            return 0
        fi
        # A logged reconcile failure is final for this boot: t3 retries the
        # relay call with backoff and only writes that line once it has given
        # up, and it does not start over on its own. Stop waiting out a link
        # that is not coming — the diagnosis below has the cause either way.
        if [[ -n $(reconcile_failure "$(current_boot_log || true)") ]]; then
            [[ -t 1 ]] && printf '\n'
            return 1
        fi
        ((SECONDS < deadline)) || break
        [[ -t 1 ]] && printf '.'
        sleep 2
    done
    [[ -t 1 ]] && printf '\n'
    return 1
}

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

# Push notifications and Live Activities on the phone are off until something
# turns them on, and nothing in the install does. On by default here: this box
# is driven from a mobile client, and an agent that finishes a long run in
# silence is the whole reason to be running one on a server.
#
# `publish` reads as a toggle in --help but is not one — it writes true unless
# --disable is passed, so a re-run cannot flip it off. The status check is only
# to keep the output honest about which run did it. Note that it cannot tell
# "never set" from "turned off on purpose" (both print `disabled`), so a box
# that was deliberately quieted gets it back on the next run of this script —
# --disable it again, or drop this block.
if connect_status | grep -q 'Publish agent activity: enabled'; then
    ok "already publishing agent activity to mobile clients"
elif t3 connect publish >/dev/null; then
    ok "publishing agent activity to mobile clients (t3 connect publish --disable to stop)"
else
    warn "could not enable agent-activity publishing — 't3 connect publish' to see why.
    Everything else works without it; you just get no push notifications."
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
    check still reads healthy. Re-run './provision.sh --only t3-service' as root to reconcile, or:
        systemctl --user disable --now ${stray[*]}"
fi

# ------------------------------------------------------------------- service
step "t3code.service"
systemctl --user cat t3code.service >/dev/null 2>&1 ||
    die "t3code.service is not installed — run './provision.sh --only t3-service' as root first."

# The environment link is provisioned by the server on its next start, so a
# freshly authorized box needs one restart. Only then: a restart drops the
# tunnel and any live Claude sessions, so it is not something to do on every run.
if connect_status | grep -q 'Environment link: provisioned'; then
    systemctl --user start t3code.service || die "t3code.service failed to start —
    tail -n 50 $HOME/.t3/userdata/logs/boot-service.log"
else
    log "restarting so the server picks up the authorization"
    marker=$(mktemp) && trap 'rm -f "$marker"' EXIT
    systemctl --user restart t3code.service || die "t3code.service failed to start —
    tail -n 50 $SERVICE_LOG"
    log "waiting for the server to come up (up to ${SERVER_WAIT_SECONDS}s)"
    wait_for_server "$marker"
    log "waiting for the environment link and its tunnel"
    log "(usually ~30s; up to ${LINK_WAIT_SECONDS}s, because t3 retries a failed"
    log "relay call for ten minutes before it reports either way)"
    wait_for_link || true
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

# Three different failures end with 'Environment link: pending server startup',
# and the status output cannot tell them apart — it reports the link as absent
# whether the relay refused it, the tunnel never came up, or the server has not
# asked yet. Split them on what the server logged this boot, because the fix
# for one is wrong for the other two.
boot_log=$(current_boot_log || true)
failure=$(reconcile_failure "$boot_log")

if connect_status | grep -q 'Environment link: provisioned'; then
    ok "environment link provisioned"
elif [[ -n $failure ]]; then
    # The relay answered and declined. Nothing below the link layer has run at
    # this point: no link means no managed tunnel, so no relay client either,
    # and pointing at cloudflared or a firewall here sends people down a hole.
    hint=""
    if grep -qE '\(403 ' <<<"$failure"; then
        # A 403 is a refusal, not a transport error, and t3 tags it
        # 'EnvironmentHttpInternalServerError' and retries it for minutes
        # before logging — so neither the tag nor the delay means "transient".
        hint="

    403 is the relay declining to create the link rather than failing to serve
    the request, so restarting alone will not change the answer. Check the
    environments at https://app.t3.codes: an account that already holds its
    allowed environment link refuses the next one, and releasing the stale
    entry there is the fix. Then:
        systemctl --user restart t3code.service"
    fi
    warn "the server reached the relay and the relay refused to provision the
    environment link. This is not a tunnel, firewall or relay-client problem —
    the relay client is only started once the link exists, which is why it is
    not running. What the server logged:

$(sed 's/^/        /' <<<"$failure")$hint"
elif grep -q 'T3 Connect desired link reconciled' <<<"$boot_log"; then
    # The link exists; only the tunnel behind it is missing. This is the one
    # case where the relay client really is the suspect.
    warn "the environment link reconciled but its tunnel has not registered a
    connection. The relay client is what the app connects through and it needs
    outbound UDP/7844 to Cloudflare (it falls back to TCP/7844 for http2):
        grep -i 'relay client' $SERVICE_LOG | tail
        systemctl --user restart t3code.service"
else
    # Silence *after* t3's own retry budget has run out is a different thing
    # from silence during it, and this branch is now only reached once the
    # budget is gone. t3 writes one line or the other at the end of the
    # reconcile no matter how it ends, so nothing written means the reconcile
    # never ran — the loop is gated on the desired-link secret and returns
    # without logging when it is unset. `t3 connect link` is what sets it, and
    # it only sets it after the browser step completes.
    warn "the server never attempted the environment link. It logged neither
    success nor failure in the ${LINK_WAIT_SECONDS}s since it started listening, and t3's
    own retry budget is ten minutes — so this is not something still in
    flight. The reconcile is skipped without logging when the desired-link
    flag is unset, which is the state a cancelled or half-finished
    't3 connect link' leaves behind:
        t3 connect status        # 'Exposure: enabled' is that flag
    If it says disabled, re-run the authorization and let it finish:
        t3 connect link --headless
        systemctl --user restart t3code.service
    If it says enabled, the server did not pick it up — read its log:
        grep -i 'desired link' $SERVICE_LOG | tail"
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
