# Changelog

## Unreleased / main

- Added `makepkg` `check()` coverage for the smoke suite.
- Added packaged `SECURITY.md` and `CHANGELOG.md` documentation.
- Documented the deterministic smoke command with `TMUX` and `STY` cleared.

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
