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

**The guest layer** is `provision.sh` and the playbooks it runs. It requires
root and systemd, and nothing else. That is what makes this useful to somebody
who has never touched Proxmox.

```
provision.sh             install ansible-core, pick a profile, run the playbook
  ansible.cfg            ansible-core only, no collections
  callback_plugins/      the stdout callback: what a run prints, and what it
                         leaves out
  inventory/local.yml    this machine, connection: local
  inventory/group_vars/  settings shared by every profile — must live beside the
                         inventory, not at the repo root, or Ansible ignores it
  playbooks/<name>.yml   a role list plus settings — the user-facing surface
    tasks/preflight.yml  refuse Alpine, warn on tier 2, read the app user's uid
    roles/<name>/        one installable thing
    tasks/done.yml       what is left for a human to do
```

### Why Ansible, and where it stops helping

This started as a tree of bash: a `setup.sh` that parsed arguments, a `lib/`
that abstracted package managers and file writes, and a role runner that read
`# requires:` headers and resolved a dependency graph. It worked, and it was
about fourteen hundred lines of code that existed only so the interesting parts
could be written.

Ansible removes that layer wholesale. Dependency ordering, "write this file only
if it differs", "install this package unless it is already there", per-task
change reporting, `--check`, `--diff`, `--start-at-task` — all of it is now
somebody else's code, tested by somebody else. Roughly five hundred lines went
away and are not missed.

It is worth being precise about what it did **not** fix, because that is most of
what makes this repo hard:

- npm 12's `allow-scripts` semantics, and the fact that the allowlist has to
  reach `~/.npmrc` rather than a command line
- node-pty falling back to `node-gyp rebuild` on Linux, and failing at runtime
  rather than at install time
- logind asking polkit whether a user may set their own linger
- `t3 service install` exiting 0 on a runtime that cannot boot
- two servers against one `~/.t3`

None of that becomes simpler in YAML. Written as tasks it becomes *harder* to
debug, because a `shell:` task inside a role is something you can only run by
running the playbook. So those pieces stay as scripts the roles ship and call —
see [Scripts, not tasks](#scripts-not-tasks).

### Scripts, not tasks

Four pieces of logic are shipped as executable scripts rather than expressed as
Ansible tasks:

| Script | What it decides |
| --- | --- |
| `roles/keyring/files/verify-keyring.sh` | Is every key in this file one we pinned? |
| `roles/github-ssh/files/github-host-keys.sh` | Fetch, verify and merge GitHub's host keys |
| `roles/t3/files/check-npmrc-allow-scripts.sh` | Does `~/.npmrc` really allow t3's native install scripts? |
| `roles/t3-service/files/check-pinned-runtime.sh` | Can the runtime systemd will boot load node-pty? |

The rule for what belongs here: **if the day you read it is a day something is
broken, it should be runnable on its own.** A key rotation, an unreachable
container, a crash-looping server — in each case you want to run the check
directly, with your own arguments, and read its output. Every one of them takes
its inputs as arguments and prints a real message.

The payoff is that they are unit-testable without root, without a container and
without Ansible. `test/unit.sh` covers all four in about a second, which is more
than the old library layer ever managed for the same logic.

The rule for what does *not* belong here: anything Ansible already reports on
correctly. Installing a package, writing a unit file, creating a directory —
those are tasks, and turning them into a script would throw away change
reporting and `--check` for nothing.

### What a run prints

A full provisioning run is around a hundred tasks, and on a box that is already
provisioned all but a few of them end `ok` — they are conditions being checked,
which is the point of writing them as tasks, but a screen of `ok:` is not
something anyone reads. So the output is filtered down to what actually
happened:

- **Tasks that changed something, and tasks that failed**, exactly as Ansible
  prints them.
- **The debug tasks**, which are the run talking to you on purpose: what
  distribution this is and whether it is tested, and the closing note about the
  OAuth device codes only a human can finish.
- **The play recap**, whose `changed=0` on a second run is the idempotency
  claim this repo makes — and is what `test/install-check.sh` asserts on.

Everything else says nothing. That is `callback_plugins/concise.py`, forty
lines subclassing the in-core `default` callback, plus `display_ok_hosts =
False` in `ansible.cfg`; `provision.sh -- -v` turns the full task-by-task output
back on. The same principle applies to the two scripts: the package manager
installing ansible-core and `pct create` unpacking an image are buffered and
printed only if they exit non-zero (`quietly()` in both scripts).

## Writing a role

A role is one directory under `roles/`, with `tasks/main.yml` and anything it
ships in `files/` beside it.

```yaml
---
- name: Preconditions
  ansible.builtin.include_role:
    name: preflight
  vars:
    preflight_for: my-role
    preflight_commands: [curl]

- name: Install the thing
  ansible.builtin.package:
    name: [ripgrep, fd-find]
    state: present

- name: Configure it
  ansible.builtin.copy:
    src: thing.conf
    dest: /etc/thing.conf
    owner: root
    group: root
    mode: "0644"
```

Add a `meta/main.yml` with a one-line description — that is what
`./provision.sh --list` prints — and then add the role to a profile playbook
with its own tag.

The rules that matter:

- **Declare preconditions with the `preflight` role, not with
  `meta/main.yml` dependencies.** See [--only and tags](#only-and-tags).
- **Report changes honestly.** Every `command:` and `shell:` task needs an
  explicit `changed_when`. If a task runs a vendor's own updater, `false` is the
  right answer and deserves a comment saying why.
- **Name packages per family in `vars/<os_family>.yml`.** `ansible_os_family` is
  `Debian`, `RedHat` or `Archlinux`; branch on that, never on the distribution.
- **Pin third-party signing keys** with the `keyring` role. Fail closed.
- **Ensure `npm_prefix_dirs` yourself** if the role installs into the app user's
  npm prefix. Every component, parents included — see
  [the ownership note](#every-component-of-the-app-users-npm-prefix-is-owned-explicitly).
  Do not assume the `user` role has been re-run since.
- **Run as the app user with `become_user` plus `environment: "{{ app_user_env }}"`,**
  never one without the other. That variable is what carries the PATH, the
  `XDG_RUNTIME_DIR` that makes `systemctl --user` work, and the `npm_config_*`
  overrides described in `inventory/group_vars/all.yml`.

Then add it to `test/unit.sh` if it ships a script with logic worth asserting.

### `--only` and tags

`--only claude` maps to `ansible-playbook --tags claude`, and every role in
every profile carries its own name as a tag. Nothing declares
`meta/main.yml` dependencies, on purpose.

Ansible inserts a role dependency into the play and tags it with its
*dependant's* tags. So if `claude` declared `dependencies: [base, user]`, then
`--tags claude` would run `base` and `user` too — which is precisely what
`--only` exists not to do. It is for repairing one step on a box that is already
provisioned, and re-running the package layer and the account layer every time
would make it useless.

The ordering that dependencies would have encoded lives in the profile playbook
instead, which lists roles in the order they must run. With ten roles that is
one readable list rather than a graph to resolve, and inserting a step is one
line. What is lost — a role stating what it needs — comes back as the
`preflight` role, which fails with the command to run rather than silently
running it.

## Writing a profile

A profile is a playbook. It is the whole user-facing surface: to build a
different kind of box, copy one and change the role list.

```yaml
---
# description: What this box is for
- name: What this box is for
  hosts: all
  become: true
  gather_facts: true

  vars:
    node_major: 22

  pre_tasks:
    - ansible.builtin.import_tasks: ../tasks/preflight.yml

  roles:
    - {role: base, tags: [base]}
    - {role: user, tags: [user]}
    - {role: node, tags: [node]}

  post_tasks:
    - ansible.builtin.import_tasks: ../tasks/done.yml
```

The `# description:` comment on the second line is what `--list` shows; nothing
else parses the file.

Settings go under `vars:`, which sits between `inventory/group_vars/all.yml` and `-e` in
Ansible's precedence order. That is the same three-level order the bash version
maintained by hand with `: "${VAR:=...}"`, and here it needs no discipline to
get right.

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

Two Arch-specific things worth knowing, both of which cost a CI run.

`ansible-core` ships the `apt` and `dnf` modules but not `pacman`, which lives
in `community.general`. So `provision.sh` installs `ansible-core` everywhere
except Arch, where it installs the bundled `ansible` package instead. Adding a
collection dependency for tier 1 would mean a galaxy install on every fresh
container; paying it only where it is needed keeps the common path to one
distribution package.

That dependency is deliberately confined to *runtime on Arch*. No task in any
role names a collection module, and it is worth knowing why: **Ansible resolves
every module in a task list when it loads the play, including tasks whose `when`
is false.** A single `community.general.*` task in a role every profile runs
therefore makes that collection a hard dependency on Debian, Ubuntu and Fedora
as well — which is how Fedora's CI job broke on an Arch-only task. When a role
needs something only a collection expresses, it uses `ansible.builtin.command`
and a `changed_when` instead.

And **Arch does not support partial upgrades.** Refreshing the index without
also upgrading (`pacman -Sy`) leaves packages built against library versions
that are no longer installed, and asks the mirror for files it has already
replaced — which surfaces as a 404 on some unrelated dependency, not as
anything that names the real cause. `ansible.builtin.package` runs a plain
`pacman -S`, so the `base` role runs `pacman -Syu` first. That is the Arch
counterpart of the apt cache refresh, not an extra step: on Arch the two cannot
be separated.

## Design decisions

### Non-root by design

The app user runs with **no sudo**. Everything system-level is done by
the playbook as root, so an agent running as this user cannot damage the OS
install; the blast radius is one home directory, and every repo there has a
remote. Nothing needs root anyway: user systemd units, outbound-only
networking, ports above 1024, and `npm i -g` into `~/.local`.

There is no sudo on the box at all, which is also why `ansible.cfg` sets
`become_method = su`. Ansible's default is sudo, and a fresh Debian or Ubuntu
LXC does not ship it, so the default fails at the first task that runs as the
app user — an error (`Premature end of stream waiting for become success`) that
names neither sudo nor the task's real problem. `su` is part of util-linux and
therefore always present, and root becoming a named user needs no password.
`tasks/preflight.yml` checks for it before any role runs, and the base role
installs `acl`, which is what Ansible uses to hand a module file to an
unprivileged user.

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

### Every component of the app user's npm prefix is owned explicitly

`npm_prefix_dirs` in `inventory/group_vars/all.yml` lists `~/.local` itself, not just
`~/.local/bin`, `lib` and `share`. That looks redundant and is not.

The bash version created these with `install -d -o devuser ~/.local/bin`, which
applies the ownership to the **last** component only and leaves the `~/.local`
it created on the way `root:root 0755`. Nothing notices while programs only
write *inside* the leaf — npm never creates anything directly in `~/.local` —
until one tries to add a sibling. Claude Code's installer does, and died with
`EACCES: permission denied, mkdir '/home/devuser/.local/share'`.

Ansible's `file:` module has the same property: `state: directory` with an owner
sets it on the path you named, and any parents it creates along the way get
whatever the umask says. Listing the parents is the fix, and it is a better one
than the `user_dir` helper it replaced, because the list is visible in one place
rather than implied by a function. `file:` also chowns directories that already
exist, so a re-run repairs a container provisioned before this was understood.

Several roles ensure the list themselves rather than trusting that `user` has
been re-run since — `--only t3` on an already-provisioned box has to work on
its own.

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

Packages with native code need their install scripts to build. `npm_allow_scripts`
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
./provision.sh --only claude -e claude_model=claude-sonnet-5 -e claude_effort_level=high
```

**Each key is written only when it is absent.** `/model` and `/effort` inside a
session write back to this same file, so anything already there is a choice
somebody made in the app, and re-running the playbook must not silently undo it —
provisioning sets a *starting point*, it does not own the file. To reset a
container to the profile default, delete the key (or the whole file) and re-run
`./provision.sh --only claude`.

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
- **Forcing the value on every run.** Turns the habit of re-provisioning
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
The `t3` role refuses to run if `npm_allow_scripts` does not list what it needs,
and then refuses again if the `~/.npmrc` on disk does not — two different
failures, checked separately, because a `--only t3` run that skips `node` never
revisits the file. The second check is
`roles/t3/files/check-npmrc-allow-scripts.sh`, which you can run by hand.

`t3 service install` (and every nightly `t3 service update`) also runs
`loginctl enable-linger` **as the app user**. logind does not take that call on
faith: it asks polkit whether the session user may set their own linger. A box
with no polkit daemon answers "denied", the step fails with exit 1, and
`t3 service install` aborts before the unit is written.

Linger for the app user is already enabled by the `user` role (as root, before
this role runs), so that self-call has nothing left to do — the only question
is whether logind will authorize it. Relying on that is fragile: the polkit
action is `org.freedesktop.login1.set-self-linger`, which logind evaluates
against the caller's *session*, and `runuser` does not create one. Installing
the polkit daemon did not reliably fix it on a real container.

So the `t3-service` role makes the step deterministic by installing a
user-scoped `loginctl` shim into the app user's PATH —
`$NPM_PREFIX/bin/loginctl`, which is first in the PATH the roles give that user.
For exactly `loginctl enable-linger` with no further arguments (t3's
invocation) it answers from `/var/lib/systemd/linger/<user>`: that file is what
logind itself keys linger off, and reading it needs neither a session nor
polkit. Marker present, exit 0. **Marker absent, forward to the real binary** —
the shim reports what is true rather than what is convenient, because faking
success there buys a clean `t3 service install` and pays for it with a
`t3code.service` that systemd kills at logout. Everything else, including
`loginctl enable-linger <other user>`, is forwarded untouched. The role
also installs the polkit daemon (`polkitd` on Debian, `polkit` on RHEL/Arch)
so the real command still works when something calls it by absolute path or a
human runs it by hand. Both are ensured *here* rather than in `base`, because a
role must not depend on another role having been re-run, so `./provision.sh
--only t3-service` on an already-provisioned box has to work on its own.

### What this repo does *not* hand-roll, and why the split is there

It is worth being explicit, because "install the service from a provisioning
role" reads like the kind of thing that should be left to the tool:

- **The unit, the pinned runtime and the update protocol are t3's.** The role
  shells out to `t3 service install` and inspects the result. It never writes
  `t3code.service` itself. Everything in the list above is why.
- **What the role adds is the environment `t3 service install` assumes.** The
  `allow-scripts` line so the pinned runtime's `npm install --prefix` can build
  `node-pty`; linger that resolves without a login session; a compiler and
  python3 for node-gyp. Those are the provisioner's job by definition — t3
  cannot install its own build toolchain.
- **The rest of the role is verification, not installation.** `t3 service
  install` exits 0 once the unit is written and the runtime is staged, and both
  can be perfect over a server that dies on its first start. So the role checks
  the two things the installer does not: that the pinned runtime can load
  `node-pty`, and that the server behind the unit reported itself listening
  (a live `pid` in `~/.t3/userdata/server-runtime.json`). Provisioning that
  reports success for a crash-looping unit is worse than provisioning that
  fails, because the next thing to run is an interactive OAuth flow.

The one part with a real alternative is the nightly timer, which duplicates
what the app's own update button does. It exists because that button is the
*only* other trigger — see below.

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
t3 connect publish                   # push notifications / Live Activities
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
- **`t3 connect publish` is not part of linking.** Agent activity is not
  published until it is asked for, so without it a linked box reaches the phone
  but never notifies it. Despite the *"Toggle"* in its help text it writes
  enabled unless `--disable` is passed, so it is safe to re-run; `t3 connect
  status` reports the state as `Publish agent activity`.
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

### `Environment link: pending server startup` right after `first-login`

The server provisions the link asynchronously, and on a healthy box it lands
20–30s after the restart. When it does not, the important thing to know is that
**t3 says nothing until it has finished trying**. The reconcile is wrapped in

```
Effect.retry({ while: <not 400/401/409>,
               schedule: exponential(1s) capped at 30s, upTo 10 minutes })
```

and only then logs `T3 Connect desired link reconciled on startup` or
`Failed to reconcile T3 Connect desired link on startup`. Every transport
failure and every other HTTP status — a relay **403 included**, which is
wrapped as `EnvironmentHttpInternalServerError` — stays in that loop for the
full ten minutes. Only the three refusal statuses short-circuit.

So an empty log two minutes in means nothing at all, which is why `first-login`
now waits out t3's own budget (`LINK_WAIT_SECONDS`, default 660) instead of
guessing at two. It still returns the moment either line appears.

If ten minutes really do pass with neither line written, the reconcile never
ran: the loop returns without logging when the desired-link flag is unset, and
`t3 connect link` is what sets it — at the *end*, after the browser step.

```bash
t3 connect status                    # 'Exposure: enabled' is that flag
t3 connect link --headless           # if it says disabled, do it again
systemctl --user restart t3code.service
grep -i 'desired link' ~/.t3/userdata/logs/boot-service.log | tail
```

A logged failure with `(403 ` in it is the relay declining, not a transport
problem — release the stale environment at https://app.t3.codes and restart.
Nothing below the link layer has run at that point: no link means no managed
tunnel and no relay client, so cloudflared is not the suspect.

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

`./provision.sh --only t3-service` does the same thing. Either server works fine
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
[the ownership note](#every-component-of-the-app-users-npm-prefix-is-owned-explicitly).
Re-run `./provision.sh --only user` to fix the ownership, then re-run the role that
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
