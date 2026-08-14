#!/usr/bin/env bash
# System-level operations that differ per distribution: accounts, linger,
# timezone, locale. Roles call these instead of branching themselves.

# sys_user_create USER — create an unprivileged, password-less account.
#
# `useradd` rather than Debian's `adduser`: shadow-utils ships it on every
# family, so this needs no branch. -m creates the home directory, and no
# supplementary groups are added — the app user deliberately has no sudo.
sys_user_create() {
    local u=$1
    if id "$u" >/dev/null 2>&1; then
        ok "user $u exists"
        return 0
    fi
    log "creating $u"
    useradd --create-home --shell /bin/bash --comment "" "$u" ||
        die "useradd $u failed"
    # No password at all, rather than a locked-but-set one: the account is
    # reached over SSH keys or `machinectl shell`, never by typing a password.
    passwd --delete "$u" >/dev/null 2>&1 || true
    passwd --lock "$u" >/dev/null 2>&1 || true
    ok "created $u"
}

# sys_enable_linger USER — start this user's systemd manager at boot, and wait
# for the runtime directory it creates.
#
# Lingering is what lets the user's units run without an active login, i.e. the
# server starts at boot and survives you logging out. Later roles run
# `systemctl --user`, which needs /run/user/UID to exist — so wait for the user
# manager rather than racing it.
sys_enable_linger() {
    local u=$1 runtime_dir
    os_require_systemd

    if [[ $(loginctl show-user "$u" -p Linger --value 2>/dev/null) == yes ]]; then
        ok "linger already enabled for $u"
    else
        log "enabling linger for $u"
        loginctl enable-linger "$u" || die "loginctl enable-linger $u failed"
    fi

    runtime_dir="/run/user/$(id -u "$u")"
    for _ in {1..30}; do
        [[ -d $runtime_dir ]] && break
        sleep 0.5
    done
    [[ -d $runtime_dir ]] || die "$runtime_dir never appeared.
    In an LXC container this is usually the missing 'nesting' feature
    (Proxmox: Container -> Options -> Features -> Nesting, then reboot).
    On a very minimal image, check that dbus and the systemd PAM module are
    installed — logind cannot open a user session without them."
    ok "user systemd session ready ($runtime_dir)"
}

# sys_set_timezone TZ — systemd timers fire in local time, so this is what
# "04:00" means for the nightly update. Container images are almost always UTC.
sys_set_timezone() {
    local tz=$1
    if [[ $(timedatectl show -p Timezone --value 2>/dev/null) == "$tz" ]]; then
        ok "timezone already $tz"
        return 0
    fi
    log "setting timezone to $tz"
    if timedatectl set-timezone "$tz" 2>/dev/null; then
        ok "timezone $tz"
    elif [[ -f /usr/share/zoneinfo/$tz ]]; then
        # timedatectl refuses to work without a running systemd; the symlink is
        # what it would have written anyway.
        ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
        printf '%s\n' "$tz" >/etc/timezone
        ok "timezone $tz (via /etc/localtime)"
    else
        warn "unknown timezone '$tz' — leaving the system default in place"
    fi
}

# sys_set_locale LOCALE — generate a UTF-8 locale and make it the default.
#
# A stock container image generates no locales, but `pct enter` and ssh both
# carry LANG in from wherever you came from — so every package operation
# answers with a wall of "locale: Cannot set LC_CTYPE" and perl "Falling back to
# the standard locale". Harmless, but it buries real output.
sys_set_locale() {
    local loc=$1 short=${1%%.*}
    os_detect

    case $OS_FAMILY in
        debian|arch)
            # locale -a reports the generated form: en_US.utf8, not en_US.UTF-8.
            if locale -a 2>/dev/null | grep -qix "${short}.utf8"; then
                ok "locale $loc already generated"
            else
                log "generating locale $loc"
                ensure_line /etc/locale.gen "$loc UTF-8"
                locale-gen >/dev/null || die "locale-gen failed"
            fi
            ;;
        rhel)
            # glibc-langpack-* ships the locale prebuilt; the base role installs
            # it via the `locales` canonical name.
            locale -a 2>/dev/null | grep -qix "${short}.utf8" ||
                warn "locale $loc is not available — install glibc-langpack-${short%%_*}"
            ;;
    esac

    # Three places, because which one is authoritative depends on the distro and
    # on whether systemd is running. Checking only the Debian one meant a Fedora
    # box rewrote /etc/locale.conf on every run — harmless, but it is exactly the
    # sort of "converges except for this" that idempotency tests exist to catch.
    local current='' f
    for f in /etc/default/locale /etc/locale.conf; do
        [[ -r $f ]] || continue
        # shellcheck disable=SC1090  # one of two known locale files, chosen at runtime
        current=$( . "$f" 2>/dev/null; echo "${LANG:-}" )
        [[ -n $current ]] && break
    done
    # `if`, not `[[ ... ]] && current=$(...)`. localectl exits non-zero without a
    # running systemd, pipefail promotes that to the pipeline's status, and an
    # assignment on the right of && is the one place set -e does not forgive —
    # so the whole run died here, silently, with no message to go on.
    if [[ -z $current ]] && command -v localectl >/dev/null; then
        current=$(localectl status 2>/dev/null | sed -n 's/.*LANG=\([^ ]*\).*/\1/p') || current=
    fi

    if [[ $current == "$loc" ]]; then
        ok "default LANG already $loc"
        return 0
    fi

    if command -v update-locale >/dev/null; then
        update-locale "LANG=$loc"
    elif command -v localectl >/dev/null && localectl set-locale "LANG=$loc" 2>/dev/null; then
        :
    else
        printf 'LANG=%s\n' "$loc" >/etc/locale.conf
    fi
    ok "default LANG set to $loc"
}
