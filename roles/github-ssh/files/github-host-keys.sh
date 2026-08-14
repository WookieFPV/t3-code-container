#!/usr/bin/env bash
# github-host-keys.sh KNOWN_HOSTS FINGERPRINT... — fetch GitHub's current SSH
# host keys, verify each against the pinned fingerprints, and write them into
# KNOWN_HOSTS without disturbing anything else in the file.
#
# Without this, the first `git clone git@github.com:...` stops on
#
#   The authenticity of host 'github.com' can't be established.
#   Are you sure you want to continue connecting (yes/no/[fingerprint])?
#
# which is a prompt nobody actually verifies — the whole point of the check is
# lost if the answer is always "yes". Pinning answers it once, from fingerprints
# published out of band, for every user on the box.
#
# The keys are fetched rather than hardcoded: the API is the authority on what
# GitHub serves today, and the pinned fingerprints are what make trusting that
# fetch safe. A key GitHub adds that has not been pinned stops the run instead
# of being silently trusted.
#
# Exits 0 and prints "changed" or "unchanged" on the last line, which is how the
# Ansible task decides what to report. Kept as a script because it is the piece
# somebody has to run by hand the day GitHub rotates a key:
#
#   ./roles/github-ssh/files/github-host-keys.sh /tmp/try SHA256:... SHA256:...
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "usage: $0 KNOWN_HOSTS FINGERPRINT..."

known_hosts=$1; shift
pinned=("$@")

# ssh.github.com is the port-443 endpoint, same keys — worth having in case the
# network this container lives on ever blocks port 22.
HOSTS='github.com,ssh.github.com'

for c in curl jq ssh-keygen; do
    command -v "$c" >/dev/null || die "$c is missing — the 'base' role installs it"
done

fetched=$(mktemp)
merged=$(mktemp)
trap 'rm -f "$fetched" "$merged"' EXIT

curl -fsSL https://api.github.com/meta |
    jq -r --arg h "$HOSTS" '.ssh_keys[] | "\($h) \(.)"' >"$fetched"
[[ -s $fetched ]] || die "api.github.com/meta returned no ssh_keys"

mapfile -t found < <(ssh-keygen -lf "$fetched" | awk '{print $2}')
[[ ${#found[@]} -gt 0 ]] || die "could not read fingerprints from the fetched keys"

for fpr in "${found[@]}"; do
    if [[ " ${pinned[*]} " != *" $fpr "* ]]; then
        die "GitHub SSH: UNPINNED host key $fpr
    GitHub may have rotated a host key, or this response was tampered with.
    Verify the fingerprint in GitHub's docs, then add it to
    roles/github-ssh/defaults/main.yml."
    fi
done
printf 'GitHub host keys verified (%d pinned key(s))\n' "${#found[@]}"

# This owns GitHub's lines, not the whole file: anything else already in
# known_hosts (another forge, an internal git host) is carried over. Our own
# hosts are dropped from the old content and re-appended, so what was just
# verified wins and a re-run produces byte-identical output.
if [[ -f $known_hosts ]]; then
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
    ' "$known_hosts" >"$merged"
fi
cat "$fetched" >>"$merged"

if [[ -f $known_hosts ]] && cmp -s "$merged" "$known_hosts"; then
    printf 'unchanged\n'
    exit 0
fi

install -m 0644 -o root -g root "$merged" "$known_hosts"
printf 'changed\n'
