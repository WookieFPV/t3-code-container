# Design notes

Why this is built the way it is. The [README](../README.md) covers how to use
it; this file is the reasoning, and the failure modes worth knowing about.

## Contents

- [Architecture](#architecture)
- [Writing a role](#writing-a-role)
- [Writing a profile](#writing-a-profile)
- [Distribution support](#distribution-support)
- [Design decisions](#design-decisions)
- [The t3 profile](#the-t3-profile)
- [Troubleshooting](#troubleshooting)

## Architecture

Two layers, with a hard boundary between them.

**The host layer** is `pve/create-container.sh`, and it is the only file that
knows Proxmox exists. It creates the container, waits for DHCP, pushes the
working tree in and runs the guest layer. Replacing it with Terraform, an Incus
command or a cloud VPS changes nothing else.

**The guest layer** is `setup.sh` and everything it runs. It requires root and
systemd, and nothing else. That is what makes this useful to somebody who has
never touched Proxmox.

```
setup.sh                 parse arguments, pick a profile, resolve the plan
  lib/common.sh          sourced by setup.sh and by every role
    lib/log.sh           header/log/ok/warn/skip/die
    lib/os.sh            distribution detection and support tiers
    lib/pkg.sh           package manager abstraction and name mapping
    lib/sys.sh           accounts, linger, timezone, locale
    lib/fs.sh            install_file, ensure_line, user_dir
    lib/keys.sh          pinned signing-key verification
    lib/roles.sh         role discovery, metadata, dependency ordering
  profiles/<name>.sh     a role list plus settings — the user-facing surface
  roles/<name>/install.sh  one installable thing
```

Each role runs as a **separate bash process**. A subshell would be cheaper, but
a separate process is what makes a role unable to leak state into the next one,
so `--only claude` behaves exactly as the `claude` step of a full run does.
Configuration reaches roles by having each of them source `lib/common.sh`,
which re-reads the same profile — not by exporting a pile of variables.

### Why roles replaced numbered modules

The first version ran `modules/*.sh` in filename order: `05-user.sh`,
`10-apt.sh`, `20-node.sh`. That encodes ordering in the filename, which works
exactly until two people add a module — everyone picks 25, and inserting a step
means renumbering its neighbours. It also made every ordering constraint
implicit: `05-user.sh` had to install `dbus` and `libpam-systemd` itself,
with a comment explaining that it ran *before* the package module, because the
dependency was real but pointed the wrong way.

Roles declare what they need and the order is derived, so `base` owns every
system package and `user` simply requires it.

## Writing a role

A role is one directory with one executable `install.sh`, and anything it ships
in `files/` beside it.

```bash
#!/usr/bin/env bash
# requires: base user
# description: Whatever this installs, one line, lower case
set -euo pipefail
source "$REPO_DIR/lib/common.sh"

: "${MY_SETTING:=default}"    # `:=`, so a profile or the environment can win

pkg_install ripgrep fd-find
install_file "$ROLE_DIR/files/thing.conf" /etc/thing.conf 0644
```

Metadata lives in the comment header, so listing roles never executes them.
Parsing stops at the first line that is neither a comment nor blank, which is
why a `# description:` inside the body cannot change the plan.

Two variables are provided: `REPO_DIR` (the repo root) and `ROLE_DIR` (this
role's directory — use it for `files/`, never a relative path).

The rules that matter:

- **Converge, do not just install.** Every run must reach the same state, and a
  second run must write nothing. Use `pkg_install`, `install_file` and
  `ensure_line`, which all no-op when there is nothing to do. `test/install-check.sh`
  asserts this and CI runs it.
- **Never call `apt-get`, `dpkg` or `dnf` directly.** Use `pkg_install`, and add
  a mapping to `pkg_map` if the package is spelled differently somewhere.
- **Use `user_dir` for anything under the app user's home**, never
  `install -d -o`. See [the ownership note](#every-directory-under-the-app-users-home-is-created-with-user_dir).
- **Pin third-party signing keys** with `fetch_keyring`. Fail closed.
- **Branch on `OS_FAMILY`, never on `OS_ID`.**
- **Do not stream a command that is verbose on success.** Package managers and
  installers are loud about things that are not errors; wrap them in
  `run_quiet "what failed" <cmd> ...` (see `lib/log.sh`). Success prints
  nothing, failure replays the captured log and dies, and the role prints its
  own `log`/`ok` summary line either way.

Then add it to a profile, and to `test/unit.sh` if it has logic worth asserting.

## Writing a profile

A profile is a role list and some settings. It is the whole user-facing surface:
to build a different kind of box, copy one and change the list.

```bash
PROFILE_DESCRIPTION="What this box is for"
ROLES=(base user node)
: "${NODE_MAJOR:=22}"
```

Settings are assigned with `: "${VAR:=...}"`, never `VAR=...`, so precedence
stays: **defaults in `lib/common.sh` < profile < environment**. Assigning
directly would silently beat `NODE_MAJOR=22 ./setup.sh`, which is the one thing
someone reading the usage text expects to work.

## Distribution support

| Tier | Distributions | What it means |
| --- | --- | --- |
| 1 | Debian 12/13, Ubuntu 24.04 | CI installs and re-runs on every push |
| 2 | Fedora, RHEL-like, Arch | Written to work, nothing tests it, warns at startup |
| — | Alpine | Refused with an explanation |

Alpine is detected only so the error is useful. Every long-running part of this
setup is a systemd **user** unit — the app user's linger session, the server,
the update timer — and Alpine has no systemd. Supporting it means rewriting
those as OpenRC services running as root, which is a different design, not a
port.

Tier 2 prints a warning naming itself. Claiming a distribution nothing tests is
worse than not claiming it.

## Design decisions

### Non-root by design

The app user runs with **no sudo**. Everything system-level is done by
`setup.sh` as root, so an agent running as this user cannot damage the OS
install; the blast radius is one home directory, and every repo there has a
remote. Nothing needs root anyway: user systemd units, outbound-only
networking, ports above 1024, and `npm i -g` into `~/.local`.

### Third-party signing keys are pinned

Vendor repositories are verified against fingerprints hard-coded in the role
that adds them, checked *before* the key is installed and re-checked on every
run. It fails closed: any key that is not pinned stops the run rather than
being trusted.

This is the main thing this project does that the popular Proxmox helper-script
collections do not — they download vendor keys over TLS and trust whatever
arrives. Pinning the key is sufficient; the package manager then verifies every
package against it, so per-file checksums would add nothing.

If a vendor rotates keys you get an `UNPINNED signing key <fpr>` error. Confirm
the new fingerprint in the vendor's own docs (linked in the role), then add it
to the array. GitHub's older key expires **2026-09-05**; its replacement is
already pinned, so that rollover needs no action.

### GitHub's SSH host keys are pinned, not accepted at the prompt

`roles/github-ssh` fetches them from `api.github.com/meta` and checks each one
against fingerprints pinned in the role, failing closed on anything it does not
recognise. The keys come from the API so they are current; the pins are what
make trusting the API safe. Without this, the first `git clone` over SSH asks
*"Are you sure you want to continue connecting?"*, and nobody has ever verified
that fingerprint by hand.

### Every directory under the app user's home is created with `user_dir`

Not with `install -d -o`: that applies the ownership to the **last** component
only, so `install -d -o devuser ~/.local/bin` leaves `~/.local` itself
`root:root 0755`. Nothing notices while programs only write *inside* the leaf —
npm never creates anything directly in `~/.local` — until one tries to add a
sibling. Claude Code's installer does, and died with
`EACCES: permission denied, mkdir '/home/devuser/.local/share'`. `user_dir`
owns every component of the path, and chowns existing ones, so re-running
`setup.sh` repairs a container provisioned before this was fixed.

### There is deliberately no fake `xdg-open`

`gh` and `t3` both log a failure when they try to open a browser, which looks
like something to fix with a shim that prints the URL instead. Don't:
`t3 connect`'s callback is `http://127.0.0.1:<port>`, reachable only from
inside the container, so a shim that *appears* to succeed would send you to
open a URL that cannot work and hide the headless-mode option that does. The
error line is noise; both tools print the URL and the one-time code right above
it.

### `gh` stores its token in plain text

No credential store (gnome-keyring or similar) exists on a headless container,
so `gh auth login` warns and falls back to `~/.config/gh/hosts.yml`, mode 0600.
That is the same trust level as `~/.ssh/id_ed25519` sitting next to it, on a box
where the whole point is that the app user can reach GitHub unattended — but it
is worth knowing it is there.

### npm's major version is pinned, and `allow-scripts` is required

Distribution packages ship whatever npm Node bundles (11.x for Node 24). npm 12
**blocks** install-time lifecycle scripts where npm 11 only warns, and these
roles are written against the blocking behaviour — so `roles/node` installs npm
12 into the user prefix (never `/usr`). Override with `NPM_MAJOR`.

Packages with native code need their install scripts to build. `NPM_ALLOW_SCRIPTS`
is a profile setting written into the app user's `~/.npmrc`, and it has to live
there rather than on a command line, because the installs that matter most are
ones nobody types: a tool's own service installer or self-updater runs
`npm install --prefix <staging> …`, and npm 12 rejects `--allow-scripts` outright
for a project-scoped install like that — *"Add the entries to the allowScripts
field in package.json, or to .npmrc, instead"*.

That single `.npmrc` source applies to the global installs this repo runs
itself as well: the t3 role and the nightly updater deliberately do **not** pass
`--allow-scripts` on their own `npm install -g` command lines. npm 12 reads the
same `~/.npmrc` entries there, so a package allowed for the pinned runtime build
is allowed everywhere, and a profile cannot drift into two different lists.

Two consequences. `--strict-allow-scripts` stats **both** halves of the npm
prefix rather than creating them on demand, so `~/.local/bin` *and*
`~/.local/lib` must exist before the install or npm dies with `ENOENT` (the
`user` role creates both). And `node-pty` ships prebuilt binaries for macOS and
Windows only, so on Linux it always falls back to `node-gyp rebuild` — which is
why a compiler **and `python3`** are in the base package list; node-gyp refuses
to run without a Python interpreter.

---

## The t3 profile

Everything below is specific to `profiles/t3.sh`. Skip it if you are using
another profile.

### Claude's model and effort are seeded, not enforced

A fresh container would otherwise start Claude on whatever the **account**
default is. That is a reasonable product default and the wrong one for this
box, which exists to run long agent sessions against real repos — so
`roles/claude` writes `model` and `effortLevel` into
`/home/<user>/.claude/settings.json` (user scope, so it applies in every repo,
including one cloned an hour from now).

The values live in the profile and are overridable from the environment:

```bash
CLAUDE_MODEL=claude-sonnet-5 CLAUDE_EFFORT_LEVEL=high ./setup.sh --only claude
```

**Each key is written only when it is absent.** `/model` and `/effort` inside a
session write back to this same file, so anything already there is a choice
somebody made in the app, and re-running `setup.sh` must not silently undo it —
provisioning sets a *starting point*, it does not own the file. To reset a
container to the profile default, delete the key (or the whole file) and re-run
`./setup.sh --only claude`.

The role leaves the account default alone when both settings are empty, which is
what every profile other than `t3` does.

Three alternatives were considered and rejected:

- **Prompting during `first-login`.** The interactive path already exists and is
  better than anything we would write: `/model` in a live session lists exactly
  what the logged-in account can reach and persists the answer. A prompt at
  first login asks someone to type a model ID before they have seen that list,
  once, on the one day they are least equipped to answer.
- **Documentation only.** A default that must be re-applied by hand on every new
  container is not a default; it is a step to forget.
- **Forcing the value on every run.** Turns the habit of re-running `setup.sh`
  into a way to lose a deliberate `/model` switch.

Model IDs age faster than anything else here. A name the account cannot reach
falls back to the account default rather than failing loudly, so after changing
it, confirm with `/model` in a session — not by re-reading the file.

### The server runs under t3's own unit

`roles/t3-service` calls `t3 service install`, which writes
`~/.config/systemd/user/t3code.service`. This repo used to ship its own
`t3.service`; it does not any more, and the role removes a leftover one. Only
one may run in any case — they share `~/.t3`, one database and one secret store
and one tunnel, so two is a broken environment rather than a redundant one.

t3's unit is better than anything worth hand-rolling here, and better in ways
that compound:

- It installs each release into `~/.t3/runtime/versions/<version>` through a
  staging directory, a validation step, and a sentinel written only after npm
  exits 0, then publishes it with an atomic rename. systemd points at that
  pinned copy, so the server it boots is never "whatever state the global npm
  prefix happens to be in".
- Its launcher carries an update protocol the app drives: snapshot SQLite, start
  the new version on trial, commit or roll the migration back. A hand-rolled
  unit gets `npm i -g` and a blind restart.
- It already sets `OOMPolicy=continue` (agent tool calls are children in this
  cgroup, and systemd's default stops the whole unit — a stop `Restart=` does
  not cover — when the kernel kills one greedy child), `KillMode=mixed`, and
  `Restart=always`.
- It tracks t3's own changes. A unit of ours tracks them only when someone
  remembers to look.

The one thing it needs from us is the `allow-scripts` line in `~/.npmrc`; left
alone, `node-pty` never runs `node-gyp rebuild` and the pinned runtime is a t3
with no working PTY. Its validation is `node <entry> --version`, which does not
load node-pty and so passes, and you find out when a terminal fails at runtime.
The `t3` role refuses to run if `NPM_ALLOW_SCRIPTS` does not list what it needs.

`t3 service install` (and every nightly `t3 service update`) also runs
`loginctl enable-linger` **as the app user**. logind does not take that call on
faith: it asks polkit whether the session user may set their own linger. A box
with no polkit daemon answers "denied", the step fails with exit 1, and
`t3 service install` aborts before the unit is written.

Linger for the app user is already enabled by the `user` role (as root, before
this role runs), so that self-call has nothing left to do — the only question
is whether logind will authorize it. Relying on that is fragile: on a real
container, even installing the polkit daemon did not always make the
authorization succeed. So the `t3-service` role makes the step deterministic by
installing a user-scoped `loginctl` shim into the app user's PATH —
`$NPM_PREFIX/bin/loginctl`, which is first in the PATH the roles give that user
— that exits 0 for exactly `loginctl enable-linger` with no further arguments
(t3's invocation) and forwards everything else to `/usr/bin/loginctl`. The role
also installs the polkit daemon (`polkitd` on Debian, `polkit` on RHEL/Arch)
so the real command still works when something calls it by absolute path or a
human runs it by hand. Both are ensured *here* rather than in `base`, because a
role must not depend on another role having been re-run, so `./setup.sh --only
t3-service` on an already-provisioned box has to work on its own.

### Nightly updates

t3's self-update is not automatic — `serverUpdateServer` is a WebSocket method
the app calls, so the box updates when someone taps a button and never
otherwise. `t3-update.timer` fires at 04:00 (`Persistent=true`, so a missed run
catches up after boot), installs the latest CLI, and touches the service **only
if the version changed** — a restart kills the tunnel and any live sessions. If
`npm install` fails, the old working version keeps running. The real work goes
to `t3 service update`, so the staging-and-sentinel install is used rather than
bypassed.

Two guards, because this runs unattended and a bad night is only noticed the
next morning:

- **The new binary must run before we hand it the update.** npm reporting a new
  version only means it rewrote package metadata; an install killed partway
  through leaves a tree that looks right and dies on exec — and `t3 service
  update` is about to be run *with that binary*. `t3 --version` has to succeed
  first, and until it does the server keeps serving from its old pinned runtime.
- **The database is snapshotted first**, to `~/.t3/userdata/pre-update/`, with
  the version it belonged to. The service is stopped before the copy: a live
  SQLite file races its WAL and the copy can come out unusable, and the update
  is downtime either way. One generation is kept, overwritten nightly.

### First login, by hand

`first-login` does this for you, re-runnably. If you would rather not:

```bash
gh auth login --git-protocol ssh --web
gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(hostname -s)"
git config --global user.name  "..."
git config --global user.email "..."
t3 connect link --headless           # answer y to the relay client prompt
systemctl --user restart t3code.service
t3 connect status                    # Environment link: provisioned
claude
```

Two notes the script would otherwise give you:

- **Answer `y` to the relay client (cloudflared) prompt.** It defaults to
  **no**, and nothing else installs the relay client — without it the tunnel can
  never come up, however healthy `t3 connect status` looks.
- **`--headless` matters.** It is only auto-detected inside an SSH session, and
  `machinectl shell` is not SSH; without it the CLI waits on a
  `http://127.0.0.1:<port>` OAuth callback, which resolves only inside the
  container, for a browser this box does not have.
- **`connect link`, not bare `t3 connect`.** The latter ends by offering to run
  T3 Code in the background, which `roles/t3-service` already set up. A second
  server unit against one `~/.t3` is
  [the failure mode below](#two-servers-one-environment).

### Checking it worked

```bash
systemctl --user is-active t3code.service      # active
t3 service status                              # installed · t3@<version>
systemctl --user list-timers t3-update.timer   # next run 04:00 local
```

Those only prove the unit is up. Three more say whether the **app** can reach
it, and they are the ones worth running:

```bash
# 1. Exactly one server. A second one means the app will fail — see below.
systemctl --user list-units --all 't3*.service'   # t3code.service only
pgrep -af 'service-launcher|t3 serve'             # launcher + its child

# 2. The server is answering locally. Read the origin rather than assuming 3773.
curl -fsS "$(jq -r .origin ~/.t3/userdata/server-runtime.json)/.well-known/t3/environment"

# 3. The tunnel actually registered with the relay. This is the only real
#    check — cloudflared is a child of the server, so its progress is in the
#    server's log.
grep -E 'Relay client (process started|tunnel connection registered|exited)' \
    ~/.t3/userdata/logs/boot-service.log | tail
```

You want `Relay client tunnel connection registered`. `process started; waiting
for tunnel connection` with nothing after it means cloudflared came up but never
reached the relay; `Relay client exited; restarting` in a loop means it is being
rejected — usually because a second connector holds the same tunnel.

**t3code.service logs to a file, not the journal.** Its unit sets
`StandardOutput=append:~/.t3/userdata/logs/boot-service.log`, so
`journalctl --user -u t3code.service` shows only systemd's own start/stop lines
and `tail -f` on that file is the equivalent of `journalctl -f`. Nothing rotates
it. It is quiet at `Info`, but on a box left running for months it is worth a
`logrotate` entry or an occasional `: > ~/.t3/userdata/logs/boot-service.log`.

**`t3 connect status` is not a tunnel check**, despite reading like one. Its own
help text is *"Show persisted T3 Connect and relay client state"*: every line
comes from files under `~/.t3`, so the output is byte-identical whether the
server is running or has never started. `Environment link: provisioned` means
"a server linked this environment at some point", not "the tunnel is up now".

---

## Troubleshooting

### Two servers, one environment

**The app can't connect, but every local check passes.** `is-active` says
`active`, `t3 connect status` says exposure enabled and environment link
provisioned, `server-runtime.json` says port 3773 — and the app still can't
reach the box. Almost always: **two servers are running.**

Two ways to get there. Older versions of this repo shipped a hand-rolled
`t3.service`, and bare `t3 connect` ends by asking *"Run T3 Code in the
background whenever this machine boots?"* with the default set to **yes** — so
pressing Enter added `t3code.service` next to it. Either way both processes
serve the same `~/.t3`: one SQLite database, one secret store and one
`server-runtime.json` between two writers, and **two cloudflared connectors
registered for the same tunnel**. The relay hands the app whichever connector it
picks, and that one fronts the wrong process.

Nothing in the obvious checklist catches it: `is-active` names one unit at a
time, `t3 connect status` reads files rather than live state, and
`server-runtime.json` is simply whatever the last server to start wrote there.

```bash
systemctl --user list-units --all 't3*.service'   # anything besides t3code.service?
ls ~/.config/systemd/user/                        # a leftover t3.service?
pgrep -af 'service-launcher|t3 serve'             # two servers = two process trees

# fix: one server, and it is t3code.service
systemctl --user disable --now t3.service
rm -f ~/.config/systemd/user/t3.service
systemctl --user daemon-reload
systemctl --user restart t3code.service
```

`./setup.sh --only t3-service` does the same thing. Either server works fine
**alone**; the failure is entirely in running two.

### Rolling back a bad update

`t3-nightly-update.sh` leaves one generation behind in
`~/.t3/userdata/pre-update/` — the database as it was, plus the version that
wrote it.

```bash
cat ~/.t3/userdata/pre-update/version        # the version to reinstall

systemctl --user stop t3code.service
npm install -g "t3@$(cat ~/.t3/userdata/pre-update/version)" \
    --strict-allow-scripts
t3 service update                            # repoint the unit at that version
systemctl --user stop t3code.service         # `service update` starts it again
cp ~/.t3/userdata/pre-update/state.sqlite ~/.t3/userdata/state.sqlite
rm -f ~/.t3/userdata/state.sqlite-wal ~/.t3/userdata/state.sqlite-shm
systemctl --user start t3code.service
```

`t3 service update` is what repoints the unit at the older pinned runtime —
reinstalling the global CLI alone does not move the server, which runs from
`~/.t3/runtime/versions/<version>`. Restore the database *after* it, and drop
the stale `-wal`/`-shm`: they belong to the database you just replaced, and
SQLite will otherwise try to replay them onto it.

The next nightly run overwrites the snapshot, so do this before 04:00 or copy it
aside first.

### `systemctl --user` says "Failed to connect to bus"

The single most common trap. `su - devuser` does **not** create a systemd login
session, so `XDG_RUNTIME_DIR` is unset and there is no user bus.

```bash
machinectl shell devuser@       # proper login session

# fallback if machinectl is unavailable — works as long as linger is on,
# because the user manager is already running and owns the bus socket:
su - devuser
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

### `/run/user/UID` never appears

In an LXC container this is almost always the missing **nesting** feature. In
Proxmox: *Container → Options → Features → Nesting*, then reboot the container.
`pve/create-container.sh` sets it for you.

On a very minimal image, also check `dbus` and the systemd PAM module are
installed — logind cannot open a user session without them. The `base` role
installs both.

### `EACCES: permission denied, mkdir '/home/devuser/.local/...'`

A directory in the app user's home is owned by root — see
[the `user_dir` note](#every-directory-under-the-app-users-home-is-created-with-user_dir).
Re-run `./setup.sh --only user` to fix the ownership, then re-run the role that
failed.

```bash
ls -ld /home/devuser/.local /home/devuser/.local/*
```

### `t3 serve` won't bind / not reachable from the LAN

It binds **loopback only** — access goes through the cloudflared tunnel the
server spawns once `t3 connect link` has authorized the environment, so you do
not need LAN exposure. It is **3773 in normal operation**, and only falls back
to a random port if something already holds 3773 — typically a second
`t3 serve` started by hand while the service is running. Don't assume it, read
it:

```bash
cat ~/.t3/userdata/server-runtime.json    # authoritative: pid, port, origin
```

There is no `t3 serve` command line to edit any more: `t3code.service` runs the
launcher, which starts the server itself. Pin the port with `T3CODE_PORT=<port>`
in the unit's `[Service]` section — but note the unit is generated, so
`t3 service update` rewrites it. Don't bind `--host <ip>` at all: the container
gets its IP by DHCP, and binding an address the box does not currently own fails
with `EADDRNOTAVAIL`.

### A brand-new LXC container has no network at all

Nearly always host-side config, which is why nothing inside the container
records the fix. Work down this ladder — the first failing rung locates the
problem:

```bash
ip -br link                 # 1. is eth0 there, and UP?
ip -4 -br addr              # 2. did it get an address?
ping -c1 <gateway>          # 3. gateway reachable?
ping -c1 1.1.1.1            # 4. off-subnet routing?
getent hosts deb.debian.org # 5. DNS?
```

1. **No `eth0`** → no NIC attached. On the host, `pct config <ID>` should show
   `net0: name=eth0,bridge=vmbr0,ip=dhcp,type=veth`.
2. **`eth0` present but DOWN, no address** → **the usual cause: `net0` has no
   `ip=` setting.** Proxmox attaches the veth but never configures an address,
   so the container gets no `eth0` stanza, no route, and `ping` fails with
   "Network is unreachable". Add it, keeping the rest of the line unchanged:

   ```bash
   pct set <ID> -net0 name=eth0,bridge=vmbr0,firewall=1,hwaddr=<MAC>,type=veth,ip=dhcp
   pct reboot <ID>
   ```
3. **UP but no address** → DHCP is not being answered: wrong `bridge=`, a VLAN
   tag with no DHCP server, or PVE's per-NIC firewall enabled with no rules.
4. **Address but no gateway** → wrong subnet or VLAN.
5. **IPs work, names don't** → DNS only. Use the LAN resolver, not `8.8.8.8`,
   which cannot resolve local names:

   ```bash
   pct set <ID> --nameserver <lan-resolver> --searchdomain <lan-domain>
   ```

   Inside the container, `/etc/resolv.conf` is PVE-generated; editing it there
   will not stick.

**Use DHCP, not a static IP.** Routers generally register DHCP clients in local
DNS, so the container keeps a stable *name* even when its address changes — and
you avoid picking an address that collides with the DHCP pool. For a fixed
address, add a DHCP reservation on the router keyed to the container's MAC
rather than configuring a static IP in Proxmox.
