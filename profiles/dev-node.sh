#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced by lib/common.sh; nothing here is "unused"
# A general JavaScript/TypeScript development container: Node, Bun, the GitHub
# CLI with its host keys pinned, and Claude Code. No t3, no background service.
#
# The nearest thing to "a dev box I can ssh into and start working on".

PROFILE_DESCRIPTION="Node + Bun + GitHub CLI + Claude Code, no background service"

ROLES=(
    base
    user
    gh
    github-ssh
    node
    bun
    claude
)

# Nothing here builds native modules by default. Add package names if something
# you install does:  NPM_ALLOW_SCRIPTS=node-pty,esbuild ./setup.sh -p dev-node
: "${NPM_ALLOW_SCRIPTS:=}"
