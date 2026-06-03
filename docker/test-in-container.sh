#!/usr/bin/env bash
# Runs inside distro containers built from docker/Dockerfile.
#
# Modes:
#   --mode arch-package  Arch package path: makepkg -> smoke -> profile.d checks
#   --mode source-login  source install path: ./run.sh install -> real SSH login
#   --phase save       set persistent state into $HOME for the second container
#   --phase verify     read the saved state back; assert "reboot" survival
#
# Note: tmux and screen are intentionally NOT in the base image. The full run
# builds and installs the local package with makepkg, proving those multiplexers
# arrive through package dependency resolution.
set -uo pipefail

cd /work || { echo "missing /work mount" >&2; exit 2; }

PROG_NAME="ssh-multisession-resume"
LIB_DIR="/usr/lib/${PROG_NAME}"
ETC_HOOK="/etc/profile.d/${PROG_NAME}.sh"
TESTER_HOME="${HOME:-/home/tester}"

PASS_COUNT=0
FAIL_COUNT=0
MODE="arch-package"
PHASE="full"
SSHD_PID=""

red()    { printf '\033[31m%s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
heading() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }

ok()   { green   "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { red     "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup_container() {
  if id tester >/dev/null 2>&1; then
    sudo -u tester env HOME=/home/tester USER=tester tmux -L ssh-resume-tester kill-server >/dev/null 2>&1 || true
  fi
  if [[ -n "${SSHD_PID:-}" ]]; then
    kill "$SSHD_PID" >/dev/null 2>&1 || true
    wait "$SSHD_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_container EXIT INT TERM HUP

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:?}"
      shift 2
      ;;
    --phase)
      PHASE="${2:?}"
      shift 2
      ;;
    *)
      red "unknown arg: $1"
      exit 2
      ;;
  esac
done

install_package_files() {
  sudo install -Dm755 ssh-multisession-resume "${LIB_DIR}/ssh-multisession-resume"
  sudo install -Dm755 client/install.sh        "${LIB_DIR}/client/install.sh"
  sudo install -Dm644 client/auto-resume.sh    "${LIB_DIR}/client/auto-resume.sh"
  sudo install -Dm644 client/auto-screen.sh    "${LIB_DIR}/client/auto-screen.sh"
  sudo install -Dm644 client/tmux-auto-resume.conf       "${LIB_DIR}/client/tmux-auto-resume.conf"
  sudo install -Dm644 client/screen-auto-resume.screenrc "${LIB_DIR}/client/screen-auto-resume.screenrc"
  sudo install -Dm644 client/screen-hangup-off.screenrc  "${LIB_DIR}/client/screen-hangup-off.screenrc"
  sudo install -Dm755 server/install.sh        "${LIB_DIR}/server/install.sh"
  sudo install -Dm644 client/profile-entry.sh  "${ETC_HOOK}"

  sudo install -dm755 /usr/bin
  sudo tee /usr/bin/ssh-multisession-resume >/dev/null <<EOF
#!/usr/bin/env bash
export SSH_MULTISESSION_RESUME_COMMAND=ssh-multisession-resume
exec /usr/lib/ssh-multisession-resume/ssh-multisession-resume "\$@"
EOF
  sudo chmod 755 /usr/bin/ssh-multisession-resume
}

build_and_install_local_package() {
  local build_dir src_name pkg_file current_pkgver

  if ! id builder >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash builder
  fi
  printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
  chmod 0440 /etc/sudoers.d/builder

  build_dir="$(mktemp -d)"
  src_name="${PROG_NAME}-source"
  current_pkgver="$(awk -F= '$1 == "pkgver" { print $2; exit }' /work/PKGBUILD)"
  mkdir -p "${build_dir}/${src_name}"

  tar -C /work \
    --exclude='./.git' \
    --exclude='./.aur' \
    --exclude='./.agents' \
    --exclude='./.codex' \
    --exclude='./pkg' \
    --exclude='./src' \
    --exclude='./docker/output' \
    --exclude='./ssh-multisession-resume-source' \
    -cf - . | tar -C "${build_dir}/${src_name}" -xf -

  tar -C "$build_dir" -czf "${build_dir}/${src_name}.tar.gz" "$src_name"
  sed \
    -e 's|^source=.*|source=("${_srcname}.tar.gz")|' \
    -e "s|^sha256sums=.*|sha256sums=('SKIP')|" \
    /work/PKGBUILD > "${build_dir}/PKGBUILD"
  {
    printf '\n'
    printf 'pkgver() {\n'
    printf "  printf '%%s\\\\n' '%s'\n" "$current_pkgver"
    printf '}\n'
  } >> "${build_dir}/PKGBUILD"
  cp /work/ssh-multisession-resume.install "$build_dir/"
  chown -R builder:builder "$build_dir"

  if (cd "$build_dir" && sudo -u builder makepkg --syncdeps --install --noconfirm --needed); then
    pkg_file="$(find "$build_dir" -maxdepth 1 -name "${PROG_NAME}-git-*.pkg.tar.*" -print -quit)"
    if [[ -n "$pkg_file" ]]; then
      ok "built package artifact: $(basename "$pkg_file")"
      if [[ "$(basename "$pkg_file")" == *'0.r.g'* ]]; then
        fail "package artifact has invalid fallback pkgver: $(basename "$pkg_file")"
      fi
    else
      fail "package artifact missing after makepkg"
    fi
  else
    fail "makepkg --syncdeps --install failed"
  fi

  rm -rf "$build_dir"
}

prepare_login_user() {
  local user="tester"
  local key="/tmp/${PROG_NAME}-test-key"

  if ! id "$user" >/dev/null 2>&1; then
    sudo useradd --create-home --shell /bin/bash "$user"
  fi
  printf 'tester:tester\n' | sudo chpasswd

  sudo install -d -m700 -o "$user" -g "$user" /home/tester/.ssh
  rm -f "$key" "${key}.pub"
  ssh-keygen -t ed25519 -N '' -f "$key" >/dev/null
  sudo install -m600 -o "$user" -g "$user" "${key}.pub" /home/tester/.ssh/authorized_keys
}

sshd_path() {
  command -v sshd 2>/dev/null || printf '/usr/sbin/sshd\n'
}

start_test_sshd() {
  local config="/tmp/sshd_config"
  local sshd
  sshd="$(sshd_path)"

  sudo ssh-keygen -A >/dev/null
  sudo mkdir -p /run/sshd
  sudo tee "$config" >/dev/null <<EOF
Port 2222
ListenAddress 127.0.0.1
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
UsePAM no
PrintMotd no
PidFile /tmp/sshd.pid
Subsystem sftp internal-sftp
EOF

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$sshd" -D -f "$config" -E /tmp/sshd.log &
  else
    sudo "$sshd" -D -f "$config" -E /tmp/sshd.log &
  fi
  SSHD_PID=$!
  for _ in $(seq 1 50); do
    if ssh -p 2222 -i /tmp/${PROG_NAME}-test-key \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      tester@127.0.0.1 true >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  if [[ -f /tmp/sshd.log ]]; then
    cat /tmp/sshd.log >&2 || true
  fi
  fail "test sshd did not become ready"
}

run_ssh_login() {
  local _cli="$1"
  local out="$2"

  (sleep 8) | TERM=xterm timeout 10 ssh -tt -p 2222 -i /tmp/${PROG_NAME}-test-key \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      tester@127.0.0.1 > "$out" 2>&1 || true
}

tester_runtime_dir() {
  local uid
  uid="$(id -u tester)"
  printf '/tmp/ssh-auto-resume-%s\n' "$uid"
}

tester_tmux() {
  sudo -u tester env HOME=/home/tester USER=tester TMUX_TMPDIR="$(tester_runtime_dir)" tmux -L ssh-resume-tester "$@"
}

managed_tmux_sessions() {
  tester_tmux list-sessions 2>/dev/null || true
}

assert_single_managed_slot() {
  local label="$1"
  local out="$2"
  local sessions
  local count

  sessions="$(managed_tmux_sessions)"
  count="$(printf '%s\n' "$sessions" | grep -Ec '^ip-127_0_0_1-[0-9]+:' || true)"
  if [[ "$count" == "1" ]] && printf '%s\n' "$sessions" | grep -q '^ip-127_0_0_1-0:'; then
    ok "$label"
  else
    fail "$label failed; sessions: ${sessions:-<none>}; ssh output: $(cat "$out")"
  fi
}

assert_real_ssh_login_reuses_session() {
  local cli="$1"
  local out1="/tmp/${PROG_NAME}-login-1.out"
  local out2="/tmp/${PROG_NAME}-login-2.out"

  tester_tmux kill-server >/dev/null 2>&1 || true
  sudo -u tester env HOME=/home/tester USER=tester "$cli" policy set 127.0.0.1 single >/dev/null

  run_ssh_login "$cli" "$out1"
  assert_single_managed_slot "first real SSH login lands in managed tmux slot 0" "$out1"

  run_ssh_login "$cli" "$out2"
  assert_single_managed_slot "second real SSH login reuses managed tmux slot 0" "$out2"
  tester_tmux kill-server >/dev/null 2>&1 || true
}

run_source_login_suite() {
  heading "Phase A: source install from checkout"
  if SSH_MULTISESSION_ASSUME_YES=1 /work/run.sh install --yes; then
    ok "run.sh install completed"
  else
    fail "run.sh install failed"
  fi

  for path in /usr/local/bin/${PROG_NAME} /usr/local/lib/${PROG_NAME}/${PROG_NAME} /etc/profile.d/${PROG_NAME}.sh; do
    if [[ -e "$path" ]]; then
      ok "installed $path"
    else
      fail "missing $path"
    fi
  done

  if command -v tmux >/dev/null 2>&1; then
    ok "tmux present after source install"
  else
    fail "tmux missing after source install"
  fi
  if command -v screen >/dev/null 2>&1; then
    ok "screen present after source install"
  else
    fail "screen missing after source install"
  fi
  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    ok "sshd present after source install"
  else
    fail "sshd missing after source install"
  fi

  heading "Phase B: source tree smoke suite"
  if env -u TMUX -u STY bash tests/smoke.sh; then
    ok "smoke suite"
  else
    fail "smoke suite"
  fi

  heading "Phase C: real SSH login"
  prepare_login_user
  start_test_sshd
  assert_real_ssh_login_reuses_session /usr/local/bin/${PROG_NAME}

  heading "Phase D: source rollback"
  if SSH_MULTISESSION_ASSUME_YES=1 /work/run.sh rollback --yes; then
    ok "run.sh rollback completed"
  else
    fail "run.sh rollback failed"
  fi
  if [[ ! -e /usr/local/bin/${PROG_NAME} && ! -e /etc/profile.d/${PROG_NAME}.sh ]]; then
    ok "source install files removed"
  else
    fail "source install files remain after rollback"
  fi
}

run_full_suite() {
  # ------------------------------------------------------------------
  heading "Phase A: minimal image baseline"
  # ------------------------------------------------------------------
  if command -v tmux >/dev/null 2>&1; then
    fail "tmux unexpectedly preinstalled - image is not minimal"
  else
    ok "tmux not preinstalled (baseline)"
  fi
  if command -v screen >/dev/null 2>&1; then
    fail "screen unexpectedly preinstalled - image is not minimal"
  else
    ok "screen not preinstalled (baseline)"
  fi

  # ------------------------------------------------------------------
  heading "Phase B: package install resolves runtime deps"
  # ------------------------------------------------------------------
  build_and_install_local_package
  if pacman -Q "${PROG_NAME}-git" >/dev/null 2>&1; then
    ok "package installed via pacman: ${PROG_NAME}-git"
  else
    fail "package not installed via pacman"
  fi
  for path in "${LIB_DIR}/ssh-multisession-resume" "${ETC_HOOK}" /usr/bin/ssh-multisession-resume; do
    if [[ -e "$path" ]]; then
      ok "installed $path"
    else
      fail "missing $path"
    fi
  done

  if command -v tmux >/dev/null 2>&1; then
    ok "tmux installed as package dependency: $(command -v tmux)"
  else
    fail "tmux still missing after package install"
  fi
  if command -v screen >/dev/null 2>&1; then
    ok "screen installed as package dependency: $(command -v screen)"
  else
    fail "screen still missing after package install"
  fi

  # ------------------------------------------------------------------
  heading "Phase C: TDD smoke suite"
  # ------------------------------------------------------------------
  # Now that tmux/screen are present, the suite's apply/rollback assertions
  # (which call `client/install.sh apply` and check ~/.bash_profile etc.)
  # can exercise their happy path.
  if env -u TMUX -u STY bash tests/smoke.sh; then
    ok "smoke suite"
  else
    fail "smoke suite"
  fi

  # ------------------------------------------------------------------
  heading "Phase D: zero-touch profile.d hook gates"
  # ------------------------------------------------------------------
  out="$(env -i HOME="$TESTER_HOME" PATH="$PATH" bash -c "
    . '${ETC_HOOK}'
    echo \"SSH_AUTO_RESUME=\${SSH_AUTO_RESUME:-unset}\"
  ")"
  if [[ "$out" == *"SSH_AUTO_RESUME=unset"* ]]; then
    ok "non-SSH login is a clean no-op"
  else
    fail "non-SSH login leaked state: $out"
  fi

  mkdir -p "$TESTER_HOME/.config/ssh-multisession-resume"
  : > "$TESTER_HOME/.config/ssh-multisession-resume/opt-out"
  if env -i HOME="$TESTER_HOME" PATH="$PATH" SSH_CONNECTION='1.2.3.4 5 6 7' \
       bash -c ". '${ETC_HOOK}'; echo done" 2>&1 | grep -q "^done$"; then
    ok "opt-out short-circuits cleanly"
  else
    fail "opt-out did not short-circuit"
  fi
  rm -f "$TESTER_HOME/.config/ssh-multisession-resume/opt-out"

  mkdir -p "$TESTER_HOME/.config/ssh-multisession-resume/choices"
  printf '%s\n' skip > "$TESTER_HOME/.config/ssh-multisession-resume/choices/1_2_3_4"
  out="$(env -i HOME="$TESTER_HOME" PATH="$PATH" SSH_CONNECTION='1.2.3.4 5 6 7' \
         bash -c ". '${ETC_HOOK}'; echo MARK" </dev/null 2>&1)"
  if [[ "$out" != *"Select 1/2/3"* ]] && [[ "$out" == *"MARK"* ]]; then
    ok "saved skip choice bypasses menu (no prompts)"
  else
    fail "saved choice did not bypass menu: $out"
  fi
  rm -rf "$TESTER_HOME/.config/ssh-multisession-resume"

  # ------------------------------------------------------------------
  heading "Phase E: CLI surface non-interactive"
  # ------------------------------------------------------------------
  if ssh-multisession-resume policy set 10.0.0.42 single >/dev/null; then
    ok "policy set 10.0.0.42 single"
  else
    fail "policy set failed"
  fi
  if ssh-multisession-resume policy set 192.168.1.5 multi >/dev/null; then
    ok "policy set 192.168.1.5 multi"
  else
    fail "policy set failed"
  fi
  ssh-multisession-resume policy show > /tmp/policy.out
  if grep -q '10_0_0_42 -> single' /tmp/policy.out; then
    ok "policy show lists 10_0_0_42 -> single"
  else
    fail "policy show missing 10_0_0_42"
  fi
  if grep -q '192_168_1_5 -> multi' /tmp/policy.out; then
    ok "policy show lists 192_168_1_5 -> multi"
  else
    fail "policy show missing 192_168_1_5"
  fi
  if ssh-multisession-resume policy clear >/dev/null; then
    ok "policy clear"
  else
    fail "policy clear failed"
  fi

  sum_out="$(ssh-multisession-resume </dev/null 2>&1 || true)"
  if [[ "$sum_out" == *"Install:"* ]] && [[ "$sum_out" == *"Next steps:"* ]] && \
     [[ "$sum_out" != *"YES"*"NO"* ]]; then
    ok "default action is non-interactive summary"
  else
    fail "default action shape unexpected"
  fi

  # ------------------------------------------------------------------
  heading "Phase F: X11 + Wayland env-refresh pinning"
  # ------------------------------------------------------------------
  conf="${LIB_DIR}/client/tmux-auto-resume.conf"
  if grep -q '^set-option -g update-environment .*DISPLAY' "$conf"; then
    ok "tmux pins DISPLAY"
  else
    fail "tmux conf missing DISPLAY"
  fi
  if grep -q 'WAYLAND_DISPLAY' "$conf"; then
    ok "tmux pins WAYLAND_DISPLAY"
  else
    fail "missing WAYLAND_DISPLAY"
  fi
  if grep -q 'SSH_AUTH_SOCK' "$conf"; then
    ok "tmux pins SSH_AUTH_SOCK"
  else
    fail "missing SSH_AUTH_SOCK"
  fi
  if grep -q 'XAUTHORITY' "$conf"; then
    ok "tmux pins XAUTHORITY"
  else
    fail "missing XAUTHORITY"
  fi
  if grep -q 'SSH_AGENT_PID' "$conf"; then
    ok "tmux pins SSH_AGENT_PID"
  else
    fail "missing SSH_AGENT_PID"
  fi

  # ------------------------------------------------------------------
  heading "Phase G: resource-leak checks"
  # ------------------------------------------------------------------
  # Source profile-entry.sh 100 times in a single bash and assert the FD
  # count and reservation directory size stay flat.
  leak_home="$(mktemp -d)"
  mkdir -p "$leak_home/.config/ssh-multisession-resume/choices"
  printf '%s\n' skip > "$leak_home/.config/ssh-multisession-resume/choices/1_2_3_4"

  fd_before="$(bash -c 'ls /proc/$$/fd | wc -l')"
  bash -c "
    for i in \$(seq 1 100); do
      HOME='$leak_home' SSH_CONNECTION='1.2.3.4 5 6 7' bash -c \". '${ETC_HOOK}'\" </dev/null >/dev/null 2>&1
    done
    ls /proc/\$\$/fd | wc -l
  " > /tmp/fd_after 2>/dev/null
  fd_after="$(cat /tmp/fd_after)"
  if [[ "$fd_after" -le $((fd_before + 5)) ]]; then
    ok "FD count stable over 100 invocations (before=${fd_before} after=${fd_after})"
  else
    fail "FD count grew: before=${fd_before} after=${fd_after}"
  fi

  # Reservation dir should be cleaned up after each invocation. With saved
  # `skip`, no slot is ever reserved, so the dir should not exist.
  if [[ ! -d "$leak_home/.config/ssh-multisession-resume/reservations" ]]; then
    ok "no stray reservations directory in HOME"
  else
    fail "reservations directory leaked in HOME"
  fi

  # Even XDG_RUNTIME_DIR shouldn't accumulate state for skip-mode users.
  runtime_dir="${XDG_RUNTIME_DIR:-/tmp/ssh-auto-resume-$(id -u)}"
  if [[ -d "$runtime_dir" ]]; then
    count="$(find "$runtime_dir" -maxdepth 3 -name 'ssh-resume-*' 2>/dev/null | wc -l)"
    if [[ "$count" -eq 0 ]]; then
      ok "no leftover ssh-resume-* state in $runtime_dir"
    else
      fail "$count leftover state files in $runtime_dir"
    fi
  else
    ok "no runtime dir created for skip-mode users"
  fi

  rm -rf "$leak_home"

  # ------------------------------------------------------------------
  heading "Phase H: edge-case input handling"
  # ------------------------------------------------------------------
  ec_home="$(mktemp -d)"
  mkdir -p "$ec_home/.config/ssh-multisession-resume/choices"

  # Corrupted choice file -> read_choice should reject and the menu would
  # re-prompt. For automation we just check read_choice returns non-zero.
  printf 'totally-bogus-mode\n' > "$ec_home/.config/ssh-multisession-resume/choices/c1"
  if HOME="$ec_home" AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
       . "$AUTO_RESUME"; _ssh_auto_resume_read_choice c1
       ' >/dev/null 2>&1; then
    fail "read_choice accepted corrupted content"
  else
    ok "read_choice rejected corrupted content"
  fi

  # Empty choice file.
  : > "$ec_home/.config/ssh-multisession-resume/choices/c2"
  if HOME="$ec_home" AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
       . "$AUTO_RESUME"; _ssh_auto_resume_read_choice c2
       ' >/dev/null 2>&1; then
    fail "read_choice accepted empty file"
  else
    ok "read_choice rejected empty file"
  fi

  # Choice file with trailing whitespace -> rejected (we want strict).
  printf 'single \n' > "$ec_home/.config/ssh-multisession-resume/choices/c3"
  if HOME="$ec_home" AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
       . "$AUTO_RESUME"; _ssh_auto_resume_read_choice c3
       ' >/dev/null 2>&1; then
    fail "read_choice accepted trailing-whitespace content"
  else
    ok "read_choice rejected trailing-whitespace content"
  fi

  # Multi-line choice file: read first line. If first line is valid, accept.
  printf 'multi\nsecond-line\n' > "$ec_home/.config/ssh-multisession-resume/choices/c4"
  out="$(HOME="$ec_home" AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
         . "$AUTO_RESUME"; _ssh_auto_resume_read_choice c4 && printf "%s" "$_ssh_auto_resume_choice"
         ' 2>/dev/null)"
  if [[ "$out" == "multi" ]]; then
    ok "read_choice accepts first line of multi-line file (got: ${out})"
  else
    fail "read_choice multi-line behavior unexpected (got: ${out})"
  fi

  # Sanitization edge cases.
  sanitized="$(AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
                 . "$AUTO_RESUME"; _ssh_auto_resume_sanitize "$(printf "verylong.%.0s" {1..50})"
                 ' 2>/dev/null)"
  if [[ "${#sanitized}" -gt 0 ]] && [[ ! "$sanitized" =~ [^A-Za-z0-9_-] ]]; then
    ok "sanitize handled very-long input cleanly (len=${#sanitized})"
  else
    fail "sanitize output dirty: $sanitized"
  fi
  unicode_in="$(AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
                  . "$AUTO_RESUME"; _ssh_auto_resume_sanitize "192.168.X.1"
                  ' 2>/dev/null)"
  if [[ ! "$unicode_in" =~ [^A-Za-z0-9_-] ]]; then
    ok "sanitize stripped unicode-ish input to safe chars (got: $unicode_in)"
  else
    fail "sanitize unicode output dirty: $unicode_in"
  fi
  empty_in="$(AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
                . "$AUTO_RESUME"; _ssh_auto_resume_sanitize ""
                ' 2>/dev/null)"
  if [[ -z "$empty_in" ]]; then
    ok "sanitize empty input stays empty"
  else
    fail "sanitize empty input produced: $empty_in"
  fi

  rm -rf "$ec_home"

  # ------------------------------------------------------------------
  heading "Phase I: concurrent slot allocation race"
  # ------------------------------------------------------------------
  # Five parallel processes attempt to reserve a tmux slot from the same
  # source IP. Each must get a unique slot. The protocol's invariant is:
  # the per-shell reservation file lives for as long as the shell does;
  # the lock is held only across select+reserve, then released so the next
  # shell can pick the *next* free slot.
  conc_dir="$(mktemp -d)"
  source="100_101_137_99"
  conc_rt="$(mktemp -d)"
  pids=()
  for ((attempt = 1; attempt <= 5; attempt++)); do
    (
      AUTO_RESUME=/work/client/auto-resume.sh SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c "
        set +e
        . \"\$AUTO_RESUME\"
        _ssh_auto_resume_socket_name=ssh-resume-test
        _ssh_auto_resume_session_base=ip-${source}
        _ssh_auto_resume_reservation_dir='${conc_rt}/reservations'
        _ssh_auto_resume_lock_dir='${conc_rt}/slot.lock'
        _ssh_auto_resume_reservation=''
        mkdir -p \"\$_ssh_auto_resume_reservation_dir\"
        SSH_AUTO_RESUME_MAX_SLOTS=8
        if _ssh_auto_resume_lock 2>/dev/null; then
          if _ssh_auto_resume_select_tmux 2>/dev/null; then
            _ssh_auto_resume_reserve \"tmux-\${_ssh_auto_resume_selected}\"
            echo \"\$_ssh_auto_resume_selected\" >> '${conc_dir}/slots'
            # Release the lock so the next shell can pick a new slot, but
            # keep the reservation alive (real flow: tmux attach is here).
            _ssh_auto_resume_unlock
            sleep 2
          else
            _ssh_auto_resume_unlock
          fi
        fi
        # EXIT trap installed by _ssh_auto_resume_reserve will clean up the
        # reservation when this subshell exits.
      "
    ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

  if [[ -f "$conc_dir/slots" ]]; then
    total="$(wc -l < "$conc_dir/slots")"
    unique="$(sort -u "$conc_dir/slots" | wc -l)"
    if [[ "$total" -ge 3 ]] && [[ "$unique" == "$total" ]]; then
      ok "concurrent slot allocation: ${total} winners, all unique"
    else
      fail "concurrent slot allocation race (total=${total} unique=${unique} -- $(tr '\n' ' ' <"$conc_dir/slots"))"
    fi
  else
    fail "no concurrent winners recorded"
  fi
  rm -rf "$conc_dir" "$conc_rt"

  # ------------------------------------------------------------------
  heading "Phase J: phase-save state into HOME for the persistence run"
  # ------------------------------------------------------------------
  run_phase_save
}

run_phase_save() {
  # Persistent state lives entirely under $HOME, so the same volume re-mount
  # on the next container start should restore it identically.
  ssh-multisession-resume policy clear >/dev/null 2>&1 || true
  ssh-multisession-resume policy set 10.0.0.99 single >/dev/null
  ssh-multisession-resume policy set 192.168.42.7 multi >/dev/null
  ssh-multisession-resume policy set 203.0.113.55 skip >/dev/null
  : > "$TESTER_HOME/.config/ssh-multisession-resume/.phase-save.marker"
  ok "saved 3 policies and the phase marker under $TESTER_HOME/.config/ssh-multisession-resume/"
}

run_phase_verify() {
  heading "Persistence phase: verify state survived 'reboot'"
  install_package_files

  if [[ ! -f "$TESTER_HOME/.config/ssh-multisession-resume/.phase-save.marker" ]]; then
    fail "phase-save marker missing — volume did not persist"
    return
  fi
  ok "phase-save marker present (volume persisted across container lifecycles)"

  ssh-multisession-resume policy show > /tmp/policy.out
  for line in '10_0_0_99 -> single' '192_168_42_7 -> multi' '203_0_113_55 -> skip'; do
    if grep -q "$line" /tmp/policy.out; then
      ok "policy survived: $line"
    else
      fail "policy missing: $line"
    fi
  done

  # The crowning zero-touch claim: no user input is needed even after reboot,
  # the menu is bypassed because the choice already exists.
  out="$(env -i HOME="$TESTER_HOME" PATH="$PATH" SSH_CONNECTION='203.0.113.55 5 6 7' \
         bash -c ". '${ETC_HOOK}'; echo MARK" </dev/null 2>&1)"
  if [[ "$out" != *"Select 1/2/3"* ]] && [[ "$out" == *"MARK"* ]]; then
    ok "post-reboot SSH connect uses saved choice without prompting"
  else
    fail "post-reboot connect prompted unexpectedly: $out"
  fi
}

case "$MODE" in
  arch-package)
    case "$PHASE" in
      full)    run_full_suite ;;
      save)    install_package_files; run_phase_save ;;
      verify)  run_phase_verify ;;
      *)       red "unknown phase: $PHASE"; exit 2 ;;
    esac
    ;;
  source-login)
    run_source_login_suite
    ;;
  *)
    red "unknown mode: $MODE"
    exit 2
    ;;
esac

echo
printf '%s passed, %s failed (mode=%s phase=%s)\n' "$PASS_COUNT" "$FAIL_COUNT" "$MODE" "$PHASE"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  red "CONTAINER PHASE FAILED"
  exit 1
fi
green "CONTAINER PHASE OK"
