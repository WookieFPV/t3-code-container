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
# Two sources, because api.github.com has outages (a run has failed on a 504
# from it while github.com itself was serving fine) and a box that cannot
# provision because a status API is down is a box waiting on somebody else's
# incident. If the API does not answer we ask the SSH port for its own keys.
# Neither source is trusted on its own: whatever comes back has to match the
# pinned fingerprints, which is the same check either way.
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

for c in curl jq ssh-keygen ssh-keyscan; do
    command -v "$c" >/dev/null || die "$c is missing — the 'base' role installs it"
done

fetched=$(mktemp)
merged=$(mktemp)
trap 'rm -f "$fetched" "$merged"' EXIT

# Sorted so the file does not depend on the order a source happened to return
# the keys in: the two sources disagree about it, and without this a rerun that
# fell back would rewrite known_hosts and report a change that was not one.
key_source=api.github.com/meta
if curl -fsS --max-time 20 --retry 3 --retry-connrefused --retry-all-errors \
        https://api.github.com/meta 2>/dev/null |
        jq -r --arg h "$HOSTS" '.ssh_keys[] | "\($h) \(.)"' |
        sort >"$fetched" && [[ -s $fetched ]]; then
    :
else
    # ssh-keyscan prints the banner it saw as comments on stdout; those would
    # end up in known_hosts, so keep only the key lines and put our own host
    # list in front of the key, exactly as the jq above does.
    key_source="ssh-keyscan (api.github.com did not answer)"
    ssh-keyscan -T 20 -t rsa,ecdsa,ed25519 github.com 2>/dev/null |
        awk -v h="$HOSTS" '$1 !~ /^#/ && NF >= 3 { print h, $2, $3 }' |
        sort >"$fetched" || true
    [[ -s $fetched ]] || die "neither api.github.com/meta nor ssh-keyscan
    returned GitHub's host keys — check this box's network access to github.com"
fi

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
printf 'GitHub host keys verified against pinned fingerprints (%d key(s), from %s)\n' \
    "${#found[@]}" "$key_source"

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

# root-owned when we are root, which is how the role runs it. A hand run as
# yourself against a scratch file is the other documented use, and -o root would
# fail it after having already written the content — worse than not asking.
if [[ $(id -u) -eq 0 ]]; then
    install -m 0644 -o root -g root "$merged" "$known_hosts"
else
    install -m 0644 "$merged" "$known_hosts"
fi
printf 'changed\n'
