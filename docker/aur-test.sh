#!/usr/bin/env bash
set -euo pipefail

NAME="ssh-multisession-resume"
PORT="${SSH_MULTISESSION_TEST_SSH_PORT:-2222}"
KEY="/tmp/${NAME}-test-key"
SSHD_PID=""

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -f /tmp/sshd.log ]]; then
    printf '\nsshd log:\n' >&2
    cat /tmp/sshd.log >&2 || true
  fi
  exit 1
}

cleanup() {
  if id tester >/dev/null 2>&1; then
    tester_tmux_default kill-server >/dev/null 2>&1 || true
    tester_tmux_runtime kill-server >/dev/null 2>&1 || true
  fi
  if [[ -n "${SSHD_PID:-}" ]]; then
    kill "$SSHD_PID" >/dev/null 2>&1 || true
    wait "$SSHD_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM HUP

install_build_deps() {
  pacman -Syu --noconfirm --needed base-devel git sudo openssh ca-certificates
}

prepare_builder() {
  if ! id builder >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash builder
  fi
  printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
  chmod 0440 /etc/sudoers.d/builder
}

install_aur_package() {
  sudo -u builder bash -lc "
    set -euo pipefail
    cd /home/builder
    git clone https://aur.archlinux.org/${NAME}-git.git
    cd ${NAME}-git
    makepkg --syncdeps --install --noconfirm --needed
  "
}

prepare_login_user() {
  if ! id tester >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash tester
  fi
  printf 'tester:tester\n' | chpasswd
  install -d -m700 -o tester -g tester /home/tester/.ssh
  ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null
  install -m600 -o tester -g tester "${KEY}.pub" /home/tester/.ssh/authorized_keys
}

sshd_path() {
  command -v sshd 2>/dev/null || printf '/usr/sbin/sshd\n'
}

start_sshd() {
  local config="/tmp/sshd_config"
  local sshd
  sshd="$(sshd_path)"
  ssh-keygen -A >/dev/null
  mkdir -p /run/sshd
  cat > "$config" <<EOF
Port ${PORT}
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
  "$sshd" -D -f "$config" -E /tmp/sshd.log &
  SSHD_PID=$!
  for _ in $(seq 1 50); do
    if ssh -p "$PORT" -i "$KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      tester@127.0.0.1 true >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  fail "sshd did not become ready"
}

run_login() {
  local _cli="$1"
  local out="$2"
  (sleep 8) | TERM=xterm timeout 10 ssh -tt -p "$PORT" -i "$KEY" \
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

tester_tmux_default() {
  sudo -u tester env HOME=/home/tester USER=tester tmux -L ssh-resume-tester "$@"
}

tester_tmux_runtime() {
  sudo -u tester env HOME=/home/tester USER=tester TMUX_TMPDIR="$(tester_runtime_dir)" tmux -L ssh-resume-tester "$@"
}

managed_tmux_sessions() {
  {
    tester_tmux_runtime list-sessions 2>/dev/null || true
    tester_tmux_default list-sessions 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

assert_single_managed_slot() {
  local label="$1"
  local out="$2"
  local sessions
  local count

  sessions="$(managed_tmux_sessions)"
  count="$(printf '%s\n' "$sessions" | grep -Ec '^ip-127_0_0_1-[0-9]+:' || true)"
  if [[ "$count" == "1" ]] && printf '%s\n' "$sessions" | grep -q '^ip-127_0_0_1-0:'; then
    log "PASS: $label"
  else
    fail "$label failed; sessions: ${sessions:-<none>}; ssh output: $(cat "$out")"
  fi
}

assert_login_works() {
  local cli="/usr/bin/${NAME}"
  local out1="/tmp/login1.out"
  local out2="/tmp/login2.out"

  tester_tmux_default kill-server >/dev/null 2>&1 || true
  tester_tmux_runtime kill-server >/dev/null 2>&1 || true
  sudo -u tester env HOME=/home/tester USER=tester "$cli" policy set 127.0.0.1 single >/dev/null
  run_login "$cli" "$out1"
  assert_single_managed_slot "first SSH login uses slot 0" "$out1"

  run_login "$cli" "$out2"
  assert_single_managed_slot "second SSH login reuses slot 0" "$out2"
  tester_tmux_default kill-server >/dev/null 2>&1 || true
  tester_tmux_runtime kill-server >/dev/null 2>&1 || true
}

install_build_deps
prepare_builder
install_aur_package
command -v "${NAME}" >/dev/null || fail "installed command missing"
command -v tmux >/dev/null || fail "tmux missing after AUR install"
command -v screen >/dev/null || fail "screen missing after AUR install"
command -v sshd >/dev/null || [[ -x /usr/sbin/sshd ]] || fail "sshd missing after AUR install"
prepare_login_user
start_sshd
assert_login_works
log "AUR PHASE OK"
