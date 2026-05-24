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

1. Builds `archlinux:base-devel` + the runtime/build deps the suite
   exercises (`bash`, `tmux`, `screen`, `openssh`, `sudo`, `shellcheck`,
   `zsh`, `dash`).
2. Runs `tests/smoke.sh` — the 55-case TDD suite.
3. Re-implements the PKGBUILD `package()` step in `/usr/lib/...` and
   `/etc/profile.d/...` exactly the way the AUR install would.
4. Asserts the **zero-touch** guarantees, in order:
   - Non-SSH login is a clean no-op.
   - `~/.config/ssh-multisession-resume/opt-out` short-circuits without
     prompting.
   - A saved choice (`single` / `multi` / `skip`) bypasses the menu.
   - `policy set / show / forget / clear` round-trips through the
     installed CLI.
   - `--help` advertises every user-facing subcommand.
   - The default no-args action is non-interactive (no Y/N prompt).

If every assertion holds, the container exits 0 with
`ALL CONTAINER TESTS PASSED`.

## Outputs

`docker/output/` collects timestamped logs. The directory is gitignored.
