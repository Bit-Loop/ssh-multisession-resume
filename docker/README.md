# Containerized Test Suite

Reproducible TDD on a clean Arch base image. Mirrors what an AUR user gets.

## Usage

```bash
./docker/run.sh           # build + run, log to docker/output/<ts>.log
./docker/run.sh build     # build image only
./docker/run.sh test      # re-run tests on the existing image
./docker/run.sh shell     # interactive shell inside the container
```

## What it does

1. Builds `archlinux:base-devel` with system and test tooling only. `tmux`
   and `screen` are deliberately absent from the image.
2. Builds and installs the local package with `makepkg --syncdeps --install`,
   proving `tmux` and `screen` arrive through package dependency resolution.
3. Runs `tests/smoke.sh`, the TDD smoke suite.
4. Asserts the **zero-touch** guarantees, in order:
   - Non-SSH login is a clean no-op.
   - `~/.config/ssh-multisession-resume/opt-out` short-circuits without
     prompting.
   - A saved choice (`single` / `multi` / `skip`) bypasses the menu.
   - `policy set / show / forget / clear` round-trips through the
     installed CLI.
   - `--help` advertises every user-facing subcommand.
   - The default no-args action is non-interactive (no Y/N prompt).

If every assertion holds, the container exits 0 with `CONTAINER PHASE OK`.

## Outputs

`docker/output/` collects timestamped logs. The directory is gitignored.
