#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT_INSTALL="${ROOT_DIR}/install.sh"
SERVER_INSTALL="${ROOT_DIR}/server/install.sh"
CLIENT_INSTALL="${ROOT_DIR}/client/install.sh"
AUTO_RESUME="${ROOT_DIR}/client/auto-resume.sh"
LEGACY_AUTO_SCREEN="${ROOT_DIR}/client/auto-screen.sh"
TMUX_CONF="${ROOT_DIR}/client/tmux-auto-resume.conf"
SCREENRC="${ROOT_DIR}/client/screen-auto-resume.screenrc"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "missing file: ${path}" >&2
    exit 1
  }
}

require_file "$ROOT_INSTALL"
require_file "$SERVER_INSTALL"
require_file "$CLIENT_INSTALL"
require_file "$AUTO_RESUME"
require_file "$LEGACY_AUTO_SCREEN"
require_file "$TMUX_CONF"
require_file "$SCREENRC"

bash -n "$ROOT_INSTALL"
bash -n "$SERVER_INSTALL"
bash -n "$CLIENT_INSTALL"
bash -n "$AUTO_RESUME"
bash -n "$LEGACY_AUTO_SCREEN"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$AUTO_RESUME"
  zsh -n "$LEGACY_AUTO_SCREEN"
fi

bash -c "SSH_AUTO_RESUME=1 SSH_AUTO_RESUME_TMUX_CONF='${TMUX_CONF}' SSH_AUTO_RESUME_SCREENRC='${SCREENRC}' SSH_CONNECTION=x . '${AUTO_RESUME}'; printf '%s\n' bash-auto-resume-guard-ok"
bash -c "SCREEN_KILL_ON_HANGUP=1 SSH_AUTO_RESUME_TMUX_CONF='${TMUX_CONF}' SSH_AUTO_RESUME_SCREENRC='${SCREENRC}' SSH_CONNECTION=x . '${AUTO_RESUME}'; printf '%s\n' bash-legacy-auto-resume-guard-ok"
bash -c "SCREEN_KILL_ON_HANGUP=1 SCREEN_KILL_SCREENRC='${ROOT_DIR}/client/screen-hangup-off.screenrc' SSH_CONNECTION=x . '${LEGACY_AUTO_SCREEN}'; printf '%s\n' bash-legacy-shim-guard-ok"
if command -v zsh >/dev/null 2>&1; then
  zsh -c "SSH_AUTO_RESUME=1 SSH_AUTO_RESUME_TMUX_CONF='${TMUX_CONF}' SSH_AUTO_RESUME_SCREENRC='${SCREENRC}' SSH_CONNECTION=x . '${AUTO_RESUME}'; printf '%s\n' zsh-auto-resume-guard-ok"
fi

tmp_fake_bin="$(mktemp -d)"
tmp_fake_state="$(mktemp)"
cat > "${tmp_fake_bin}/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_TMUX_STATE:?}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -L|-f)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

cmd="${1:-}"
shift || true

session_arg() {
  local value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|-s)
        value="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  printf '%s\n' "$value"
}

case "$cmd" in
  has-session)
    session="$(session_arg "$@")"
    grep -q "^${session}|" "$state"
    ;;
  display-message)
    session="$(session_arg "$@")"
    awk -F'|' -v session="$session" '$1 == session { print $2; found = 1 } END { exit found ? 0 : 1 }' "$state"
    ;;
  list-sessions)
    awk -F'|' '{ printf "%s|%s|1\n", $1, $2 }' "$state"
    ;;
  *)
    exit 2
    ;;
esac
FAKE_TMUX
chmod +x "${tmp_fake_bin}/tmux"

printf '%s\n' 'main|1' 'ip-100_101_137_20-1|0' > "$tmp_fake_state"
PATH="${tmp_fake_bin}:$PATH" FAKE_TMUX_STATE="$tmp_fake_state" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
  . "$AUTO_RESUME"
  _ssh_auto_resume_socket_name=ssh-resume-test
  _ssh_auto_resume_session_base=ip-100_101_137_20
  _ssh_auto_resume_reservation_dir="$(mktemp -d)"
  SSH_AUTO_RESUME_MAX_SLOTS=4
  _ssh_auto_resume_select_tmux
  [[ "$_ssh_auto_resume_selected" == "ip-100_101_137_20-1" ]]
  [[ "$_ssh_auto_resume_selected_slot" == "1" ]]
'

PATH="${tmp_fake_bin}:$PATH" FAKE_TMUX_STATE="$tmp_fake_state" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
  . "$AUTO_RESUME"
  _ssh_auto_resume_socket_name=ssh-resume-test
  _ssh_auto_resume_session_base=ip-100_101_137_20
  _ssh_auto_resume_reservation_dir="$(mktemp -d)"
  printf "%s\n" "$$" > "$_ssh_auto_resume_reservation_dir/tmux-ip-100_101_137_20-1.pid"
  SSH_AUTO_RESUME_MAX_SLOTS=4
  _ssh_auto_resume_select_tmux
  [[ "$_ssh_auto_resume_selected" == "ip-100_101_137_20-2" ]]
  [[ "$_ssh_auto_resume_selected_slot" == "2" ]]
'

AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
  . "$AUTO_RESUME"
  tmp_lock_parent="$(mktemp -d)"
  _ssh_auto_resume_lock_dir="${tmp_lock_parent}/slot.lock"
  mkdir "$_ssh_auto_resume_lock_dir"
  printf "%s\n" 999999999 > "${_ssh_auto_resume_lock_dir}/pid"
  _ssh_auto_resume_lock
  [[ -f "${_ssh_auto_resume_lock_dir}/pid" ]]
  _ssh_auto_resume_unlock
  [[ ! -e "$_ssh_auto_resume_lock_dir" ]]
'

tmp_fake_screen_bin="$(mktemp -d)"
cat > "${tmp_fake_screen_bin}/screen" <<'FAKE_SCREEN'
#!/usr/bin/env bash
cat <<'SCREEN_LS'
There are screens on:
	123.ip-100_101_137_20-10	(Attached)
	456.ip-100_101_137_20-1	(Detached)
SCREEN_LS
FAKE_SCREEN
chmod +x "${tmp_fake_screen_bin}/screen"
PATH="${tmp_fake_screen_bin}:$PATH" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
  . "$AUTO_RESUME"
  [[ "$(_ssh_auto_resume_screen_state ip-100_101_137_20-1)" == "detached" ]]
'

tmp_dep_bin="$(mktemp -d)"
tmp_dep_log="$(mktemp)"
ln -s /usr/bin/dirname "${tmp_dep_bin}/dirname"
cat > "${tmp_dep_bin}/sudo" <<'FAKE_SUDO'
#!/bin/sh
exec "$@"
FAKE_SUDO
cat > "${tmp_dep_bin}/pacman" <<FAKE_PACMAN
#!/bin/sh
printf '%s\n' "\$*" > "${tmp_dep_log}"
FAKE_PACMAN
chmod +x "${tmp_dep_bin}/sudo" "${tmp_dep_bin}/pacman"
printf 'YES\n' | PATH="$tmp_dep_bin" /usr/bin/bash "$ROOT_INSTALL" deps
grep -q -- '-S --needed tmux screen' "$tmp_dep_log"

if SSH_CONNECTION='100.101.137.20 55555 100.101.137.1 22' SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$ROOT_INSTALL" doctor >/tmp/ssh-auto-resume-doctor.out 2>&1; then
  echo "doctor unexpectedly succeeded outside managed multiplexer" >&2
  cat /tmp/ssh-auto-resume-doctor.out >&2
  exit 1
fi
grep -q 'doctor: not active for this login' /tmp/ssh-auto-resume-doctor.out

tmp_home="$(mktemp -d)"
HOME="$tmp_home" "$CLIENT_INSTALL" apply
HOME="$tmp_home" "$CLIENT_INSTALL" apply
HOME="$tmp_home" "$CLIENT_INSTALL" status
HOME="$tmp_home" "$CLIENT_INSTALL" sessions
grep -q 'auto-resume.sh' "$tmp_home/.bash_profile"
grep -q 'auto-resume.sh' "$tmp_home/.zshrc"
HOME="$tmp_home" "$CLIENT_INSTALL" rollback
[[ ! -e "$tmp_home/.bash_profile" ]]
[[ ! -e "$tmp_home/.zshrc" ]]

if command -v tmux >/dev/null 2>&1; then
  tmp_service_home="$(mktemp -d)"
  HOME="$tmp_service_home" SSH_AUTO_RESUME_SKIP_SYSTEMD=1 "$CLIENT_INSTALL" service-install
  grep -q 'SSH auto-resume tmux keepalive' "$tmp_service_home/.config/systemd/user/ssh-auto-resume.service"
  grep -q '__ssh_auto_resume_keepalive' "$tmp_service_home/.config/systemd/user/ssh-auto-resume.service"
  HOME="$tmp_service_home" SSH_AUTO_RESUME_SKIP_SYSTEMD=1 "$CLIENT_INSTALL" service-status
  HOME="$tmp_service_home" SSH_AUTO_RESUME_SKIP_SYSTEMD=1 "$CLIENT_INSTALL" service-rollback
  [[ ! -e "$tmp_service_home/.config/systemd/user/ssh-auto-resume.service" ]]
fi

tmp_home_existing="$(mktemp -d)"
printf '%s\n' 'export EXISTING_PROFILE_VALUE=1' > "$tmp_home_existing/.profile"
HOME="$tmp_home_existing" "$CLIENT_INSTALL" apply
grep -q 'auto-resume.sh' "$tmp_home_existing/.profile"
[[ ! -e "$tmp_home_existing/.bash_profile" ]]
HOME="$tmp_home_existing" "$CLIENT_INSTALL" rollback
grep -q '^export EXISTING_PROFILE_VALUE=1$' "$tmp_home_existing/.profile"
! grep -q 'scoped-screen-autodetach-off' "$tmp_home_existing/.profile"
! grep -q 'ssh-auto-resume-session' "$tmp_home_existing/.profile"

tmp_conf_dir="$(mktemp -d)"
tmp_conf="${tmp_conf_dir}/sshd_config"
printf 'Port 22\nPasswordAuthentication no\n' > "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ip 100.101.137.15
SSHD_CONFIG_FILE="$tmp_conf" "$SERVER_INSTALL" status
grep -q '^Match Address 100.101.137.15$' "$tmp_conf"
grep -q '^    SetEnv SSH_AUTO_RESUME=1$' "$tmp_conf"
! grep -q 'Host ipad174' "$tmp_conf"
! grep -q 'TCPKeepAlive' "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ip 100.101.137.15 --ip 100.101.137.16
grep -q '^Match Address 100.101.137.15,100.101.137.16$' "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ips 100.101.137.15,100.101.137.16
grep -q '^Match Address 100.101.137.15,100.101.137.16$' "$tmp_conf"

detected="$(SSH_CONNECTION='100.101.137.17 55555 100.101.137.1 22' "$SERVER_INSTALL" detect-current)"
[[ "$detected" == "100.101.137.17" ]]

printf 'NO\n' | SSH_CONNECTION='100.101.137.19 55555 100.101.137.1 22' SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL"
! grep -q '100.101.137.19' "$tmp_conf"

printf 'YES\n' | SSH_CONNECTION='100.101.137.18 55555 100.101.137.1 22' SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL"
grep -q '^Match Address 100.101.137.15,100.101.137.16,100.101.137.18$' "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" add-current --ip 100.101.137.17
grep -q '^Match Address 100.101.137.15,100.101.137.16,100.101.137.18,100.101.137.17$' "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" add-current --ip 100.101.137.17
grep -q '^Match Address 100.101.137.15,100.101.137.16,100.101.137.18,100.101.137.17$' "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ips 100.101.137.0/24
grep -q '^Match Address 100.101.137.0/24$' "$tmp_conf"

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ip 100.101.137.15 --match-host ipad174.taile7c246.ts.net
grep -q '^Match Address 100.101.137.15 Host ipad174.taile7c246.ts.net$' "$tmp_conf"

if SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ip 999.1.1.1 >/dev/null 2>&1; then
  echo "invalid IP was accepted" >&2
  exit 1
fi

if SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ips 100.101.137.0/33 >/dev/null 2>&1; then
  echo "invalid CIDR was accepted" >&2
  exit 1
fi

SSHD_CONFIG_FILE="$tmp_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" rollback
! grep -q 'ssh-auto-resume' "$tmp_conf"
! grep -q 'ssh-screen-disconnect-kill' "$tmp_conf"

tmp_root_home="$(mktemp -d)"
tmp_root_conf_dir="$(mktemp -d)"
tmp_root_conf="${tmp_root_conf_dir}/sshd_config"
printf 'Port 22\nPasswordAuthentication no\n' > "$tmp_root_conf"
printf 'YES\n' | HOME="$tmp_root_home" SSH_CONNECTION='100.101.137.20 55555 100.101.137.1 22' SSHD_CONFIG_FILE="$tmp_root_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$ROOT_INSTALL"
grep -q '^Match Address 100.101.137.20$' "$tmp_root_conf"
grep -q '^    SetEnv SSH_AUTO_RESUME=1$' "$tmp_root_conf"
grep -q 'auto-resume.sh' "$tmp_root_home/.bash_profile"
grep -q 'auto-resume.sh' "$tmp_root_home/.zshrc"
HOME="$tmp_root_home" SSH_CONNECTION='100.101.137.20 55555 100.101.137.1 22' SSHD_CONFIG_FILE="$tmp_root_conf" "$ROOT_INSTALL" status
HOME="$tmp_root_home" SSHD_CONFIG_FILE="$tmp_root_conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 "$ROOT_INSTALL" rollback
! grep -q 'ssh-auto-resume' "$tmp_root_conf"
! grep -q 'ssh-screen-disconnect-kill' "$tmp_root_conf"
[[ ! -e "$tmp_root_home/.bash_profile" ]]
[[ ! -e "$tmp_root_home/.zshrc" ]]

if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
  tmp_real_sshd="$(mktemp -d)"
  tmp_key="${tmp_real_sshd}/host_ed25519"
  tmp_real_conf="${tmp_real_sshd}/sshd_config"
  ssh-keygen -q -t ed25519 -N '' -f "$tmp_key"
  printf 'Port 2222\nHostKey %s\nPasswordAuthentication no\n' "$tmp_key" > "$tmp_real_conf"
  SSHD_CONFIG_FILE="$tmp_real_conf" SSH_SCREEN_KILL_NO_RELOAD=1 "$SERVER_INSTALL" apply --ips 100.101.137.15,100.101.138.0/24
fi

echo "smoke: ok"
