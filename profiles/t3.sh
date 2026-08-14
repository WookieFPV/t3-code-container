#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced by lib/common.sh; nothing here is "unused"
# A T3 Code dev server: the setup this repo started as.
#
# Profiles are the whole user-facing surface. To build a different box, copy
# this file, change the role list, and run `./setup.sh --profile <name>`.
#
# Assign overridable settings with `: "${VAR:=...}"`, never `VAR=...`, so an
# environment override still wins:
#     CLAUDE_MODEL=claude-sonnet-5 ./setup.sh --profile t3

PROFILE_DESCRIPTION="T3 Code server: node, bun, gh, Claude Code, t3 + nightly updates"

ROLES=(
    base
    user
    gh
    github-ssh
    node
    bun
    claude
    t3
    t3-service
    first-login
)

# t3's native dependencies need their npm install scripts to build. The node
# role writes this into the app user's .npmrc, which is the only place the
# installs t3 runs for itself will read it from.
: "${NPM_ALLOW_SCRIPTS:=node-pty,msgpackr-extract}"

# A fresh box would otherwise start Claude on the account default. That is a
# reasonable product default and the wrong one here: this machine exists to run
# long agent sessions against real repos. Seeded, not enforced — see
# docs/design.md.
: "${CLAUDE_MODEL:=claude-opus-5[1m]}"   # [1m] = the 1M-context variant
: "${CLAUDE_EFFORT_LEVEL:=medium}"       # low | medium | high | xhigh

# The nightly t3 update timer fires at 04:00 in this timezone.
: "${TIMEZONE:=Etc/UTC}"
