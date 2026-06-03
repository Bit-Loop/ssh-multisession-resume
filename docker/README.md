# Containerized Test Suite

Docker tests cover both install paths:

- source checkout installs through `./run.sh`
- AUR installs by cloning `ssh-multisession-resume-git` inside a vanilla Arch container

## Usage

```bash
./run.sh test:all       # local package test + all source distro tests
./run.sh test:aur       # remote AUR package in vanilla Arch
./run.sh test:debian    # one source-install distro
./run.sh package        # build Arch/deb/rpm/apk artifacts into dist/
./run.sh shell debian
```

Supported source-install images:

- Arch (`pacman`)
- Debian (`apt-get`)
- Ubuntu (`apt-get`)
- Fedora (`dnf`)
- Amazon Linux 2 (`yum`)
- openSUSE Leap (`zypper`)
- Alpine (`apk`)

Package artifact builds use clean family-specific containers:

- Arch package: `archlinux:base-devel`
- Debian/Ubuntu `.deb`: `debian:stable-slim`
- RPM-family `.rpm`: `fedora:latest`
- Alpine `.apk`: `alpine:latest`

The generated artifacts are architecture-independent (`any`, `all`, or
`noarch`) and are written to `dist/`.

## What It Verifies

For each source-install image:

1. `./run.sh install --yes` installs runtime dependencies through the distro package manager.
2. `/usr/local/bin/ssh-multisession-resume` and global profile hooks are installed.
3. `tests/smoke.sh` passes.
4. A local `sshd` starts inside the container.
5. Two real SSH logins attach to the same managed `tmux` session.
6. `./run.sh rollback --yes` removes source-installed files and hooks.

For the AUR image:

1. A clean `archlinux:base-devel` container installs only build tooling.
2. The test clones `https://aur.archlinux.org/ssh-multisession-resume-git.git`.
3. `makepkg --syncdeps --install --noconfirm` installs the package.
4. A real SSH login verifies the installed command lands in managed `tmux`.

Logs land in `docker/output/<UTC-timestamp>.log`.
