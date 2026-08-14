#!/usr/bin/env bash
# Distribution detection.
#
# Everything downstream branches on OS_FAMILY, never on OS_ID: "is this apt or
# dnf" is the question a role actually has, and pinning roles to exact distro
# IDs is what made the first version of this repo Debian-only.
#
# Support tiers are deliberate and enforced by os_tier:
#
#   1  debian, ubuntu   — what CI installs and re-runs on every push
#   2  fedora, rhel-like, arch — best effort, community-maintained, no CI
#   -  alpine           — detected so the error is useful, then refused: there
#                         is no systemd, and the app user, the server unit and
#                         the update timer are all systemd user units
#
# Claiming a distro nothing tests is worse than not claiming it, so tier 2
# prints a warning naming itself rather than pretending to be supported.

# _osr KEY — read one field from /etc/os-release without leaking its variables
# into our namespace (it defines ID, NAME, VERSION... which collide easily).
_osr() { ( . /etc/os-release 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }

os_detect() {
    [[ -n ${OS_ID:-} ]] && return 0    # already detected

    [[ -r /etc/os-release ]] ||
        die "cannot read /etc/os-release — this does not look like a modern Linux"

    OS_ID=$(_osr ID)
    OS_ID_LIKE=$(_osr ID_LIKE)
    OS_NAME=$(_osr PRETTY_NAME)
    OS_VERSION_ID=$(_osr VERSION_ID)
    OS_VERSION_MAJOR=${OS_VERSION_ID%%.*}
    OS_CODENAME=$(_osr VERSION_CODENAME)

    case " $OS_ID $OS_ID_LIKE " in
        *" debian "*|*" ubuntu "*) OS_FAMILY=debian; PKG_MGR=apt    ;;
        *" fedora "*|*" rhel "*|*" centos "*)
                                   OS_FAMILY=rhel;   PKG_MGR=dnf    ;;
        *" arch "*)                OS_FAMILY=arch;   PKG_MGR=pacman ;;
        *" alpine "*)              OS_FAMILY=alpine; PKG_MGR=apk    ;;
        *)
            die "unsupported distribution: ${OS_NAME:-$OS_ID}
    Recognised families: debian, ubuntu, fedora/rhel, arch.
    If yours is close to one of these, set OS_FAMILY and PKG_MGR by hand:
        OS_FAMILY=debian PKG_MGR=apt ./setup.sh" ;;
    esac

    case $OS_ID in
        debian|ubuntu) OS_TIER=1 ;;
        alpine)        OS_TIER=0 ;;
        *)             OS_TIER=2 ;;
    esac

    # Package architecture, in the naming each family actually uses.
    case $OS_FAMILY in
        debian)
            OS_ARCH=$(dpkg --print-architecture 2>/dev/null) || OS_ARCH=
            ;;
    esac
    if [[ -z ${OS_ARCH:-} ]]; then
        case $(uname -m) in
            x86_64)  OS_ARCH=amd64 ;;
            aarch64) OS_ARCH=arm64 ;;
            armv7l)  OS_ARCH=armhf ;;
            *)       OS_ARCH=$(uname -m) ;;
        esac
    fi

    export OS_ID OS_ID_LIKE OS_NAME OS_VERSION_ID OS_VERSION_MAJOR \
           OS_CODENAME OS_FAMILY OS_TIER OS_ARCH PKG_MGR
}

# os_tier — announce what we are running on, and refuse tier 0.
#
# Called once by setup.sh rather than by each role: a role that fails on Alpine
# should fail at the top of the run, before anything has been written.
os_tier() {
    os_detect
    case $OS_TIER in
        1) ok "$OS_NAME (${OS_FAMILY}/${PKG_MGR}, $OS_ARCH) — tier 1, tested" ;;
        2) warn "$OS_NAME (${OS_FAMILY}/${PKG_MGR}, $OS_ARCH) — tier 2.
    Nothing tests this combination. Roles are written to work here, but
    failures are expected to be reported rather than already fixed." ;;
        0) die "$OS_NAME is not supported.
    Every long-running part of this setup is a systemd *user* unit — the app
    user's linger session, the server, the update timer — and Alpine has no
    systemd. Supporting it means rewriting those as OpenRC services running as
    root, which is a different design, not a port." ;;
    esac
}

# os_has_systemd — roles that install units call this before doing anything.
os_has_systemd() { [[ -d /run/systemd/system ]]; }

os_require_systemd() {
    os_has_systemd || die "systemd is not running (no /run/systemd/system).
    In a container this usually means it was started with a plain command
    instead of an init — the LXC/Incus defaults are fine, 'docker run' is not."
}
