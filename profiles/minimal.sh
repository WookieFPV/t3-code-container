#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced by lib/common.sh; nothing here is "unused"
# The smallest useful box: base packages and an unprivileged app user with a
# working systemd user session. Everything else is opt-in.
#
# Also what CI installs on every supported distribution, because it exercises
# the two roles every other role depends on.

PROFILE_DESCRIPTION="Base packages and an unprivileged app user"

ROLES=(
    base
    user
)
