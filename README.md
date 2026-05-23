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

## Quick Start (AUR package)

```bash
pacman -S ssh-multisession-resume-git    # or yay / paru
```

Then just SSH in. On the first connect from any source IP, a menu asks
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

## Source-checkout install

If you're running from a clone instead of the AUR package, install the
per-user shell hook manually:

```bash
git clone https://github.com/Bit-Loop/ssh-multisession-resume.git
cd ssh-multisession-resume
./ssh-multisession-resume apply
```

The legacy `apply` flow patches `~/.bash_profile`/`.zshrc` and (with
sudo) adds an `sshd_config` Match block for ClientAlive tuning. Both
are *optional* with the new system-wide profile.d hook.

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

Use `ssh-multisession-resume` after installing the package. Use
`./ssh-multisession-resume` only when running from a source checkout.

| Package command | Source checkout command | Purpose |
| --- | --- | --- |
| `ssh-multisession-resume` | `./ssh-multisession-resume` | Install or update the normal setup |
| `ssh-multisession-resume doctor` | `./ssh-multisession-resume doctor` | Verify the current SSH login is attached correctly |
| `ssh-multisession-resume status` | `./ssh-multisession-resume status` | Show SSHD and shell-hook status |
| `ssh-multisession-resume sessions` | `./ssh-multisession-resume sessions` | List managed `tmux` and fallback `screen` sessions |
| `ssh-multisession-resume monitor` | `./ssh-multisession-resume monitor` | Watch managed sessions refresh in place |
| `ssh-multisession-resume deps` | `./ssh-multisession-resume deps` | Install or check `tmux`/`screen` dependencies |
| `ssh-multisession-resume service-install` | `./ssh-multisession-resume service-install` | Install the optional user service |
| `ssh-multisession-resume rollback` | `./ssh-multisession-resume rollback` | Remove SSHD config, service, and shell hooks |

The packaged command is a wrapper. It runs the same root installer from
`/usr/lib/ssh-multisession-resume/ssh-multisession-resume`, but help text and
completion hints should still name `ssh-multisession-resume`.

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
`/usr/bin` and `/usr/lib/ssh-multisession-resume`. They intentionally do not
rewrite host-owned state such as `/etc/ssh/sshd_config`, shell profile hooks,
or the optional user systemd unit.

After upgrading, check the active install:

```bash
ssh-multisession-resume status
```

Re-run `ssh-multisession-resume` from the SSH login you want to preserve when
you need to add a new client IP or when release notes mention SSHD or hook
behavior changes.

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

To undo the normal setup:

```bash
ssh-multisession-resume rollback
```

Rollback removes:

- the managed SSHD config block
- the optional user service
- the shell profile hook

It does not kill unrelated user sessions.

## Smoke Checks

From a source checkout, run smoke checks with:

```bash
env -u TMUX -u STY ./tests/smoke.sh
```

The AUR package also runs this smoke suite from `check()` when makepkg checks
are enabled.

## Files

| Path | Purpose |
| --- | --- |
| `ssh-multisession-resume` | Main source-checkout operator command |
| `server/install.sh` | SSHD match-block install, status, and rollback |
| `server/01-sshd-auto-resume.conf` | Static reference SSHD snippet |
| `client/install.sh` | Shell hook, session listing, and user service setup |
| `client/auto-resume.sh` | Runtime auto-attach guard |
| `client/tmux-auto-resume.conf` | Managed `tmux` defaults |
| `client/screen-auto-resume.screenrc` | Fallback `screen` defaults |
| `tests/smoke.sh` | Non-destructive syntax and behavior checks |

## Notes

- Linux/OpenSSH is assumed.
- Exact IPv4 addresses and IPv4 CIDR ranges from any IPv4 network are
  supported. It is not limited to Tailscale or `100.x.x.x` addresses.
- IPv6 matching is not implemented yet.
- Multi-IP matching is emitted as one OpenSSH criteria value:
  `Match Address ip1,ip2`.
- The managed SSHD block is appended to the end of `sshd_config` because
  OpenSSH `Match` blocks do not have an explicit end marker.
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
