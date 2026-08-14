#!/usr/bin/env bash
# requires:
# description: Base packages, timezone and locale
#
# Runs before everything. The old layout had this second, after the user role,
# which forced that role to install dbus and the PAM module itself with a
# comment explaining why — the dependency was real but pointed the wrong way.
# Here base owns every system package and the user role can simply require it.
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

os_detect

# dbus + the systemd PAM module: logind cannot open a user session without
# them, so the user role's linger wait would time out. They are packages, so
# they belong here.
#
# build-essential and python3 are required at install time, not optional:
# node-pty (a t3 dependency) ships prebuilds for macOS and Windows only, so on
# Linux npm falls back to `node-gyp rebuild`, and node-gyp refuses to run
# without a python3 interpreter. Kept in the base list rather than the node
# role because a compiler is what any dev container is for.
pkg_install \
    apt-transport-https \
    bash-completion \
    bind9-dnsutils \
    build-essential \
    ca-certificates \
    cron \
    curl \
    dbus \
    git \
    gnupg \
    htop \
    jq \
    libpam-systemd \
    locales \
    lsof \
    nano \
    openssh-client \
    python3 \
    systemd-container \
    unzip \
    vim \
    wget

sys_set_timezone "$TIMEZONE"
sys_set_locale "$LOCALE"
