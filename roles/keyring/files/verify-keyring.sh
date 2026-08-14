#!/usr/bin/env bash
# verify-keyring.sh FILE NAME FINGERPRINT... — fail unless every primary key in
# FILE is one that was pinned, and at least one pinned key is present.
#
# The property this exists to keep: a third-party repository's key is checked
# against fingerprints committed to this repo *before* the package manager is
# ever told to trust it, and re-checked on every run so drift is caught rather
# than only tampering-at-install. Pinning the key is sufficient — the package
# manager then verifies every package against it, so per-file checksums would
# add nothing.
#
# This is the main thing this project does that the popular Proxmox helper
# scripts do not: they download vendor keys over TLS and trust whatever arrives.
#
# Kept as a script rather than a handful of Ansible tasks so that a key rotation
# — the one time anybody reads this — can be diagnosed by running it directly:
#
#   ./roles/keyring/files/verify-keyring.sh /usr/share/keyrings/nodesource.asc \
#       NodeSource 6F71F525282841EEDAF851B42F59B5F99B1BE0B4
#
# Accepts both binary keyrings and ASCII-armored ones; `gpg --show-keys` reads
# either, so nothing has to know which form a vendor ships.
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 3 ]] || die "usage: $0 FILE NAME FINGERPRINT..."

file=$1 name=$2; shift 2
expected=("$@")

command -v gpg >/dev/null || die "gpg is missing — the 'base' role installs it"
[[ -r $file ]] || die "$name: cannot read $file"

mapfile -t found < <(
    gpg --show-keys --with-colons "$file" 2>/dev/null |
        awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}'
)
[[ ${#found[@]} -gt 0 ]] || die "$name: no PGP keys found in $file"

for fpr in "${found[@]}"; do
    if [[ " ${expected[*]} " != *" $fpr "* ]]; then
        die "$name: UNPINNED signing key $fpr
    The repo may have rotated keys, or this download was tampered with.
    Verify the fingerprint in the vendor's own documentation (linked in the
    role that called this), then add it to that role's key list."
    fi
done

match=0
for fpr in "${expected[@]}"; do
    [[ " ${found[*]} " == *" $fpr "* ]] && match=1
done
[[ $match -eq 1 ]] || die "$name: none of the pinned keys are present"

printf '%s: signing key verified (%d pinned key(s))\n' "$name" "${#found[@]}"
