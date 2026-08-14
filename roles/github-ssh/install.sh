#!/usr/bin/env bash
# requires: base
# description: Pin GitHub's SSH host keys system-wide
#
# Without this, the first `git clone git@github.com:...` stops on
#
#   The authenticity of host 'github.com' can't be established.
#   Are you sure you want to continue connecting (yes/no/[fingerprint])?
#
# which is a prompt nobody actually verifies — the whole point of the check is
# lost if the answer is always "yes". Pinning answers it once, from fingerprints
# published out of band, for every user on the box.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

require_cmd curl jq ssh-keygen

KNOWN_HOSTS=/etc/ssh/ssh_known_hosts
# ssh.github.com is the port-443 endpoint, same keys — worth having in case the
# network this container lives on ever blocks port 22.
HOSTS='github.com,ssh.github.com'

# Published at https://docs.github.com/authentication/keeping-your-account-and-\
# data-secure/githubs-ssh-key-fingerprints — verify there before changing.
# GitHub rotated its RSA key in March 2023 after a brief exposure; these are the
# post-rotation values.
GH_HOST_KEYS=(
    "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"  # ed25519
    "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"  # ecdsa-sha2-nistp256
    "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"  # rsa
)

# Fetch the keys rather than hardcoding the base64: the API is the authority on
# what GitHub serves today, and the pinned fingerprints are what make trusting
# that fetch safe. A key GitHub adds that we have not pinned stops the run
# instead of being silently trusted.
tmp=$(mktemp)
merged=$(mktemp)
trap 'rm -f "$tmp" "$merged"' EXIT

log "fetching GitHub host keys"
curl -fsSL https://api.github.com/meta |
    jq -r --arg h "$HOSTS" '.ssh_keys[] | "\($h) \(.)"' >"$tmp"
[[ -s $tmp ]] || die "api.github.com/meta returned no ssh_keys"

mapfile -t found < <(ssh-keygen -lf "$tmp" | awk '{print $2}')
[[ ${#found[@]} -gt 0 ]] || die "could not read fingerprints from the fetched keys"

for fpr in "${found[@]}"; do
    if [[ " ${GH_HOST_KEYS[*]} " != *" $fpr "* ]]; then
        die "GitHub SSH: UNPINNED host key $fpr
    GitHub may have rotated a host key, or this response was tampered with.
    Verify the fingerprint in GitHub's docs, then add it to this role."
    fi
done
ok "GitHub host keys verified (${#found[@]} pinned key(s))"

# This role owns GitHub's lines, not the whole file: anything else already in
# ssh_known_hosts (another forge, an internal git host) is carried over. Our own
# hosts are dropped from the old content and re-appended, so what was just
# verified wins and a re-run produces byte-identical output.
if [[ -f $KNOWN_HOSTS ]]; then
    awk -v hosts="$HOSTS" '
        BEGIN { split(hosts, want, ",") }
        {
            field = ($1 ~ /^@/) ? $2 : $1
            split(field, have, ",")
            for (i in have)
                for (j in want)
                    if (have[i] == want[j]) next
            print
        }
    ' "$KNOWN_HOSTS" >"$merged"
fi
cat "$tmp" >>"$merged"

install_file "$merged" "$KNOWN_HOSTS" 0644 || true
