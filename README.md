<p align="center">
  <img src="assets/capybara-terminal.png" alt="Pixel art capybara using a green terminal" width="860">
</p>

# SSH Multisession Resume

**Server-side SSH auto-resume. Install once, reconnect from anything.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![AUR](https://img.shields.io/aur/version/ssh-multisession-resume-git?label=AUR)](https://aur.archlinux.org/packages/ssh-multisession-resume-git)
[![Packages](https://img.shields.io/badge/packages-arch%20%7C%20deb%20%7C%20rpm%20%7C%20apk-success.svg)](#release-packages)

No client script. No iPad setup. Install on the SSH server and connect like
normal.

## Install

```bash
yay -S ssh-multisession-resume-git
# or
paru -S ssh-multisession-resume-git
```

Source install on Arch, Debian, Ubuntu, Fedora, openSUSE, Alpine, and friends:

```bash
git clone https://github.com/Bit-Loop/ssh-multisession-resume.git
cd ssh-multisession-resume
./run.sh
```

## Session Picker, Live Preview & Empty-Terminal Detection

Your very first SSH login opens `ssh-resume-0` immediately with no prompt.
Whenever open managed sessions already exist on subsequent connects or new SSH
instances, the interactive **Session Picker** appears automatically:

- **Arrow keys (`Up`/`Down` or `j`/`k`)** browse detached sessions with a live
  pane preview, or **type a number (`1`–`9`)** to jump straight in.
- **Active sessions are never previewed**: any currently attached session is
  marked `[active - preview hidden]` and `capture-pane` is strictly skipped.
- **Cleared & empty terminal detection**: single-pane idle shells with no
  running foreground or background child processes are automatically badged as
  `[empty]` (fresh untouched shell) or `[cleared]` (`clear` / `Ctrl-L` shell)
  so you can reuse or prune them in one keypress (`c`).
- **Built-in IP & transfer controls**: press `t` to transfer/reclaim a session
  whose old SSH connection went stale, `d` to drop a detached session, or `i`
  to open the interactive **IP & Session Manager** directly from the picker.

Configure login picker behavior anytime with:

```bash
ssh-multisession-resume picker auto   # default: open when sessions exist
ssh-multisession-resume picker on     # always open on SSH login
ssh-multisession-resume picker off    # silent first-free-slot attach
```

## Native Terminal History, Mouse & TUI Scrolling

Managed `tmux` sessions are preconfigured for a native terminal feel across
full-screen TUIs, editors, pagers, and 200,000-line shell output:

- **Mouse-aware TUIs (`opencode`, `nvim`, `htop`, `btop`, `nano -m`)**: mouse
  wheel, trackpad scrolling, clicks, and drags forward directly into the TUI's
  scrollable panes instead of cycling prompt history.
- **Editors & pagers without mouse mode (`nano`, `less`, `man`, `git log`)**:
  emulates native terminal alternate-scroll by scrolling 3 lines up/down per
  wheel notch instead of trapping you in tmux `copy-mode`.
- **Shell output & long logs (`cat`, build logs, inline CLI output)**: scrolling
  up with the mouse wheel/trackpad or pressing `Shift+PageUp` / `Shift+PageDown`
  smoothly browses the **200,000-line** scrollback buffer and automatically
  exits back to the live prompt when you scroll down to the bottom.
- **Clipboard, low-latency ESC & TrueColor**: OSC 52 clipboard sync
  (`set-clipboard on`), `10ms` ESC responsiveness, `focus-events`, and 24-bit
  TrueColor are enabled out of the box (hold `Shift` or `Option` while dragging
  to use your local terminal's native text selection).
- **Live upgrades & custom overrides**: config updates apply automatically to
  already-running tmux servers on next attach or instantly via
  `ssh-multisession-resume reload`, and optional personal overrides can be
  placed in `~/.config/ssh-multisession-resume/tmux.conf`.

## Modes & First-Login Menu

New logins default to `multi` without prompting:

| Mode | Behavior |
| --- | --- |
| `single` | Always return to one persistent terminal |
| `multi` | Shared global pool with concurrent slots (default) |
| `skip` | Leave that source alone |
| `per-client` | Separate `ip-<source>-N` pool per source IP |

The per-IP mode prompt is **off by default**. Enable it with
`ssh-multisession-resume menu on` to let each new source IP pick a mode,
including `per-client`; disable it again with `menu off`. Choices live in
`~/.config/ssh-multisession-resume/choices/` and can also be set with
`ssh-multisession-resume policy set`.

## IP & Session Management

Client IPs, device labels, connection counts, and session ownership are stored
under `~/.config/ssh-multisession-resume/` (`ips/` and `sessions/`):

- **Transfer (`ip transfer OLD_IP [NEW_IP] [--detach]`)**: migrates saved
  policies, device labels, session ownership records, and live `ip-<old>-N`
  per-client tmux slots (`rename-session`) to `NEW_IP` (defaults to your
  current SSH IP), optionally detaching stale clients without killing running
  programs.
- **Drop (`ip drop IP [--detach] [--kill-detached]`)**: removes stored IP
  records and safely migrates any `ip-<old>-N` per-client sessions back into
  the shared `ssh-resume-N` pool so open work is never orphaned (or closes only
  detached sessions with `--kill-detached`, never touching active sessions).
- **Label (`ip label IP NAME`)**: tag dynamic or Tailscale/LAN IPs (e.g.
  `laptop`, `ipad`) so they appear by name in `sessions`, `ip show`, and the
  login picker.

## Commands

```bash
ssh-multisession-resume status
ssh-multisession-resume doctor
ssh-multisession-resume reload
ssh-multisession-resume pick
ssh-multisession-resume picker show
ssh-multisession-resume sessions
ssh-multisession-resume sessions clean --cleared
ssh-multisession-resume sessions drop ssh-resume-2
ssh-multisession-resume sessions transfer ssh-resume-0 --detach
ssh-multisession-resume ip show
ssh-multisession-resume ip label 100.101.137.20 ipad
ssh-multisession-resume ip transfer 192.168.1.50 100.101.137.20 --detach
ssh-multisession-resume ip drop 192.168.1.50
ssh-multisession-resume ip prune
ssh-multisession-resume policy show
ssh-multisession-resume policy move OLD_IP NEW_IP
ssh-multisession-resume menu on
ssh-multisession-resume menu off
ssh-multisession-resume menu show
ssh-multisession-resume opt-out
```

## Release Packages

```bash
./run.sh package
```

Attach all built artifacts to the release:

| Tested distro | Release asset |
| --- | --- |
| Arch | `ssh-multisession-resume-git-<version>-any.pkg.tar.zst` |
| Debian | `ssh-multisession-resume_<version>_all.deb` |
| Ubuntu | `ssh-multisession-resume_<version>_all.deb` |
| Fedora | `ssh-multisession-resume-<version>.noarch.rpm` |
| openSUSE | `ssh-multisession-resume-<version>.noarch.rpm` |
| yum / Amazon Linux | `ssh-multisession-resume-<version>.noarch.rpm` |
| Alpine | `ssh-multisession-resume-<version>.noarch.apk` |

All artifacts are architecture-independent: `any`, `all`, or `noarch`.

## Verify

```bash
./run.sh test
./run.sh test:all
./run.sh test:aur
```
