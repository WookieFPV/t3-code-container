#!/usr/bin/env bash
# File and directory helpers. Distro-independent.

# install_file SRC DEST [MODE] [OWNER] — copy only when content differs.
# Returns 0 if it wrote, 1 if it was already correct, so callers can react to
# a change (reload systemd, refresh an index) without tracking state.
install_file() {
    local src=$1 dest=$2 mode=${3:-0644} owner=${4:-root:root}
    mkdir -p "$(dirname "$dest")"
    if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
        chmod "$mode" "$dest"; chown "$owner" "$dest"
        ok "$dest unchanged"
        return 1
    fi
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest"
    ok "wrote $dest"
    return 0
}

# ensure_line FILE LINE [OWNER] — append LINE unless already present verbatim.
ensure_line() {
    local file=$1 line=$2 owner=${3:-root:root}
    if [[ ! -e $file ]]; then
        touch "$file"
        chown "$owner" "$file"
    fi
    if grep -qxF "$line" "$file"; then
        ok "already set: $line"
    else
        printf '%s\n' "$line" >>"$file"
        ok "appended to $(basename "$file"): $line"
    fi
}

# user_dir DIR [MODE] — create DIR under $APP_HOME owned by $APP_USER,
# including every missing parent.
#
# `install -d -o u -g g ~/.local/bin` applies the ownership to `bin` only: the
# `~/.local` it creates on the way is left root:root 0755. That stays invisible
# for as long as everything only writes *inside* the leaf — npm never needs to
# create anything directly in ~/.local — and then bites the first program that
# does. Claude Code's installer is one: its `mkdir ~/.local/share` fails with
# EACCES because the app user cannot write to a root-owned ~/.local.
#
# So walk the path and own each component. Existing components are chown'd too,
# which repairs a container provisioned before this was fixed.
user_dir() {
    local dir=$1 mode=${2:-0755}
    local rest path part

    [[ $dir == "$APP_HOME"/* ]] || die "user_dir: $dir is outside $APP_HOME"

    rest=${dir#"$APP_HOME"/}
    path=$APP_HOME
    while [[ -n $rest ]]; do
        part=${rest%%/*}
        if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=; fi
        [[ -n $part ]] || continue
        path="$path/$part"
        if [[ -d $path ]]; then
            chown "$APP_USER:$APP_USER" "$path"
        else
            install -d -m 0755 -o "$APP_USER" -g "$APP_USER" "$path"
        fi
    done
    chmod "$mode" "$dir"
}
