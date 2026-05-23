# Changelog

## Unreleased / main

- Zero-touch deployment: package installs `/etc/profile.d/ssh-multisession-resume.sh`
  so every interactive SSH login is hooked without per-user `apply`. Legacy
  `apply`/`rollback` are kept for source-checkout users.
- New per-IP menu shown on the first connect: choose `single` (one persistent
  session shared across reconnects), `multi` (fresh slot per connect; concurrent
  sessions OK), or `skip` (plain shell, no auto-attach). The choice is saved to
  `~/.config/ssh-multisession-resume/choices/<sanitized-ip>` and persists across
  reboots. Override at runtime via `SSH_AUTO_RESUME_MODE=single|multi|skip`.
- New CLI subcommands:
  - `policy show|set IP MODE|forget IP|clear`
  - `opt-out` / `opt-in` (writes/removes
    `~/.config/ssh-multisession-resume/opt-out`)
  - default action (no args) is now `summary` — install state, saved policies,
    and next-step hints — instead of the interactive `apply` prompt.
- Single-mode forces tmux/screen slot 0 for the IP, enabling multi-attach when
  several concurrent connections arrive.
- Wayland coverage: `WAYLAND_DISPLAY` (and `MSYSTEM`) pinned in the tmux
  `update-environment` so reconnects via `waypipe` / `wayvnc` see live sockets
  in new panes.
- AUR package promotes `tmux` and `screen` from `optdepends` to hard `depends`,
  so the install is immediately usable.
- Code-quality pass:
  - EXIT/INT/TERM/HUP traps added to seven `mktemp` sites in client/server
    install scripts so a signaled abort no longer strands `/tmp` files.
  - Misleading `_ssh_auto_resume_screen_args` flag renamed to
    `_ssh_auto_resume_has_screenrc`.
  - `SSH_AUTO_RESUME_LOCK_RETRIES` env var (default `50`) for slot-lock retry
    budget tuning under contention.
  - `policy show` tolerates `SIGPIPE` (`policy show | head` no longer crashes
    the CLI under `set -euo pipefail`).
- Full TDD suite (`tests/smoke.sh`) rebuilt around a small `tests/lib.sh`
  harness: 55 named test cases covering sanitization, source-IP extraction,
  runtime-dir resolution, slot allocation (multi, single, reserved, exhausted),
  lock recovery + retry tuning, screen-state parsing, choice IO with garbage
  rejection, the menu in every input mode, profile-entry static gates,
  CLI subcommands, IPv4/CIDR/keepalive validation, idempotent apply/rollback,
  legacy root-binary apply, signal-driven temp cleanup, and PKGBUILD/SRCINFO
  invariants. `shellcheck -S warning` clean across the entire script set.

## 0.r8.g3da2e62-1

- Cleaned ShellCheck findings in sourced helper scripts and package hooks.
- Made smoke-test negative assertions explicit under `set -e`.
- Hardened temporary runtime directory permission handling.
- Kept host-owned configuration untouched during package upgrades.

## 0.r7.g2c5805f-1

- Hardened IPv4, CIDR, and keepalive input validation.
- Expanded fuzz coverage for address parsing, source detection, and tmux slot
  exhaustion.

## 0.r6.gf7d4b81-1

- Prepared the AUR package entrypoint.
- Removed the confusing root `install.sh` shim in favor of
  `ssh-multisession-resume`.
- Added package install/upgrade messaging.
