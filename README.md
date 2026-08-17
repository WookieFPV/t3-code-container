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
sudo ./provision.sh --profile dev-node
```

That is the only command. `provision.sh` installs `ansible-core` from the
distribution if it is missing, then runs the playbook against the machine it is
sitting on — there is no control node, no inventory of IPs and no SSH into the
box.

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
LOG_FILE=/var/log/create-container.log ./pve/create-container.sh   # keep the whole run, ANSI-free
```

It picks the next free CTID, the newest Debian template you have downloaded and
the host's own DNS settings, sets the container options that are easy to get
wrong (unprivileged, nesting, `ip=dhcp`, start-at-boot), then pushes this
working tree in and runs `provision.sh` inside it.

Run from a terminal it asks how much CPU, RAM and disk the container should
get — Enter keeps the defaults (4 cores, 2048 MB, 20 GB), or set `CORES`,
`MEMORY_MB` and `DISK_GB` in the environment to skip the prompts. Swap defaults
to 512 MB (`SWAP_MB`).

## Profiles

```bash
./provision.sh --list
```

| Profile | What you get |
| --- | --- |
| `minimal` | Base packages and an unprivileged app user with a working systemd session |
| `dev-node` | The above plus Node, Bun, GitHub CLI (host keys pinned) and Claude Code |
| `t3` | The above plus the t3 server, its systemd unit and a nightly update timer |

A profile is a playbook: a role list and a few settings, about fifteen lines.
To build a different kind of box, copy one:

```yaml
# playbooks/mine.yml
# description: Python box
- name: Python box
  hosts: all
  become: true
  vars:
    app_user: dev
  pre_tasks:
    - ansible.builtin.import_tasks: ../tasks/preflight.yml
  roles:
    - {role: base, tags: [base]}
    - {role: user, tags: [user]}
    - {role: gh, tags: [gh]}
    - {role: github-ssh, tags: [github-ssh]}
  post_tasks:
    - ansible.builtin.import_tasks: ../tasks/done.yml
```

```bash
sudo ./provision.sh --profile mine
```

See [docs/design.md](docs/design.md#writing-a-profile) for the details, and
[Writing a role](docs/design.md#writing-a-role) to add something the roles
below do not cover.

## Usage

```
./provision.sh [options] [role...] [-- ansible-playbook options]

  -p, --profile NAME   which profile to install       (default: $PROFILE or t3)
  -o, --only   a,b,c   run exactly these roles, without their dependencies —
                       for repairing one step
  -e, --extra  K=V     override any setting (repeatable)
  -n, --dry-run        report what would change, without changing it
  -l, --list           list available profiles and roles
  -L, --log    FILE    also append everything to FILE, ANSI-free
  -h, --help           this
```

Anything after `--` goes straight to `ansible-playbook`, so
`./provision.sh -- --start-at-task 'Install t3'` and `--list-tags` work as you
would expect.

**Idempotent.** Re-run it any time; a converged run installs nothing and writes
nothing. That is asserted by `test/install-check.sh`, which CI runs on every
supported distribution.

Any setting can be overridden with `-e`:

```bash
sudo ./provision.sh -e timezone=Europe/Berlin
sudo ./provision.sh -p dev-node -e app_user=alice -e node_major=22
sudo ./provision.sh --only claude        # re-run one role
sudo ./provision.sh --dry-run            # see what would change first
sudo ./provision.sh --log /var/log/provision.log
```

Precedence, lowest first: `inventory/group_vars/all.yml` < the profile playbook < `-e`.

`--dry-run` is Ansible's `--check --diff`, so it reports honestly on packages,
files and services. The vendor install scripts (bun, Claude Code) and
`t3 service install` cannot be simulated and are reported as skipped rather than
as the work they would do.

### Upgrading a container provisioned by the bash version

Pull and re-run. Everything on disk — the app user, `t3code.service`, the update
timer, `~/.npmrc` — is where it was, and the roles converge onto it rather than
rebuilding it.

```bash
cd /opt/t3-code-container && git pull
sudo ./provision.sh --profile t3
```

Two interface changes:

- `./setup.sh` is `./provision.sh`, and settings move from the environment to
  `-e`: `TIMEZONE=Europe/Berlin ./setup.sh` becomes
  `./provision.sh -e timezone=Europe/Berlin`. Variable names are lower case now
  (`APP_USER` → `app_user`, `NODE_MAJOR` → `node_major`).
- `--roles a,b,c`, which resolved dependencies, is gone. Use a profile for a
  fixed set and `--only` for repairs; see [Roles](#roles) for what each one
  expects to already be there.

One thing changes on disk: the NodeSource keyring moves from
`/usr/share/keyrings/nodesource.gpg` to `nodesource.asc`, because the key is
installed as the vendor serves it rather than dearmored on the way past. The old
file is left behind and ignored; delete it if you like.

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

Two supporting roles are not in any profile and are included by the others:
`keyring` (fetch a vendor signing key, verify it against pinned fingerprints)
and `preflight` (assert a role's preconditions with an actionable error).

Order is the order the profile playbook lists them in. The `Requires` column is
not enforced by Ansible role dependencies on purpose — those get pulled in by
`--tags` and would make `--only claude` re-run half the profile. Each role
asserts its own preconditions instead, and tells you which step to run.

## Distribution support

| Tier | Distributions | What it means |
| --- | --- | --- |
| 1 | Debian 12/13, Ubuntu 24.04 | CI installs and re-runs on every push |
| 2 | Fedora, RHEL-like, Arch | Written to work, nothing tests it, warns at startup |
| — | Alpine | Refused: no systemd, and every service here is a systemd user unit |

Debian, Ubuntu and Fedora need only `ansible-core`, which `provision.sh`
installs. Arch additionally needs `community.general` for its package module, so
there `provision.sh` installs the bundled `ansible` package instead.

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

Each run is appended, ANSI-free, to `~/.local/state/first-login.log` — the
steps, and every ok/warn/error along the way. Relocate it with
`FIRST_LOGIN_LOG=/path` or disable with `FIRST_LOGIN_LOG=`.

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
./test/lint.sh                                  # everything CI's lint job runs
./test/unit.sh                                  # the shipped scripts; no root, one second
sudo ./test/install-check.sh --profile minimal  # install twice, assert changed=0
```

**Run `./test/lint.sh` before you push.** CI runs that same script rather than
its own copy of the commands, so a green run here is a green lint job there. It
installs what it needs into `.venv-lint/` on first use — no root, nothing to
read first — and takes about ten seconds after that.

To have it run itself:

```bash
git config core.hooksPath .githooks
```

That enables a pre-commit hook which lints whenever the commit touches a
`.yml`, `.yaml` or `.sh` file. `git commit --no-verify` skips it.

`install-check.sh` is destructive — run it in a throwaway container, which is
what [CI](.github/workflows/ci.yml) does.

## Layout

| Path | Purpose |
| --- | --- |
| `provision.sh` | Bootstrap: install `ansible-core`, pick a profile, run the playbook |
| `playbooks/<name>.yml` | A profile: a role list and its settings; the user-facing surface |
| `inventory/group_vars/all.yml` | Settings shared by every profile |
| `roles/<name>/` | One installable thing — `tasks/`, and its `files/` beside it |
| `tasks/` | The pre_tasks and post_tasks every profile shares |
| `inventory/local.yml` | The only inventory: this machine, no network |
| `pve/create-container.sh` | Creates and provisions an LXC container; runs on the Proxmox host |
| `test/` | The lint entry point, unit tests and the idempotency check |
| `.githooks/pre-commit` | Opt-in hook that runs `test/lint.sh` before a commit |
| `docs/design.md` | Why it is built this way, and the failure modes |

## Not covered

- **Firewall.** Filtering is left to the hypervisor or the cloud provider.
- **Backups.** Snapshot the container; the app user's home is the only state.

## License

[MIT](LICENSE).
