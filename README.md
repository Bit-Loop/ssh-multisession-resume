# SSH Auto-Resume

Keep your SSH terminal exactly where you left it.

`ssh-auto-resume` automatically attaches selected interactive SSH logins to a
managed `tmux` session. Disconnect from a laptop, tablet, or phone, reconnect
later, and land back in the same shell with the same running programs, panes,
and scrollback.

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

Run the installer from the SSH session you want to preserve:

```bash
git clone https://github.com/<you>/ssh-auto-resume.git
cd ssh-auto-resume
./install.sh
```

When asked to add the current SSH client IP, choose `YES`.

The installer:

- detects your current SSH client IP
- adds a managed `Match Address` block to `sshd_config`
- installs a bash/zsh login hook for your user
- offers to install `tmux`/`screen` if neither is available
- asks for `sudo` only when changing the system SSHD config

Then reconnect:

```bash
exit
ssh your-server
```

Verify the new login:

```bash
./install.sh doctor
```

Success ends with:

```text
doctor: ok
```

## What It Does

```text
matching SSH login
        |
        v
SSHD sets SSH_AUTO_RESUME=1
        |
        v
bash/zsh profile loads client/auto-resume.sh
        |
        v
attach to managed tmux slot
        |
        v
your shell keeps running across disconnects
```

Only matched interactive SSH logins are attached. Normal noninteractive commands
like `ssh host uptime`, scp-style commands, shells without a TTY, and shells
already inside `tmux` or `screen` are left alone.

## Session Slots

Multiple SSH logins from the same user and source IP get separate slots.

```text
source IP 100.101.137.15
        |
        +-- slot 0: default login
        +-- slot 1: second live login
        +-- slot 2: third live login
```

Detached slots are reused first. That means a normal reconnect returns to your
existing work instead of creating a new empty terminal.

Managed `tmux` session names look like:

```text
ip-100_101_137_15-0
ip-100_101_137_15-1
```

## Daily Commands

| Command | Purpose |
| --- | --- |
| `./install.sh` | Install or update the normal setup |
| `./install.sh doctor` | Verify the current SSH login is attached correctly |
| `./install.sh status` | Show SSHD and shell-hook status |
| `./install.sh sessions` | List managed `tmux` and fallback `screen` sessions |
| `./install.sh monitor` | Watch managed sessions refresh in place |
| `./install.sh deps` | Install or check `tmux`/`screen` dependencies |
| `./install.sh service-install` | Install the optional user service |
| `./install.sh rollback` | Remove SSHD config, service, and shell hooks |

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
./install.sh service-install
./install.sh service-status
```

This keeps the `tmux` server available. It does not restore programs after a
full reboot; programs survive SSH disconnects, not machine shutdowns.

Remove the service:

```bash
./install.sh service-rollback
```

## Rollback

To undo the normal setup:

```bash
./install.sh rollback
```

Rollback removes:

- the managed SSHD config block
- the optional user service
- the shell profile hook

It does not kill unrelated user sessions.

## Lower-Level Commands

Most users should use `./install.sh`. These lower-level commands are useful
when you want to inspect or script individual pieces.

Detect the current SSH client IP:

```bash
./server/install.sh detect-current
```

Add a specific IP to the SSHD match list:

```bash
sudo ./server/install.sh add-current --ip 100.101.137.15
```

Install only the current user's shell hook:

```bash
./client/install.sh apply
```

Run smoke checks:

```bash
./tests/smoke.sh
```

## Files

| Path | Purpose |
| --- | --- |
| `install.sh` | Main installer and operator command |
| `server/install.sh` | SSHD match-block install, status, and rollback |
| `server/01-sshd-auto-resume.conf` | Static reference SSHD snippet |
| `client/install.sh` | Shell hook, session listing, and user service setup |
| `client/auto-resume.sh` | Runtime auto-attach guard |
| `client/tmux-auto-resume.conf` | Managed `tmux` defaults |
| `client/screen-auto-resume.screenrc` | Fallback `screen` defaults |
| `tests/smoke.sh` | Non-destructive syntax and behavior checks |

## Notes

- Linux/OpenSSH is assumed.
- Exact IPv4 addresses and IPv4 CIDR ranges are supported.
- Multi-IP matching is emitted as one OpenSSH criteria value:
  `Match Address ip1,ip2`.
- The managed SSHD block is appended to the end of `sshd_config` because
  OpenSSH `Match` blocks do not have an explicit end marker.
- Existing legacy `main` sessions are treated as slot `0` so old work remains
  reachable.
- To intentionally end preserved work, exit the shells/programs inside the
  managed session or run `tmux kill-session` for that session.
