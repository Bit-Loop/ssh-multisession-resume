# SSH Multisession Resume

**Server-side SSH auto-resume. Install once, reconnect from anything.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![AUR](https://img.shields.io/aur/version/ssh-multisession-resume-git?label=AUR)](https://aur.archlinux.org/packages/ssh-multisession-resume-git)
[![Packages](https://img.shields.io/badge/packages-arch%20%7C%20deb%20%7C%20rpm%20%7C%20apk-success.svg)](#release-assets)

```text
      ssh drops
         X
         |
   +-----v----------------+
   | tmux keeps it alive  |
   +-----+----------------+
         |
      ssh back
         |
      same shell
```

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

The first interactive login from each source IP asks:

| Mode | Behavior |
| --- | --- |
| `single` | Always return to one persistent terminal |
| `multi` | Keep parallel SSH logins separate |
| `skip` | Leave that source alone |

Choices live in `~/.config/ssh-multisession-resume/choices/`.

## Commands

```bash
ssh-multisession-resume status
ssh-multisession-resume doctor
ssh-multisession-resume sessions
ssh-multisession-resume policy show
ssh-multisession-resume policy move OLD_IP NEW_IP
ssh-multisession-resume opt-out
```

## Release Assets

```bash
./run.sh package
```

Attach all package families to the release:

| Family | Asset |
| --- | --- |
| Arch / pacman | `ssh-multisession-resume-git-<version>-any.pkg.tar.zst` |
| Debian / Ubuntu | `ssh-multisession-resume_<version>_all.deb` |
| Fedora / openSUSE / RHEL-family | `ssh-multisession-resume-<version>.noarch.rpm` |
| Alpine | `ssh-multisession-resume-<version>.noarch.apk` |

All artifacts are architecture-independent: `any`, `all`, or `noarch`.

## Verify

```bash
./run.sh test
./run.sh test:all
./run.sh test:aur
```
