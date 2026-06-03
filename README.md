# SSH Multisession Resume

Keep your SSH terminal exactly where you left it.

`ssh-multisession-resume` automatically attaches selected interactive SSH
logins to a managed `tmux` session. Disconnect from a laptop, tablet, or phone,
reconnect later, and land back in the same shell with the same running
programs, panes, and scrollback.

`tmux` is preferred. `screen` is used only as a fallback.

```text
Before

  SSH client disconnects
        |
        v
  terminal context is gone

After

  SSH client disconnects
        |
        v
  tmux session keeps running
        |
        v
  reconnect returns to the same work
```

## Quick Start

```bash
yay -S ssh-multisession-resume-git
# or
paru -S ssh-multisession-resume-git
```

No AUR helper:

```bash
git clone https://aur.archlinux.org/ssh-multisession-resume-git.git
cd ssh-multisession-resume-git
makepkg -si
```

Source checkout on any supported Linux distro:

```bash
git clone https://github.com/Bit-Loop/ssh-multisession-resume.git
cd ssh-multisession-resume
./run.sh
```

`./run.sh` installs runtime deps through the detected package manager
(`pacman`, `apt-get`, `dnf`, `yum`, `zypper`, or `apk`), installs the command
under `/usr/local/bin`, and installs global shell hooks for new SSH logins.

Then SSH in. On the first connect from any source IP, a menu asks
whether you want:

```text
[1] single  one persistent session shared across reconnects
[2] multi   fresh session per connect; concurrent slots OK
[3] skip    plain shell; do not auto-attach this source
```

Your choice is saved under `~/.config/ssh-multisession-resume/choices/`
and persists across reboots. To change it later:

```bash
ssh-multisession-resume policy set 192.168.1.5 single
ssh-multisession-resume policy move 192.168.1.5 10.0.0.22
ssh-multisession-resume policy forget 192.168.1.5    # re-prompt next connect
```

To disable the menu entirely for your user:

```bash
ssh-multisession-resume opt-out
```

Verify a managed session inside the SSH window:

```bash
ssh-multisession-resume doctor
```

## How It Works

```text
SSH login on /etc/profile.d/<...>.sh
        |
        v
detect interactive + SSH + not-in-mux + not opted out
        |
        v
load policy for source IP (or prompt menu on first connect)
        |
        v
attach to managed tmux session
        |
        v
your shell keeps running across disconnects
```

Only matched interactive SSH logins are attached. Normal noninteractive
commands like `ssh host uptime`, scp-style commands, shells without a TTY,
and shells already inside `tmux` or `screen` are left alone.

### Single vs Multi

| Mode    | Slot pick                           | Multiple connections from same IP |
|---------|-------------------------------------|------------------------------------|
| single  | always slot 0                       | tmux multi-attach (mirrored view)  |
| multi   | first free slot under per-IP cap    | parallel independent sessions      |
| skip    | none — plain shell                  | n/a                                |

## Session Slots

Multiple SSH logins from the same user and source IP get separate slots.

```text
source IP 192.168.1.50
        |
        +-- slot 0: default login
        +-- slot 1: second live login
        +-- slot 2: third live login
```

Detached slots are reused first. That means a normal reconnect returns to your
existing work instead of creating a new empty terminal.

Managed `tmux` session names look like:

```text
ip-192_168_1_50-0
ip-192_168_1_50-1
```

## Daily Commands

Use `ssh-multisession-resume` after installing from AUR or `./run.sh`.

| Command | Purpose |
| --- | --- |
| `ssh-multisession-resume doctor` | Verify the current SSH login is attached correctly |
| `ssh-multisession-resume status` | Show install and hook status |
| `ssh-multisession-resume sessions` | List managed `tmux` and fallback `screen` sessions |
| `ssh-multisession-resume monitor` | Watch managed sessions refresh in place |
| `ssh-multisession-resume policy show` | List saved per-source choices |
| `ssh-multisession-resume policy move OLD_IP NEW_IP` | Move one saved choice to a new source IP |
| `ssh-multisession-resume opt-out` | Disable the SSH menu for this user |
| `ssh-multisession-resume opt-in` | Re-enable the SSH menu for this user |
| `./run.sh status` | Show source-checkout install state |
| `./run.sh rollback` | Remove source-checkout installed files and global hooks |

The AUR package installs under `/usr/bin`, `/usr/lib`, and `/etc/profile.d`.
The source installer uses `/usr/local/bin`, `/usr/local/lib`, and
`/etc/profile.d`.

## Package Updates

For the AUR `ssh-multisession-resume-git` package, code updates come from the
upstream Git repository through `pkgver()`. AUR helpers may not rebuild VCS
packages during a plain system upgrade unless development-package updates are
enabled.

Common update commands:

```bash
paru -Syu --devel
yay -Syu --devel
```

From a local package checkout:

```bash
git pull
makepkg -Csi
```

When updating AUR metadata after changing `PKGBUILD`, regenerate `.SRCINFO` in
the AUR package repository:

```bash
makepkg --printsrcinfo > .SRCINFO
```

When the packaged source files change, push the GitHub source repository first.
Then regenerate `.SRCINFO` in the AUR package repository so `pkgver()` reflects
the commit users will build.

Package upgrades replace the package-owned command and helper files under
`/usr/bin`, `/usr/lib/ssh-multisession-resume`, and `/etc/profile.d`. They
intentionally do not rewrite user-owned state under
`~/.config/ssh-multisession-resume/`.

After upgrading, check the active install:

```bash
ssh-multisession-resume status
```

For a source checkout, rerun `./run.sh` after pulling updates.

## Build Packages

From a source checkout:

```bash
./run.sh package
```

Artifacts are written to `dist/`:

- Arch: `ssh-multisession-resume-git-...-any.pkg.tar.zst`
- Debian/Ubuntu: `ssh-multisession-resume_..._all.deb`
- Fedora/openSUSE/RHEL-family: `ssh-multisession-resume-...noarch.rpm`
- Alpine: `ssh-multisession-resume-...noarch.apk`

These packages are architecture-independent (`any`, `all`, or `noarch`), so
the same artifacts install on mainstream x86_64 and ARM/aarch64 systems for
their package family.

Build one format:

```bash
./run.sh package:arch
./run.sh package:deb
./run.sh package:rpm
./run.sh package:apk
```

## Test Persistence

Use a command that stays alive:

```bash
sleep 9999
```

Disconnect the SSH client, reconnect, and check that it survived:

```bash
pgrep -af 'sleep 9999'
```

If the setup is active, reconnecting normally should also place you back inside
the same managed terminal session.

## Optional User Service

The optional systemd user service keeps the managed `tmux` server ready across
host boots and user logins:

```bash
ssh-multisession-resume service-install
ssh-multisession-resume service-status
```

This keeps the `tmux` server available. It does not restore programs after a
full reboot; programs survive SSH disconnects, not machine shutdowns.

Remove the service:

```bash
ssh-multisession-resume service-rollback
```

## Rollback

To undo a source-checkout install:

```bash
./run.sh rollback
```

To remove the AUR package, use your package manager. Saved user choices under
`~/.config/ssh-multisession-resume/` are not deleted automatically.

Rollback does not kill unrelated user sessions.

## Tests

From a source checkout:

```bash
./run.sh test          # local smoke suite
./run.sh test:all      # Docker source installs on every supported package manager
./run.sh test:aur      # vanilla Arch container pulls and installs the AUR package
./run.sh package       # Docker-built package artifacts in dist/
```

`test:all` covers Arch, Debian, Ubuntu, Fedora, yum, openSUSE, and Alpine.
Each source-install container runs `./run.sh install`, starts a local `sshd`,
and verifies that two real SSH logins land in the same managed `tmux` session.
`test:aur` does not mount the local checkout; it clones the AUR package in a
clean Arch container and verifies the installed package the same way.

## Files

| Path | Purpose |
| --- | --- |
| `run.sh` | Source-checkout install, rollback, and Docker test entrypoint |
| `ssh-multisession-resume` | Installed user command |
| `client/auto-resume.sh` | Runtime auto-attach guard |
| `client/tmux-auto-resume.conf` | Managed `tmux` defaults |
| `client/screen-auto-resume.screenrc` | Fallback `screen` defaults |
| `server/install.sh` | Legacy SSHD Match-block helper |
| `packaging/build-packages.sh` | Arch/deb/rpm/apk package artifact builder |
| `tests/smoke.sh` | Non-destructive syntax and behavior checks |

## Notes

- Linux/OpenSSH is assumed.
- Exact IPv4/IPv6 addresses and IPv4/IPv6 CIDR ranges are supported. Scoped
  link-local IPv6 addresses such as `fe80::1%eth0` are accepted by the legacy
  SSHD Match helper. It is not limited to Tailscale or `100.x.x.x` addresses.
- Existing legacy `main` sessions are treated as slot `0` so old work remains
  reachable.
- To intentionally end preserved work, exit the shells/programs inside the
  managed session or run `tmux kill-session` for that session.

## X11 and Wayland Forwarding Behavior

If you forward a graphical session over SSH (`ssh -X`/`-Y` for X11,
`waypipe ssh` / `wayvnc` for Wayland), a few quirks are worth knowing
about. None of them are leaks caused by this tool, but the tool's whole
point is that you reconnect to the same session repeatedly, so they
become more visible than usual.

- **New panes get fresh display env; existing panes do not.** On reattach,
  `tmux` refreshes its session env from the attaching client. The pinned
  refresh list in `client/tmux-auto-resume.conf` covers `DISPLAY`,
  `WAYLAND_DISPLAY`, `XAUTHORITY`, `SSH_AUTH_SOCK`, `SSH_AGENT_PID`,
  `SSH_CONNECTION`, and the rest of the tmux >= 3.x defaults. New
  windows or panes opened after reconnecting see the live values.
  Already-running shells keep whatever env they were forked with - a
  Unix limitation, not a tmux bug. Run
  `eval "$(tmux showenv -s DISPLAY WAYLAND_DISPLAY SSH_AUTH_SOCK)"`
  inside an existing pane if you need to refresh it manually.
- **`~/.Xauthority` grows over time.** OpenSSH appends an auth cookie per
  X11-forwarded session and does not remove it on disconnect. Over many
  reconnects the file accumulates stale entries. To clean up safely:
  ```bash
  : > ~/.Xauthority   # truncate, then reconnect to repopulate
  ```
  Prefer `ssh -Y` only when you actually need it.
- **Wayland sockets are managed by the forwarding tool.** `waypipe` and
  similar bridges create their own per-session socket under
  `$XDG_RUNTIME_DIR` and remove it on disconnect, so there's nothing to
  clean up after them. The only thing to refresh is `WAYLAND_DISPLAY` in
  long-lived shells (see above).
- **`screen` fallback does not auto-refresh env.** Unlike `tmux`, `screen`
  has no `update-environment` equivalent. After reconnecting, run inside
  a fresh screen window:
  ```bash
  screen -X setenv DISPLAY "$DISPLAY"
  screen -X setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
  # or just export the vars directly
  ```
- **GUI processes that were running when SSH dropped will stay alive
  inside tmux but hold dead display connections.** Kill and restart them
  after reconnecting; the tool cannot revive the X11/Wayland socket they
  were attached to.

## Tuning Environment Variables

A few env vars affect the auto-resume client hook:

- `SSH_AUTO_RESUME_MAX_SLOTS` (default `64`) - cap on per-IP session slots
  before "no free slot" is returned.
- `SSH_AUTO_RESUME_LOCK_RETRIES` (default `50`) - retry budget on the slot
  lock; each retry sleeps `0.1s`, so the default is a 5s timeout. Raise
  this on heavily loaded hosts where many concurrent SSH connections may
  contend for the same lock.
