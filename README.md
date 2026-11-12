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

## First SSH Login

New logins default to `multi` without prompting. Every source IP shares the
same session pool: a reconnect from any IP attaches to the first free slot,
and concurrent logins get additional slots.

| Mode | Behavior |
| --- | --- |
| `single` | Always return to one persistent terminal |
| `multi` | Shared global pool with concurrent slots (default) |
| `skip` | Leave that source alone |
| `per-client` | Separate `ip-<source>-N` pool per source IP |

The first-login menu is **off by default**. Enable it with
`ssh-multisession-resume menu on` to let each new source IP pick a mode,
including `per-client`; disable it again with `menu off`. Choices are saved in
`~/.config/ssh-multisession-resume/choices/` and can also be set directly with
`ssh-multisession-resume policy set`.

## Commands

```bash
ssh-multisession-resume status
ssh-multisession-resume doctor
ssh-multisession-resume sessions
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
