#!/usr/bin/env bash
# Signing-key verification.
#
# The property worth keeping from the first version of this repo: a third-party
# repository's key is checked against fingerprints committed here *before* the
# package manager is ever told to trust it, and re-checked on every run so drift
# is caught rather than only tampering-at-install.
#
# This is the main thing this project does that the popular Proxmox helper
# scripts do not: they download vendor keys over TLS and trust whatever arrives.

# verify_keyring FILE NAME FPR... — fail closed unless every primary key in
# FILE is one we pinned, and at least one pinned key is present.
#
# Pinning the key is sufficient — the package manager then verifies every
# package against it, so per-file checksums would add nothing.
verify_keyring() {
    local file=$1 name=$2; shift 2
    local expected=("$@") found=() fpr

    command -v gpg >/dev/null || die "gpg is missing — the 'base' role installs it"

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
    role that called this), then add it to that role's key array."
        fi
    done

    local match=0
    for fpr in "${expected[@]}"; do
        [[ " ${found[*]} " == *" $fpr "* ]] && match=1
    done
    [[ $match -eq 1 ]] || die "$name: none of the pinned keys are present"

    ok "$name: signing key verified (${#found[@]} pinned key(s))"
}

# fetch_keyring URL DEST NAME FPR... — download, verify, then install. The
# order is the point: nothing untrusted is ever written where apt will read it.
# ARMORED=1 in the environment dearmors on the way through.
fetch_keyring() {
    local url=$1 dest=$2 name=$3; shift 3
    local tmp

    if [[ -f $dest ]]; then
        verify_keyring "$dest" "$name" "$@"
        return 0
    fi

    install -d -m 0755 "$(dirname "$dest")"
    tmp=$(mktemp)
    log "downloading $name signing key"
    if [[ ${ARMORED:-0} == 1 ]]; then
        curl -fsSL "$url" | gpg --dearmor -o "$tmp"
    else
        curl -fsSL "$url" -o "$tmp"
    fi
    verify_keyring "$tmp" "$name" "$@"
    install -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    ok "installed $dest"
}
