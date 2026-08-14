#!/usr/bin/env bash
# Package manager abstraction.
#
# Roles name packages using *Debian* names, which are the canonical spelling
# here, and pkg_map translates. One canonical name may expand to several
# packages (build-essential) or to none at all (apt-transport-https outside
# Debian), which is why every path goes through arrays rather than strings.

# pkg_map NAME — canonical (Debian) name -> zero or more names for this family.
# Empty output means "this family does not need it", not an error.
pkg_map() {
    local n=$1
    os_detect

    case $OS_FAMILY in
        debian) printf '%s' "$n"; return ;;
    esac

    case $OS_FAMILY:$n in
        # Toolchain. node-gyp needs a C++ compiler, make and python3; the
        # Debian metapackage has no direct equivalent anywhere else.
        rhel:build-essential)     printf 'gcc gcc-c++ make' ;;
        arch:build-essential)     printf 'base-devel' ;;

        rhel:bind9-dnsutils)      printf 'bind-utils' ;;
        arch:bind9-dnsutils)      printf 'bind' ;;

        rhel:openssh-client)      printf 'openssh-clients' ;;
        arch:openssh-client)      printf 'openssh' ;;

        rhel:python3)             printf 'python3' ;;
        arch:python3)             printf 'python' ;;

        rhel:gnupg)               printf 'gnupg2' ;;
        arch:gnupg)               printf 'gnupg' ;;

        rhel:cron)                printf 'cronie' ;;
        arch:cron)                printf 'cronie' ;;

        # dbus and the pam module that lets logind open a user session. On
        # Debian these are two packages; elsewhere systemd ships the pam bits.
        rhel:libpam-systemd)      printf 'systemd' ;;
        arch:libpam-systemd)      printf 'systemd' ;;
        rhel:systemd-container)   printf 'systemd-container' ;;
        arch:systemd-container)   printf 'systemd' ;;

        arch:gh)                  printf 'github-cli' ;;

        # apt-only concepts.
        *:apt-transport-https)    printf '' ;;
        # Debian generates locales from a list; see base_setup_locale.
        rhel:locales)             printf 'glibc-langpack-en' ;;
        arch:locales)             printf '' ;;

        # Same name everywhere: bash-completion ca-certificates curl git htop
        # jq lsof nano unzip vim wget dbus nodejs npm ...
        *)                        printf '%s' "$n" ;;
    esac
}

# Roles run as separate processes, so "have we refreshed the index yet" cannot
# be a shell variable — base, gh and node would each pay for their own update.
# A marker file under /run is shared between them and vanishes on reboot.
_PKG_INDEX_MARKER=/run/.provision-pkg-index
_PKG_INDEX_MAX_AGE=1800   # seconds

# pkg_index_update — refresh the package index, at most once per half hour
# across the whole run.
pkg_index_update() {
    os_detect
    if [[ -f $_PKG_INDEX_MARKER ]]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$_PKG_INDEX_MARKER") ))
        [[ $age -lt $_PKG_INDEX_MAX_AGE ]] && return 0
    fi
    log "refreshing package index"
    case $PKG_MGR in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        dnf)    dnf -q makecache ;;
        # -Syu, not -Sy: Arch does not support partial upgrades, and refreshing
        # the index without upgrading is how you get a package built against a
        # library version that is no longer installed.
        pacman) pacman -Syu --noconfirm >/dev/null ;;
        apk)    apk update -q ;;
    esac
    : >"$_PKG_INDEX_MARKER" 2>/dev/null || true
}

# pkg_index_stale — force the next pkg_index_update to actually run. Call this
# after adding a repository.
pkg_index_stale() { rm -f "$_PKG_INDEX_MARKER" 2>/dev/null || true; }

# pkg_installed PKG — native name, not canonical. Exit status only.
pkg_installed() {
    os_detect
    case $PKG_MGR in
        # `dpkg -s` exits 0 for a package that is removed-but-not-purged, whose
        # files are gone. Ask for the status field instead.
        apt)    [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]] ;;
        # Fall back to what *provides* the name: on Fedora `vim` is supplied by
        # vim-enhanced and `wget` by wget2-wget, so a plain `rpm -q` says "not
        # installed" forever and every run reinstalls them.
        dnf)    rpm -q "$1" >/dev/null 2>&1 || rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
        # base-devel and friends are *groups*, which `pacman -Qi` never reports
        # — without the -Qg fallback every run would reinstall them and nothing
        # here would ever be idempotent on Arch.
        pacman) pacman -Qi "$1" >/dev/null 2>&1 || pacman -Qg "$1" >/dev/null 2>&1 ;;
        apk)    apk info -e "$1" >/dev/null 2>&1 ;;
    esac
}

# pkg_install CANONICAL... — install whatever is missing, quietly if nothing is.
pkg_install() {
    os_detect
    local canonical native missing=() mapped=()

    for canonical in "$@"; do
        # Word-split deliberately: one canonical name can map to several.
        read -r -a mapped <<<"$(pkg_map "$canonical")"
        for native in "${mapped[@]}"; do
            [[ -n $native ]] || continue
            pkg_installed "$native" || missing+=("$native")
        done
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "packages already present"
        return 0
    fi

    pkg_index_update
    log "installing: ${missing[*]}"
    case $PKG_MGR in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
        dnf)    dnf install -y "${missing[@]}" ;;
        pacman) pacman -S --needed --noconfirm "${missing[@]}" ;;
        apk)    apk add "${missing[@]}" ;;
    esac
}

# pkg_version PKG — installed version of a native package name, or empty.
pkg_version() {
    os_detect
    case $PKG_MGR in
        apt)    dpkg-query -W -f='${Version}' "$1" 2>/dev/null ;;
        dnf)    rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null ;;
        pacman) pacman -Qi "$1" 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' ;;
        apk)    apk info -e "$1" 2>/dev/null ;;
    esac
}

# pkg_candidate PKG — version the repos would install right now, or empty.
# Only apt can answer this cheaply and exactly; elsewhere the caller falls back
# to "install and see", which is what pkg_upgrade_to_candidate does.
pkg_candidate() {
    os_detect
    case $PKG_MGR in
        apt) apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}' ;;
        *)   printf '' ;;
    esac
}

# pkg_upgrade_to_candidate PKG — install PKG, or upgrade it if the repo has
# something newer. Used where a distro package exists but is older than the
# vendor repo we just added (gh on Debian is the case that motivated this).
pkg_upgrade_to_candidate() {
    local p=$1 installed candidate
    # Before reading the candidate, not after: callers reach here straight from
    # repo_add_deb822, and apt-cache would otherwise answer from the index as it
    # was before the repository existed — reporting the distribution's old
    # version as current and skipping the upgrade this function exists for.
    pkg_index_update
    installed=$(pkg_version "$p"); installed=${installed:-none}
    candidate=$(pkg_candidate "$p")

    if [[ -n $candidate && $installed == "$candidate" ]]; then
        ok "$p $installed is current"
        return 0
    fi

    log "$p $installed -> ${candidate:-latest}"
    case $PKG_MGR in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" ;;
        dnf)    dnf install -y "$p" ;;
        pacman) pacman -S --needed --noconfirm "$p" ;;
        apk)    apk add --upgrade "$p" ;;
    esac
}

# repo_add_deb822 NAME URI SUITES COMPONENTS KEYRING — add an apt source in
# deb822 format. Debian family only; callers must have branched already.
#
# Returns 0 if it wrote the file (index now stale), 1 if it was already correct.
repo_add_deb822() {
    local name=$1 uri=$2 suites=$3 components=$4 keyring=$5
    os_detect
    [[ $OS_FAMILY == debian ]] || die "repo_add_deb822 called on $OS_FAMILY"

    local dest=/etc/apt/sources.list.d/$name.sources tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
Types: deb
URIs: $uri
Suites: $suites
Components: $components
Architectures: $OS_ARCH
Signed-By: $keyring
EOF
    if install_file "$tmp" "$dest"; then
        rm -f "$tmp"
        pkg_index_stale
        return 0
    fi
    rm -f "$tmp"
    return 1
}
