#!/usr/bin/env bash
# Role discovery, metadata and ordering.
#
# Roles replaced the old numeric module prefixes (05-user.sh, 10-apt.sh, ...).
# Numbering encodes order in the filename, which works exactly until two people
# add a role: everyone picks 25, and the only way to insert a step is to renumber
# its neighbours. Here each role declares what it needs and the order is derived,
# so a profile lists roles in whatever order reads best and a third-party role
# slots in without touching anything else.
#
# Metadata lives in a comment header, so listing roles never executes them:
#
#   #!/usr/bin/env bash
#   # requires: base user
#   # description: Node.js and a user-owned npm prefix

ROLES_DIR=${ROLES_DIR:-$REPO_DIR/roles}

# roles_all — every installable role, alphabetically.
roles_all() {
    local d
    for d in "$ROLES_DIR"/*/; do
        [[ -f $d/install.sh ]] || continue
        basename "$d"
    done
}

roles_exists() { [[ -f $ROLES_DIR/$1/install.sh ]]; }

# roles_meta ROLE KEY — read one header field, empty if absent.
roles_meta() {
    local role=$1 key=$2
    # Header only: stop at the first line that is neither a comment nor blank,
    # so a `# requires:` inside the body cannot be picked up by accident.
    awk -v key="$key" '
        /^#!/          { next }
        /^[[:space:]]*$/ { next }
        /^#/ {
            line = $0
            sub(/^#[[:space:]]*/, "", line)
            idx = index(line, ":")
            if (idx > 0 && tolower(substr(line, 1, idx - 1)) == key) {
                v = substr(line, idx + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                print v
                exit
            }
            next
        }
        { exit }
    ' "$ROLES_DIR/$role/install.sh"
}

roles_requires() { roles_meta "$1" requires; }
roles_describe() { roles_meta "$1" description; }

# roles_resolve ROLE... — print the full install order: every requested role
# plus everything it depends on, each exactly once, dependencies first.
#
# Depth-first with a three-colour marking, so a dependency cycle is reported by
# name instead of recursing until bash gives up.
roles_resolve() {
    local -A _state=()
    local -a _order=()
    local r

    _visit() {
        local role=$1 parent=${2:-} dep
        local -a deps

        roles_exists "$role" || die "unknown role: $role${parent:+ (required by $parent)}
    Available: $(roles_all | tr '\n' ' ')"

        case ${_state[$role]:-} in
            done)    return 0 ;;
            # A cycle is a bug in the role headers, not something to work around.
            visiting) die "dependency cycle involving role '$role'" ;;
        esac

        _state[$role]="visiting"
        read -r -a deps <<<"$(roles_requires "$role")"
        for dep in "${deps[@]}"; do
            [[ -n $dep ]] || continue
            _visit "$dep" "$role"
        done
        # Quoted: bash parses an unquoted `done` here fine, but it is a keyword
        # one edit away from being read as one.
        _state[$role]="done"
        _order+=("$role")
    }

    for r in "$@"; do _visit "$r"; done
    unset -f _visit

    [[ ${#_order[@]} -gt 0 ]] || return 0
    printf '%s\n' "${_order[@]}"
}

# roles_run ROLE — execute one role in its own bash process.
#
# A subshell would be cheaper, but a separate process is what makes a role
# unable to leak state into the next one: a stray variable or a `cd` in one role
# then cannot change what the following role does, so running the full profile
# and running a single role with --only behave identically.
roles_run() {
    local role=$1
    header "$role${2:+ — $2}"
    ROLE_DIR="$ROLES_DIR/$role" bash "$ROLES_DIR/$role/install.sh"
}
