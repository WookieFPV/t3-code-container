#!/usr/bin/env bash
# Unit tests for the shipped helper scripts. No root, no network, no package
# manager — these run in a second and are the first thing CI does.
#
#   ./test/unit.sh
#
# The bash implementation had a library layer to test. The playbooks replaced
# most of it with Ansible modules, which are somebody else's tests — what is
# left, and what these cover, is the handful of scripts the roles still ship
# because their logic is genuinely intricate: signing-key pinning, the npm
# allow-scripts check, and the pinned-runtime check. Those are exactly the
# pieces worth being able to run on their own, and this is the payoff for
# keeping them as scripts rather than dissolving them into tasks.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pass=0 fail=0

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf '\033[31mFAIL\033[0m %s\n' "$*"; }

succeeds() {   # succeeds DESC CMD...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok; else bad "$desc (expected exit 0)"; fi
}

fails() {      # fails DESC CMD...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then bad "$desc (expected a non-zero exit)"; else ok; fi
}

says() {       # says DESC PATTERN CMD...  — output must match PATTERN
    local desc=$1 pattern=$2; shift 2
    local out
    out=$("$@" 2>&1)
    if [[ $out == *"$pattern"* ]]; then
        ok
    else
        bad "$desc
      expected output containing: $pattern
      actual: $out"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ------------------------------------------------ check-npmrc-allow-scripts.sh
# The single most expensive failure mode in this repo: an .npmrc that does not
# allow t3's native install scripts produces a server that installs cleanly and
# crash-loops at startup.
CHECK_NPMRC="$REPO_DIR/roles/t3/files/check-npmrc-allow-scripts.sh"

printf 'prefix=/home/devuser/.local\nallow-scripts=node-pty,msgpackr-extract\n' \
    >"$tmp/npmrc-good"
printf 'prefix=/home/devuser/.local\n' >"$tmp/npmrc-no-line"
printf 'allow-scripts=node-pty\n' >"$tmp/npmrc-partial"
# Last assignment wins in an npmrc, which the check has to reproduce.
printf 'allow-scripts=node-pty\nallow-scripts=node-pty,msgpackr-extract\n' \
    >"$tmp/npmrc-last-wins"
printf 'allow-scripts=node-pty,msgpackr-extract\nallow-scripts=esbuild\n' \
    >"$tmp/npmrc-last-wins-bad"

succeeds "npmrc with both deps" \
    "$CHECK_NPMRC" "$tmp/npmrc-good" node-pty,msgpackr-extract
fails "npmrc with no allow-scripts line" \
    "$CHECK_NPMRC" "$tmp/npmrc-no-line" node-pty,msgpackr-extract
fails "npmrc missing one dep" \
    "$CHECK_NPMRC" "$tmp/npmrc-partial" node-pty,msgpackr-extract
succeeds "npmrc where the last line has both" \
    "$CHECK_NPMRC" "$tmp/npmrc-last-wins" node-pty,msgpackr-extract
fails "npmrc where the last line drops them again" \
    "$CHECK_NPMRC" "$tmp/npmrc-last-wins-bad" node-pty,msgpackr-extract
fails "npmrc that does not exist" \
    "$CHECK_NPMRC" "$tmp/nonexistent" node-pty
says "the error names the missing dependency" "msgpackr-extract" \
    "$CHECK_NPMRC" "$tmp/npmrc-partial" node-pty,msgpackr-extract
says "the error says how to fix it" "provision.sh --only node,t3" \
    "$CHECK_NPMRC" "$tmp/npmrc-partial" node-pty,msgpackr-extract
fails "wrong argument count" "$CHECK_NPMRC" "$tmp/npmrc-good"

# A substring must not count as a match: an allowlist of "node-pty-prebuilt"
# does not allow "node-pty".
printf 'allow-scripts=node-pty-prebuilt\n' >"$tmp/npmrc-substring"
fails "a longer package name is not a match" \
    "$CHECK_NPMRC" "$tmp/npmrc-substring" node-pty

# ------------------------------------------------------------ verify-keyring.sh
VERIFY_KEYRING="$REPO_DIR/roles/keyring/files/verify-keyring.sh"

fails "verify-keyring with too few arguments" "$VERIFY_KEYRING" /dev/null NAME
fails "verify-keyring on a file that does not exist" \
    "$VERIFY_KEYRING" "$tmp/nonexistent" NAME AAAA
says "verify-keyring says which file it cannot read" "cannot read" \
    "$VERIFY_KEYRING" "$tmp/nonexistent" NAME AAAA

if command -v gpg >/dev/null; then
    # A real key, generated here, so the test needs no network and no fixture
    # that could rot.
    export GNUPGHOME="$tmp/gnupg"
    install -d -m 0700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-generate-key \
        'Keyring Test <test@example.invalid>' default default never >/dev/null 2>&1
    gpg --batch --quiet --export >"$tmp/key.gpg" 2>/dev/null
    fpr=$(gpg --with-colons --show-keys "$tmp/key.gpg" 2>/dev/null |
        awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}')

    if [[ -n ${fpr:-} ]]; then
        succeeds "a pinned key verifies" \
            "$VERIFY_KEYRING" "$tmp/key.gpg" Test "$fpr"
        succeeds "a pinned key among several pins verifies" \
            "$VERIFY_KEYRING" "$tmp/key.gpg" Test AAAABBBBCCCC "$fpr"
        fails "an unpinned key is refused" \
            "$VERIFY_KEYRING" "$tmp/key.gpg" Test AAAABBBBCCCC
        says "the refusal names the offending fingerprint" "UNPINNED signing key $fpr" \
            "$VERIFY_KEYRING" "$tmp/key.gpg" Test AAAABBBBCCCC
        # Armored input must work too: NodeSource ships its key that way and the
        # role installs it verbatim rather than dearmoring.
        gpg --batch --quiet --armor --export >"$tmp/key.asc" 2>/dev/null
        succeeds "an armored keyring verifies the same way" \
            "$VERIFY_KEYRING" "$tmp/key.asc" Test "$fpr"
    else
        printf '\033[33mskip\033[0m could not generate a test key\n'
    fi

    printf 'not a key\n' >"$tmp/garbage"
    fails "a file with no PGP keys is refused" \
        "$VERIFY_KEYRING" "$tmp/garbage" Test AAAA
else
    printf '\033[33mskip\033[0m gpg is not installed — keyring tests skipped\n'
fi

# ------------------------------------------------------- check-pinned-runtime.sh
CHECK_RUNTIME="$REPO_DIR/roles/t3-service/files/check-pinned-runtime.sh"

fails "check-pinned-runtime with no argument" "$CHECK_RUNTIME"

if command -v node >/dev/null; then
    # No service-state.json at all: warn and pass, rather than failing a
    # provisioning run over a check that has nothing to look at.
    install -d "$tmp/t3-empty/runtime"
    succeeds "a missing service-state.json is not fatal" \
        "$CHECK_RUNTIME" "$tmp/t3-empty"
    says "and it says why" "skipping the node-pty check" \
        "$CHECK_RUNTIME" "$tmp/t3-empty"

    # An activeVersion whose node-pty is not there must fail loudly: this is the
    # runtime systemd would boot.
    install -d "$tmp/t3-broken/runtime/versions/1.2.3/node_modules"
    printf '{"activeVersion":"1.2.3"}\n' >"$tmp/t3-broken/runtime/service-state.json"
    fails "an unloadable node-pty is fatal" \
        "$CHECK_RUNTIME" "$tmp/t3-broken"
    says "the error names the rebuild command" "npm rebuild node-pty" \
        "$CHECK_RUNTIME" "$tmp/t3-broken"

    # A version whose node-pty does load.
    install -d "$tmp/t3-ok/runtime/versions/9.9.9/node_modules/node-pty"
    printf '{"activeVersion":"9.9.9"}\n' >"$tmp/t3-ok/runtime/service-state.json"
    printf '{"name":"node-pty","main":"index.js"}\n' \
        >"$tmp/t3-ok/runtime/versions/9.9.9/node_modules/node-pty/package.json"
    printf 'module.exports = {};\n' \
        >"$tmp/t3-ok/runtime/versions/9.9.9/node_modules/node-pty/index.js"
    succeeds "a loadable node-pty passes" "$CHECK_RUNTIME" "$tmp/t3-ok"
    says "and says which version it checked" "9.9.9" "$CHECK_RUNTIME" "$tmp/t3-ok"
else
    printf '\033[33mskip\033[0m node is not installed — runtime tests skipped\n'
fi

# ------------------------------------------------------------ github-host-keys
# Only the argument handling: everything else needs the network, and the roles
# that do are covered by the install-check runs.
HOST_KEYS="$REPO_DIR/roles/github-ssh/files/github-host-keys.sh"
fails "github-host-keys with no arguments" "$HOST_KEYS"
fails "github-host-keys with no fingerprints" "$HOST_KEYS" "$tmp/known_hosts"

# ---------------------------------------------------------------------- report
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
