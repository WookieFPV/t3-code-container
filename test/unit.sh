#!/usr/bin/env bash
# Unit tests for the library layer. No root, no network, no package manager —
# these run in a second and are the first thing CI does.
#
#   ./test/unit.sh
#
# shellcheck disable=SC1090  # sources every profile in the directory, by design
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_DIR
source "$REPO_DIR/lib/common.sh"
set +e   # common.sh sets -e; a failing assertion must not abort the run

pass=0 fail=0

check() {   # check DESC EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf '\033[31mFAIL\033[0m %s\n      expected: %q\n      actual:   %q\n' "$1" "$2" "$3"
    fi
}

check_fails() {   # check_fails DESC CMD...   — the command must exit non-zero
    local desc=$1; shift
    # A subshell, because these helpers report failure with die(), which exits
    # the shell it runs in. Production callers wrap them in a command
    # substitution for the same reason.
    if ( "$@" ) >/dev/null 2>&1; then
        fail=$((fail + 1))
        printf '\033[31mFAIL\033[0m %s (expected a non-zero exit)\n' "$desc"
    else
        pass=$((pass + 1))
    fi
}

# --------------------------------------------------------------- os detection
os_detect
check "OS_FAMILY is set"                      1 "$([[ -n $OS_FAMILY ]] && echo 1)"
check "PKG_MGR is set"                        1 "$([[ -n $PKG_MGR ]] && echo 1)"
check "OS_ARCH is set"                        1 "$([[ -n $OS_ARCH ]] && echo 1)"
check "OS_VERSION_MAJOR is numeric"           1 "$([[ $OS_VERSION_MAJOR =~ ^[0-9]*$ ]] && echo 1)"

# --------------------------------------------------------------- package map
# pkg_map short-circuits on debian, so exercise the translation table directly.
map_as() { ( OS_FAMILY=$1; pkg_map "$2" ); }

check "debian passes names through" "build-essential" "$(map_as debian build-essential)"
check "rhel toolchain"              "gcc gcc-c++ make" "$(map_as rhel build-essential)"
check "arch toolchain"              "base-devel"       "$(map_as arch build-essential)"
check "rhel dnsutils"               "bind-utils"       "$(map_as rhel bind9-dnsutils)"
check "arch python"                 "python"           "$(map_as arch python3)"
check "arch gh"                     "github-cli"       "$(map_as arch gh)"
check "debian polkit daemon"        "polkitd"          "$(map_as debian polkit)"
check "rhel polkit daemon"          "polkit"           "$(map_as rhel polkit)"
check "apt-only package dropped"    ""                 "$(map_as rhel apt-transport-https)"
check "arch has no locale package"  ""                 "$(map_as arch locales)"
check "unknown name passes through" "ripgrep"          "$(map_as rhel ripgrep)"

# ------------------------------------------------------------- role metadata
check "base has no requirements"  ""      "$(roles_requires base)"
check "user requires base"        "base"  "$(roles_requires user)"
check "t3 requires node"          "node"  "$(roles_requires t3)"

for r in $(roles_all); do
    check "role '$r' has a description" 1 "$([[ -n $(roles_describe "$r") ]] && echo 1)"
    check "role '$r' is executable"     1 "$([[ -x $ROLES_DIR/$r/install.sh ]] && echo 1)"
done

for t in "$REPO_DIR"/test/*.sh; do
    # CI invokes these directly, so a missing +x fails eight jobs at once with
    # "permission denied" and nothing about why. It has happened.
    check "$(basename "$t") is executable" 1 "$([[ -x $t ]] && echo 1)"
done

# ------------------------------------------------------------ role resolution
check "transitive deps, dependency-first" \
    "base user node t3 t3-service" \
    "$(roles_resolve t3-service | tr '\n' ' ' | sed 's/ $//')"

check "a role is emitted once even when required twice" \
    "base user node bun" \
    "$(roles_resolve node bun | tr '\n' ' ' | sed 's/ $//')"

check_fails "unknown role is rejected" roles_resolve definitely-not-a-role

# A cycle must be named, not recursed into until bash gives up.
cyc=$(mktemp -d)
mkdir -p "$cyc/_x" "$cyc/_y"
printf '#!/usr/bin/env bash\n# requires: _y\n# description: x\n' >"$cyc/_x/install.sh"
printf '#!/usr/bin/env bash\n# requires: _x\n# description: y\n' >"$cyc/_y/install.sh"
out=$( ROLES_DIR=$cyc roles_resolve _x 2>&1 )
check "a dependency cycle is reported by name" 1 "$([[ $out == *"cycle involving role '_x'"* ]] && echo 1)"
rm -rf "$cyc"

# Metadata must come from the header only, so a role body mentioning the key
# cannot change what the planner does.
hdr=$(mktemp -d); mkdir -p "$hdr/_z"
printf '#!/usr/bin/env bash\n# requires: base\n# description: real\n\necho "# description: fake"\n' >"$hdr/_z/install.sh"
check "metadata stops at the end of the header" "real" "$(ROLES_DIR=$hdr roles_describe _z)"
rm -rf "$hdr"

# ------------------------------------------------------------------ profiles
for p in "$REPO_DIR"/profiles/*.sh; do
    name=$(basename "$p" .sh)
    list=$( unset ROLES; . "$p"; printf '%s ' "${ROLES[@]}" )
    # shellcheck disable=SC2086  # deliberate: $list is a role list to split
    if out=$(roles_resolve $list 2>&1); then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf '\033[31mFAIL\033[0m profile %s does not resolve: %s\n' "$name" "$out"
    fi
    check "profile '$name' has a description" 1 \
        "$( ( unset PROFILE_DESCRIPTION; . "$p"; [[ -n ${PROFILE_DESCRIPTION:-} ]] && echo 1 ) )"
done

# The t3 role refuses to run unless the allowlist contains its native deps, so
# the profile that installs it has to supply them. Cheap to assert, and it is
# exactly the kind of drift a role list edit introduces.
t3_allow=$( . "$REPO_DIR/profiles/t3.sh"; echo "$NPM_ALLOW_SCRIPTS" )
check "t3 profile allows node-pty"         1 "$([[ ,$t3_allow, == *,node-pty,*        ]] && echo 1)"
check "t3 profile allows msgpackr-extract" 1 "$([[ ,$t3_allow, == *,msgpackr-extract,* ]] && echo 1)"

# ------------------------------------------------ t3-service linger shim
# t3 aborts the install when `loginctl enable-linger` exits non-zero, so the
# shim must no-op exactly that self-call and forward everything else to the
# real binary. The forwarded exit codes are compared against the real loginctl
# so the assertions hold whether or not the test runs as root.
shim="$ROLES_DIR/t3-service/files/loginctl"
check "loginctl shim exists"       1 "$([[ -f $shim ]] && echo 1)"
check "loginctl shim is executable" 1 "$([[ -x $shim ]] && echo 1)"
check "shim no-ops 'enable-linger' (self)" 0 "$("$shim" enable-linger >/dev/null 2>&1; echo $?)"
check "shim forwards other commands" \
    "$( /usr/bin/loginctl --version >/dev/null 2>&1; echo $? )" \
    "$( "$shim" --version >/dev/null 2>&1; echo $? )"
check "shim does not swallow 'enable-linger <user>'" \
    "$( /usr/bin/loginctl enable-linger definitely-not-a-user >/dev/null 2>&1; echo $? )" \
    "$( "$shim" enable-linger definitely-not-a-user >/dev/null 2>&1; echo $? )"

# ------------------------------------------------------------------ fs helpers
tmp=$(mktemp -d)
# Own the files as whoever is running the tests: install_file chowns, and these
# tests deliberately do not need root.
me="$(id -un):$(id -gn)"
printf 'one\n' >"$tmp/src"
install_file "$tmp/src" "$tmp/dest" 0644 "$me" >/dev/null; wrote=$?
check "install_file writes a new file"     0 "$wrote"
install_file "$tmp/src" "$tmp/dest" 0644 "$me" >/dev/null; wrote=$?
check "install_file is a no-op when equal" 1 "$wrote"
printf 'two\n' >"$tmp/src"
install_file "$tmp/src" "$tmp/dest" 0644 "$me" >/dev/null; wrote=$?
check "install_file rewrites on change"    0 "$wrote"

ensure_line "$tmp/f" 'export X=1' "$me" >/dev/null
ensure_line "$tmp/f" 'export X=1' "$me" >/dev/null
check "ensure_line does not duplicate" 1 "$(grep -c 'export X=1' "$tmp/f")"
rm -rf "$tmp"

# user_dir must refuse to touch anything outside the app user's home.
check_fails "user_dir refuses paths outside APP_HOME" \
    bash -c "REPO_DIR=$REPO_DIR; source $REPO_DIR/lib/common.sh; user_dir /etc/evil"

# ---------------------------------------------------------------------- done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
