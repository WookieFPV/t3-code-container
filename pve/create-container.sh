#!/usr/bin/env bash
# Create an LXC container on Proxmox and provision it.
#
# RUN THIS ON THE PROXMOX HOST, not inside a container.
#
# This is the only Proxmox-aware file in the repo. Everything it installs comes
# from the Ansible playbooks, which know nothing about Proxmox and run equally
# well on a VM, a cloud VPS or an Incus container — so this script is optional,
# and replacing it does not mean forking anything else.
#
# It encodes the container settings that are easy to get wrong in the wizard:
#   ip=dhcp        the wizard defaults to Static with an empty address, which
#                  attaches the NIC but configures nothing -> no network at all
#   nesting=1      required for systemd user sessions (systemctl --user)
#   unprivileged   maps container-root to an unprivileged host UID
#   onboot=1       otherwise the container stays down after a host reboot
#
# Usage:
#   ./pve/create-container.sh                        # create and provision
#   CTID=105 CT_HOSTNAME=foo ./pve/create-container.sh
#   PROFILE=dev-node ./pve/create-container.sh
#   CORES=8 MEMORY_MB=8192 DISK_GB=50 ./pve/create-container.sh
#   PROVISION=0 ./pve/create-container.sh            # create only
#   DRY_RUN=1 ./pve/create-container.sh              # print, do not run
#   LOG_FILE=/var/log/create-container.log ./pve/create-container.sh
#                                                    # also append the whole
#                                                    # run, ANSI-free, to a file
#
# Run from a terminal it asks how much CPU, RAM and disk the container should
# get; Enter keeps the defaults (4 cores, 2048 MB, 20 GB).
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------- --log
# LOG_FILE=FILE keeps the whole run — stdout and stderr — appended to FILE as
# plain text (the terminal keeps its colours). Same mechanism as provision.sh's
# --log, so a create-and-provision invocation leaves one record of everything,
# including the provisioning output pct exec streams back to the host.
LOG_FILE=${LOG_FILE:-}
if [[ -n $LOG_FILE ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '\n==== %s ====\n' "$(date '+%F %T %Z')" >> "$LOG_FILE"
    exec > >(tee >(sed -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
    # tee is still draining the pipe when the script exits; close our end and
    # wait, or the tail of the run would be lost.
    trap 'exec 1>&- 2>&-; wait 2>/dev/null || true' EXIT
fi

command -v pct >/dev/null || die "pct not found — run this on the Proxmox host"

# ------------------------------------------------------------------ defaults
# Discovered rather than hardcoded. The first version of this file shipped one
# person's LAN in the defaults (a specific resolver, a specific search domain,
# a specific CTID), which is invisible until it silently gives someone else a
# container that cannot resolve anything.

# The next free ID the cluster would hand out.
CTID=${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 100)}
CT_HOSTNAME=${CT_HOSTNAME:-dev-$CTID}

# Newest Debian system template already downloaded on this host.
if [[ -z ${TEMPLATE:-} ]]; then
    TEMPLATE=$(pveam list local 2>/dev/null |
        awk '/debian-[0-9]+-standard/ {print $1}' | sort -V | tail -1)
    [[ -n $TEMPLATE ]] || die "no Debian template found on 'local' storage.
    List what you have:  pveam list local
    Download one:        pveam update && pveam available --section system
                         pveam download local debian-13-standard_<version>_amd64.tar.zst
    Or name one yourself: TEMPLATE=local:vztmpl/... $0"
fi

# Inherit the host's own resolver and search domain: on a home network these
# are what resolves local names, and a public resolver cannot. Empty means
# "inherit from the host", which is what Proxmox does by default anyway.
NAMESERVER=${NAMESERVER:-$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)}
SEARCHDOMAIN=${SEARCHDOMAIN:-$(hostname -d 2>/dev/null || true)}

STORAGE=${STORAGE:-local-lvm}
DISK_GB=${DISK_GB:-20}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-2048}
SWAP_MB=${SWAP_MB:-512}
BRIDGE=${BRIDGE:-vmbr0}
SSH_KEYS=${SSH_KEYS:-/root/.ssh/authorized_keys}

# What to install once it is up, and whether to install it at all.
PROVISION=${PROVISION:-1}
PROFILE=${PROFILE:-t3}
TIMEZONE=${TIMEZONE:-$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)}
DRY_RUN=${DRY_RUN:-0}

# ----------------------------------------------------------------- preflight
# So a typo fails before anything is created.
if pct status "$CTID" >/dev/null 2>&1; then
    die "CTID $CTID already exists (pct status $CTID). Pick a free ID."
fi

tpl_store=${TEMPLATE%%:*}
tpl_file=${TEMPLATE#*:}
if ! pvesm list "$tpl_store" 2>/dev/null | grep -q "$(basename "$tpl_file")"; then
    die "template not found: $TEMPLATE"
fi

[[ -f $REPO_DIR/playbooks/$PROFILE.yml ]] || die "no such profile: $PROFILE
    Available: $(cd "$REPO_DIR/playbooks" && ls ./*.yml | sed 's/\.yml$//; s|^\./||' | tr '\n' ' ')"

# ---------------------------------------------------------------- resources
# The values above are the defaults. From a terminal, ask before creating; an
# empty answer keeps the default. Whatever ended up in the variables — from the
# environment or from the prompts — is validated, so a typo fails before
# anything is created. DRY_RUN and non-interactive runs never prompt.
validate_int() {   # validate_int NAME VALUE
    local name=$1 value=$2
    if [[ ! $value =~ ^[0-9]+$ ]] || (( 10#$value == 0 )); then
        die "$name must be a positive integer, got '$value'"
    fi
}
prompt_int() {     # prompt_int NAME LABEL DEFAULT
    local name=$1 label=$2 default=$3 answer
    while :; do
        printf '  %s [%s]: ' "$label" "$default"
        if ! IFS= read -r answer; then
            printf -v "$name" '%s' "$default"
            return
        fi
        if [[ -z $answer ]]; then
            printf -v "$name" '%s' "$default"
            return
        fi
        if [[ $answer =~ ^[0-9]+$ ]] && (( 10#$answer > 0 )); then
            printf -v "$name" '%s' "$answer"
            return
        fi
        printf '  %s must be a positive integer — Enter keeps %s\n' "$label" "$default"
    done
}

validate_int CORES     "$CORES"
validate_int MEMORY_MB "$MEMORY_MB"
validate_int SWAP_MB   "$SWAP_MB"
validate_int DISK_GB   "$DISK_GB"

if [[ $DRY_RUN != 1 && -t 0 ]]; then
    printf 'Size for CT %s — Enter keeps each default:\n' "$CTID"
    prompt_int CORES     "CPU cores" "$CORES"
    prompt_int MEMORY_MB "RAM (MB)"  "$MEMORY_MB"
    prompt_int DISK_GB   "Disk (GB)" "$DISK_GB"
fi

args=(
    "$CTID" "$TEMPLATE"
    --hostname     "$CT_HOSTNAME"
    --cores        "$CORES"
    --memory       "$MEMORY_MB"
    --swap         "$SWAP_MB"
    --rootfs       "$STORAGE:$DISK_GB"
    --ostype       debian
    --unprivileged 1
    --features     nesting=1
    --onboot       1
    --net0         "name=eth0,bridge=$BRIDGE,ip=dhcp,firewall=1,type=veth"
)
[[ -n $NAMESERVER   ]] && args+=(--nameserver   "$NAMESERVER")
[[ -n $SEARCHDOMAIN ]] && args+=(--searchdomain "$SEARCHDOMAIN")

# Without a key you can still get in via the Proxmox console.
if [[ -s $SSH_KEYS ]]; then
    args+=(--ssh-public-keys "$SSH_KEYS")
else
    echo "note: $SSH_KEYS is missing or empty — no SSH key will be installed" >&2
fi

if [[ $DRY_RUN == 1 ]]; then
    printf 'pct create'; printf ' %q' "${args[@]}"; printf '\n'
    [[ $PROVISION == 1 ]] &&
        printf '# then: provision CT %s with profile %q, timezone %q\n' "$CTID" "$PROFILE" "$TIMEZONE"
    exit 0
fi

# -------------------------------------------------------------------- create
log "creating CT $CTID ($CT_HOSTNAME) from $(basename "$tpl_file")"
pct create "${args[@]}"

log "starting"
pct start "$CTID"

# DHCP needs a moment; report the address so you can SSH straight in.
for _ in {1..30}; do
    ip=$(pct exec "$CTID" -- ip -4 -br addr show eth0 2>/dev/null | awk '{print $3}')
    [[ -n ${ip:-} ]] && break
    sleep 1
done
[[ -n ${ip:-} ]] ||
    die "CT $CTID started but eth0 got no address — check 'pct config $CTID' for ip=dhcp"
log "CT $CTID is up on $ip"

# ----------------------------------------------------------------- provision
# Pushing the working tree beats telling you to clone it inside the container:
# no second authentication, no waiting on a push to test a change, and it works
# whether or not the repo is public. The old two-step (install gh as root, log
# in, clone) existed only to get these files across.
if [[ $PROVISION != 1 ]]; then
    cat <<EOF

Created but not provisioned. Inside the container:

    pct enter $CTID
    <get this repo there somehow>
    ./provision.sh --profile $PROFILE -e timezone=$TIMEZONE
EOF
    exit 0
fi

log "copying the provisioner into CT $CTID"
tar -C "$REPO_DIR" --exclude=.git -czf /tmp/provision-"$CTID".tar.gz .
pct exec "$CTID" -- mkdir -p /opt/provision
pct push "$CTID" /tmp/provision-"$CTID".tar.gz /tmp/provision.tar.gz
pct exec "$CTID" -- tar -C /opt/provision -xzf /tmp/provision.tar.gz
pct exec "$CTID" -- rm -f /tmp/provision.tar.gz
rm -f /tmp/provision-"$CTID".tar.gz

log "provisioning with profile '$PROFILE'"
# provision.sh installs ansible-core inside the container and runs the playbook
# there, against localhost. Nothing is provisioned over SSH: the container has
# an address by now, but it has no SSH server, no keys and no user yet — and
# needing none of that is what keeps this script the only Proxmox-aware file in
# the repo.
#
# pve_ctid lets the playbook's closing notes say `pct enter`: its shell commands
# are meant for inside the container, but we are printing them on the host.
pct exec "$CTID" -- /opt/provision/provision.sh \
    --profile "$PROFILE" \
    -e "timezone=$TIMEZONE" \
    -e "pve_ctid=$CTID"

cat <<EOF

CT $CTID ($CT_HOSTNAME) is up on $ip and provisioned with '$PROFILE'.

Get a shell inside it:

    pct enter $CTID

Re-provision at any time, from the host:

    pct exec $CTID -- /opt/provision/provision.sh --profile $PROFILE

Or repair a single role:

    pct exec $CTID -- /opt/provision/provision.sh --only claude
EOF
