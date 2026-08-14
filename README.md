# provision

Reproducible provisioning for Linux dev containers. Pick a **profile**, run one
script, get a machine with your tools on it — as an unprivileged user, with
pinned signing keys, and safe to re-run.

Built for Proxmox LXC, but the provisioner itself knows nothing about Proxmox:
it runs on any systemd Linux you have root on — a VM, a cloud VPS, an Incus
container.

## Quick start

### On a machine you already have

```bash
git clone https://github.com/WookieFPV/t3-code-container /opt/provision
cd /opt/provision
sudo ./setup.sh --profile dev-node
```

### On Proxmox, from nothing

From the **Proxmox host**, this creates the container and provisions it in one
go:

```bash
git clone https://github.com/WookieFPV/t3-code-container
cd t3-code-container
./pve/create-container.sh                          # next free CTID, Debian, t3 profile
PROFILE=dev-node CT_HOSTNAME=devbox ./pve/create-container.sh
CORES=8 MEMORY_MB=8192 DISK_GB=50 ./pve/create-container.sh   # size it explicitly
DRY_RUN=1 ./pve/create-container.sh                # print what it would do
```

It picks the next free CTID, the newest Debian template you have downloaded and
the host's own DNS settings, sets the container options that are easy to get
wrong (unprivileged, nesting, `ip=dhcp`, start-at-boot), then pushes this
working tree in and runs `setup.sh` inside it.

Run from a terminal it asks how much CPU, RAM and disk the container should
get — Enter keeps the defaults (4 cores, 2048 MB, 20 GB), or set `CORES`,
`MEMORY_MB` and `DISK_GB` in the environment to skip the prompts. Swap defaults
to 512 MB (`SWAP_MB`).

## Profiles

```bash
./setup.sh --list
```

| Profile | What you get |
| --- | --- |
| `minimal` | Base packages and an unprivileged app user with a working systemd session |
| `dev-node` | The above plus Node, Bun, GitHub CLI (host keys pinned) and Claude Code |
| `t3` | The above plus the t3 server, its systemd unit and a nightly update timer |

A profile is a role list and a few settings — about ten lines. To build a
different kind of box, copy one:

```bash
# profiles/mine.sh
PROFILE_DESCRIPTION="Python box"
ROLES=(base user gh github-ssh)
: "${APP_USER:=dev}"
```

```bash
sudo ./setup.sh --profile mine
```

See [docs/design.md](docs/design.md#writing-a-profile) for the details, and
[Writing a role](docs/design.md#writing-a-role) to add something the roles
below do not cover.

## Usage

```
./setup.sh [options] [role...]

  -p, --profile NAME   which profile to install       (default: $PROFILE or t3)
  -r, --roles  a,b,c   install these roles instead of the profile's list;
                       dependencies are resolved and added
  -o, --only   a,b,c   run exactly these roles, without pulling in their
                       dependencies — for repairing one step
  -n, --dry-run        print the resolved plan and exit
  -l, --list           list available profiles and roles
  -h, --help           this
```

**Idempotent.** Re-run it any time; a converged run installs nothing and writes
nothing. That is asserted by `test/install-check.sh`, which CI runs on every
supported distribution.

Any setting can be overridden from the environment:

```bash
TIMEZONE=Europe/Berlin sudo -E ./setup.sh
APP_USER=alice NODE_MAJOR=22 sudo -E ./setup.sh --profile dev-node
sudo ./setup.sh --only claude        # re-run one role
sudo ./setup.sh --dry-run            # see the plan first
```

Precedence, lowest first: defaults in `lib/common.sh` < profile < environment.

### Upgrading a container provisioned by the old layout

Pull and re-run. Everything on disk — the app user, `t3code.service`, the update
timer, `~/.npmrc` — is where it was, and the roles converge onto it rather than
rebuilding it.

```bash
cd /opt/t3-code-container && git pull
sudo ./setup.sh --profile t3
```

The one interface change is module selection: `./setup.sh 40 50` is now
`./setup.sh --only t3 t3-service`. Passing a number prints the mapping instead
of failing.

## Roles

| Role | Requires | What it does |
| --- | --- | --- |
| `base` | — | Base packages, timezone, locale |
| `user` | `base` | Unprivileged app user, linger, home layout, shell environment |
| `gh` | `base` | GitHub CLI, from the vendor repo where the distribution lags |
| `github-ssh` | `base` | Pins GitHub's SSH host keys system-wide |
| `node` | `user` | Node.js and a user-owned npm prefix |
| `bun` | `user` | Bun, via the official installer |
| `claude` | `user` | Claude Code, plus optional seeded model/effort defaults |
| `t3` | `node` | The t3 CLI |
| `t3-service` | `t3` | `t3code.service` plus a nightly update timer |
| `first-login` | `user` | Installs the guided one-time account setup |

Order is derived from the `requires` line in each role's header, not from
filenames.

## Distribution support

| Tier | Distributions | What it means |
| --- | --- | --- |
| 1 | Debian 12/13, Ubuntu 24.04 | CI installs and re-runs on every push |
| 2 | Fedora, RHEL-like, Arch | Written to work, nothing tests it, warns at startup |
| — | Alpine | Refused: no systemd, and every service here is a systemd user unit |

## First login

Some things need a human at a browser — GitHub and t3 both use OAuth device
codes, and the only way to skip them is to paste a long-lived token onto the
box, which is worse. Everything *around* those is scripted, so it is one
command:

```bash
ssh devuser@<host>              # preferred: a real login session
machinectl shell devuser@       # from a root shell on the box

first-login
```

It signs you in to GitHub, generates and uploads an SSH key titled after the
hostname, sets your git identity from the account, authorizes the environment
for t3, and gets the server to pick it up. Re-runnable — every step checks
whether it is already done. Do **not** use plain `su`; see
[Troubleshooting](docs/design.md#systemctl---user-says-failed-to-connect-to-bus).

Then clone what you want to work on — the script has no way to know which:

```bash
gh repo clone <owner>/<repo> ~/code/<repo>
```

## Operating it

All units are **user** units — `systemctl --user`, never plain `systemctl`:

```bash
systemctl --user status t3code.service
tail -f ~/.t3/userdata/logs/boot-service.log   # the server's log, not the journal
systemctl --user list-timers t3-update.timer   # next nightly run
journalctl --user -u t3-update.service         # what the last update did
```

## Tests

```bash
./test/unit.sh                                  # library layer; no root, one second
sudo ./test/install-check.sh --profile minimal  # install twice, assert convergence
```

`install-check.sh` is destructive — run it in a throwaway container, which is
what [CI](.github/workflows/ci.yml) does.

## Layout

| Path | Purpose |
| --- | --- |
| `setup.sh` | Entrypoint: parse arguments, pick a profile, resolve and run the plan |
| `lib/` | The shared layer — logging, distro detection, packages, files, keys, roles |
| `profiles/` | Role lists and settings; the user-facing surface |
| `roles/<name>/install.sh` | One installable thing, with its `files/` beside it |
| `pve/create-container.sh` | Creates and provisions an LXC container; runs on the Proxmox host |
| `test/` | Unit tests and the idempotency check |
| `docs/design.md` | Why it is built this way, and the failure modes |

## Not covered

- **Firewall.** Filtering is left to the hypervisor or the cloud provider.
- **Backups.** Snapshot the container; the app user's home is the only state.

## License

[MIT](LICENSE).
