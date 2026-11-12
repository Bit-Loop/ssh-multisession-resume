# Security Policy

## Supported Scope

`ssh-multisession-resume` is intended for Linux hosts running OpenSSH server
configuration compatible with `sshd_config` `Match Address` blocks.

The package manages:
- a package-owned command under `/usr/bin`
- package-owned helper files under `/usr/lib/ssh-multisession-resume`
- a system login hook at `/etc/profile.d/ssh-multisession-resume.sh`
- per-user state under `~/.config/ssh-multisession-resume` (`0700`)
- an optional operator-approved managed block in `/etc/ssh/sshd_config`
- optional per-user shell profile hooks and systemd keepalive unit

Package upgrades replace only package-owned files. Host-owned configuration is
preserved unless the operator runs `ssh-multisession-resume` or
`ssh-multisession-resume rollback`.

## Security Model

The tool does not bypass SSH authentication or grant shell access. OpenSSH
still authenticates users normally. Both IPv4 and IPv6 addresses (including CIDR
ranges and scoped link-local IPv6 addresses) are validated strictly when using
optional `sshd_config` `Match Address` blocks.

Active sessions (any session currently attached by a client or reserved during
login handoff) are never captured or previewed by the session picker.

Interactive auto-attach is skipped for:
- noninteractive SSH commands
- sessions without a TTY
- shells already inside `tmux` or `screen`
- users who opt out via `ssh-multisession-resume opt-out`

## Reporting

Report security issues through the GitHub repository:

https://github.com/Bit-Loop/ssh-multisession-resume/issues

If a report includes sensitive host details, redact usernames, public IPs,
private hostnames, and SSH configuration that is unrelated to the issue.

## Maintainer Checks

Before publishing source and AUR updates, run:

```bash
shellcheck bin/ssh-multisession-resume sshd/match-install.sh runtime/install.sh runtime/auto-resume.sh runtime/auto-screen.sh tests/smoke.sh
shellcheck -s bash -e SC2034,SC2154 PKGBUILD
env -u TMUX -u STY ./tests/smoke.sh
makepkg --printsrcinfo
makepkg -f
namcap PKGBUILD
namcap ssh-multisession-resume-git-*-any.pkg.tar.zst
```
