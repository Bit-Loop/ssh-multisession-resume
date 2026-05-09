# Security Policy

## Supported Scope

`ssh-multisession-resume` is intended for Linux hosts running OpenSSH server
configuration compatible with `sshd_config` `Match Address` blocks.

The package manages:
- a package-owned command under `/usr/bin`
- package-owned helper files under `/usr/lib/ssh-multisession-resume`
- an operator-approved managed block in `/etc/ssh/sshd_config`
- per-user shell profile hooks
- an optional per-user systemd unit

Package upgrades replace only package-owned files. Host-owned configuration is
preserved unless the operator runs `ssh-multisession-resume` or
`ssh-multisession-resume rollback`.

## Security Model

The tool does not bypass SSH authentication or grant shell access. OpenSSH
still authenticates users normally. The managed `Match Address` block only sets
`SSH_AUTO_RESUME=1` for already-authenticated interactive logins from configured
IPv4 addresses or IPv4 CIDR ranges.

Interactive auto-attach is skipped for:
- noninteractive SSH commands
- sessions without a TTY
- shells already inside `tmux` or `screen`
- logins that do not match the managed OpenSSH criteria

IPv6 matching is not implemented.

## Reporting

Report security issues through the GitHub repository:

https://github.com/Bit-Loop/ssh-multisession-resume/issues

If a report includes sensitive host details, redact usernames, public IPs,
private hostnames, and SSH configuration that is unrelated to the issue.

## Maintainer Checks

Before publishing source and AUR updates, run:

```bash
shellcheck ssh-multisession-resume server/install.sh client/install.sh client/auto-resume.sh client/auto-screen.sh tests/smoke.sh ssh-multisession-resume.install
shellcheck -s bash -e SC2034,SC2154 PKGBUILD
env -u TMUX -u STY ./tests/smoke.sh
makepkg --printsrcinfo
makepkg -f
namcap PKGBUILD
namcap ssh-multisession-resume-git-*-any.pkg.tar.zst
```
