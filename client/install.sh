#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AUTO_RESUME="${SCRIPT_DIR}/auto-resume.sh"
TMUX_CONF="${SCRIPT_DIR}/tmux-auto-resume.conf"
SCREENRC="${SCRIPT_DIR}/screen-auto-resume.screenrc"
SERVICE_NAME="ssh-auto-resume.service"
KEEPALIVE_SESSION="__ssh_auto_resume_keepalive"

BLOCK_START='### begin ssh-auto-resume-session'
BLOCK_END='### end ssh-auto-resume-session'
LEGACY_BLOCK_START='### begin scoped-screen-autodetach-off'
LEGACY_BLOCK_END='### end scoped-screen-autodetach-off'
SNAP_EXT=".screen-hangup-snapshot"
CREATED_EXT=".screen-hangup-created"

usage() {
  local cmd="${0:-./client/install.sh}"

  cat <<USAGE
Usage:
  ${cmd} apply
  ${cmd} rollback
  ${cmd} status
  ${cmd} sessions
  ${cmd} service-install
  ${cmd} service-status
  ${cmd} service-rollback

Notes:
  Bash login shells are hooked through .bash_profile, .bash_login, or .profile.
  Zsh interactive shells are hooked through .zshrc.
USAGE
}

profile_block() {
  cat <<EOF_BLOCK
${BLOCK_START}
if [ "\${SSH_AUTO_RESUME:-}" = "1" ] || [ "\${SCREEN_KILL_ON_HANGUP:-}" = "1" ]; then
  SSH_AUTO_RESUME_HELPER="${AUTO_RESUME}"
  SSH_AUTO_RESUME_TMUX_CONF="${TMUX_CONF}"
  SSH_AUTO_RESUME_SCREENRC="${SCREENRC}"
  SSH_AUTO_RESUME_SESSION_PREFIX="ssh-resume"
  if [ -r "${AUTO_RESUME}" ]; then
    . "${AUTO_RESUME}"
  fi
fi
${BLOCK_END}
EOF_BLOCK
}

bash_login_profile() {
  if [[ -f "${HOME}/.bash_profile" ]]; then
    printf '%s\n' "${HOME}/.bash_profile"
  elif [[ -f "${HOME}/.bash_login" ]]; then
    printf '%s\n' "${HOME}/.bash_login"
  elif [[ -f "${HOME}/.profile" ]]; then
    printf '%s\n' "${HOME}/.profile"
  else
    printf '%s\n' "${HOME}/.bash_profile"
  fi
}

apply_profiles() {
  printf '%s\n' "$(bash_login_profile)" "${HOME}/.zshrc"
}

rollback_profiles() {
  printf '%s\n' \
    "${HOME}/.bash_profile" \
    "${HOME}/.bash_login" \
    "${HOME}/.profile" \
    "${HOME}/.zshrc" \
    "${HOME}/.bashrc"
}

has_scoped_block() {
  local file="$1"
  [[ -f "$file" ]] && {
    grep -qF "$BLOCK_START" "$file" || grep -qF "$LEGACY_BLOCK_START" "$file"
  }
}

ensure_profile() {
  local file="$1"
  local created="${file}${CREATED_EXT}"

  if [[ ! -f "$file" ]]; then
    touch "$file"
    chmod 600 "$file"
    touch "$created"
    echo "Created ${file} for patching."
  fi
}

remove_block_inline() {
  local file="$1"
  local tmp

  tmp="$(mktemp)"
  awk \
    -v start="$BLOCK_START" \
    -v end="$BLOCK_END" \
    -v legacy_start="$LEGACY_BLOCK_START" \
    -v legacy_end="$LEGACY_BLOCK_END" '
    $0 == start || $0 == legacy_start { skip = 1; next }
    $0 == end || $0 == legacy_end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

maybe_remove_created_profile() {
  local file="$1"
  local created="${file}${CREATED_EXT}"

  if [[ ! -f "$created" ]]; then
    return 0
  fi

  if [[ ! -s "$file" ]] || ! grep -q '[^[:space:]]' "$file"; then
    rm -f "$file"
    echo "Removed empty installer-created profile ${file}."
  else
    echo "Left installer-created profile ${file} because it now contains other content."
  fi

  rm -f "$created"
}

install_file() {
  local file="$1"
  local backup="${file}${SNAP_EXT}"
  local created="${file}${CREATED_EXT}"
  local had_block=0

  ensure_profile "$file"

  if has_scoped_block "$file"; then
    had_block=1
    remove_block_inline "$file"
    echo "Updated existing hook in ${file}"
  fi

  if [[ "$had_block" == "0" && ! -f "$created" && ! -f "$backup" ]]; then
    cp "$file" "$backup"
  fi

  {
    printf '\n'
    profile_block
  } >> "$file"
  echo "Patched ${file}"
}

remove_file_block() {
  local file="$1"
  local backup="${file}${SNAP_EXT}"
  local created="${file}${CREATED_EXT}"

  if [[ ! -f "$file" && ! -f "$backup" && ! -f "$created" ]]; then
    return 0
  fi

  if [[ -f "$backup" ]]; then
    mv "$backup" "$file"
    rm -f "$created"
    echo "Restored ${file} from ${backup}"
    return 0
  fi

  if has_scoped_block "$file"; then
    remove_block_inline "$file"
    echo "Removed scoped block from ${file} via inline cleanup."
  else
    echo "No scoped block found in ${file}."
  fi

  maybe_remove_created_profile "$file"
}

profile_status() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "${file}: missing"
    return 0
  fi

  if has_scoped_block "$file"; then
    echo "${file}: installed"
  else
    echo "${file}: not installed"
  fi
}

safe_user() {
  printf '%s' "${USER:-$(id -un)}" | tr -c 'A-Za-z0-9_.-' '_'
}

socket_name() {
  printf 'ssh-resume-%s\n' "$(safe_user)"
}

service_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
}

service_file() {
  printf '%s/%s\n' "$(service_dir)" "$SERVICE_NAME"
}

shell_quote() {
  local value="$1"

  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

describe_slot_name() {
  local name="$1"
  local source="-"
  local slot="-"

  if [[ "$name" == "$KEEPALIVE_SESSION" ]]; then
    printf 'source=- slot=- kind=service'
    return 0
  fi

  if [[ "$name" == "main" ]]; then
    printf 'source=legacy slot=0 kind=session'
    return 0
  fi

  if [[ "$name" =~ ^ip-(.+)-([0-9]+)$ ]]; then
    source="${BASH_REMATCH[1]}"
    slot="${BASH_REMATCH[2]}"
  fi

  printf 'source=%s slot=%s kind=session' "$source" "$slot"
}

cmd_apply() {
  local file

  if [[ ! -r "$AUTO_RESUME" ]]; then
    echo "Missing auto-resume helper: ${AUTO_RESUME}" >&2
    exit 1
  fi

  if [[ ! -r "$TMUX_CONF" ]]; then
    echo "Missing tmux config: ${TMUX_CONF}" >&2
    exit 1
  fi

  if [[ ! -r "$SCREENRC" ]]; then
    echo "Missing fallback screen config: ${SCREENRC}" >&2
    exit 1
  fi

  if ! command -v tmux >/dev/null 2>&1 && ! command -v screen >/dev/null 2>&1; then
    echo "tmux or screen is required but neither was found in PATH." >&2
    exit 1
  fi

  while IFS= read -r file; do
    install_file "$file"
  done < <(apply_profiles)

  echo "Done. Matching interactive SSH logins will auto-resume the managed terminal session."
}

cmd_rollback() {
  local file

  while IFS= read -r file; do
    remove_file_block "$file"
  done < <(rollback_profiles)

  echo "Rollback complete."
}

cmd_status() {
  local file

  echo "apply targets:"
  while IFS= read -r file; do
    profile_status "$file"
  done < <(apply_profiles)

  echo "rollback scan:"
  while IFS= read -r file; do
    case "$file" in
      "$(bash_login_profile)"|"${HOME}/.zshrc")
        ;;
      *)
        if has_scoped_block "$file"; then
          echo "${file}: installed"
        fi
        ;;
    esac
  done < <(rollback_profiles)

  if [[ -x "$AUTO_RESUME" ]]; then
    echo "auto-resume: executable"
  elif [[ -r "$AUTO_RESUME" ]]; then
    echo "auto-resume: readable but not executable"
  else
    echo "auto-resume: missing"
  fi

  if command -v tmux >/dev/null 2>&1; then
    echo "tmux: present"
  else
    echo "tmux: missing"
  fi

  if command -v screen >/dev/null 2>&1; then
    echo "screen fallback: present"
  else
    echo "screen fallback: missing"
  fi

  if [[ -r "$TMUX_CONF" ]]; then
    echo "tmux config: present"
  else
    echo "tmux config: missing"
  fi

  if [[ -r "$SCREENRC" ]]; then
    echo "screen fallback config: present"
  else
    echo "screen fallback config: missing"
  fi

  if [[ -f "$(service_file)" ]]; then
    echo "user service: installed"
  else
    echo "user service: not installed"
  fi
}

cmd_sessions() {
  local socket
  local name attached windows state session_field rest tmux_sessions
  local printed=0

  socket="$(socket_name)"
  echo "managed socket: ${socket}"

  if command -v tmux >/dev/null 2>&1; then
    echo "tmux sessions:"
    tmux_sessions="$(mktemp)"
    if tmux -L "$socket" list-sessions -F '#{session_name}|#{session_attached}|#{session_windows}' > "$tmux_sessions" 2>/dev/null; then
      if [[ -s "$tmux_sessions" ]]; then
        while IFS='|' read -r name attached windows; do
          [[ -n "$name" ]] || continue
          printf '  %s %s attached=%s windows=%s\n' "$(describe_slot_name "$name")" "name=${name}" "${attached:-0}" "${windows:-0}"
        done < "$tmux_sessions"
      else
        echo "  none"
      fi
    else
      echo "  none"
    fi
    rm -f "$tmux_sessions"
  else
    echo "tmux sessions:"
    echo "  tmux: missing"
  fi

  echo "screen sessions:"
  if command -v screen >/dev/null 2>&1; then
    while read -r session_field rest; do
      [[ "${session_field:-}" == *.* ]] || continue
      name="${session_field#*.}"
      [[ "$name" == "$(socket_name)" || "$name" =~ ^ip-(.+)-([0-9]+)$ ]] || continue
      state="unknown"
      [[ "${rest:-}" == *"(Attached)"* ]] && state="attached"
      [[ "${rest:-}" == *"(Detached)"* ]] && state="detached"
      printf '  %s name=%s state=%s\n' "$(describe_slot_name "$name")" "$name" "$state"
      printed=1
    done < <(screen -ls 2>/dev/null || true)
    (( printed == 1 )) || echo "  none"
  else
    echo "  screen fallback: missing"
  fi
}

write_service_file() {
  local socket
  local unit
  local start_cmd
  local stop_cmd

  socket="$(socket_name)"
  unit="$(service_file)"
  mkdir -p "$(dirname "$unit")"

  start_cmd="if ! command -v tmux >/dev/null 2>&1; then exit 0; fi; tmux -L $(shell_quote "$socket") has-session -t $(shell_quote "$KEEPALIVE_SESSION") >/dev/null 2>&1 || tmux -L $(shell_quote "$socket") -f $(shell_quote "$TMUX_CONF") new-session -d -s $(shell_quote "$KEEPALIVE_SESSION") 'while :; do sleep 3600; done'"
  stop_cmd="if command -v tmux >/dev/null 2>&1; then tmux -L $(shell_quote "$socket") kill-session -t $(shell_quote "$KEEPALIVE_SESSION") >/dev/null 2>&1 || true; fi"

  cat > "$unit" <<EOF_UNIT
[Unit]
Description=SSH auto-resume tmux keepalive

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -lc $(shell_quote "$start_cmd")
ExecStop=/bin/sh -lc $(shell_quote "$stop_cmd")

[Install]
WantedBy=default.target
EOF_UNIT

  echo "Installed user service unit: ${unit}"
}

maybe_enable_service() {
  if [[ "${SSH_AUTO_RESUME_SKIP_SYSTEMD:-0}" == "1" ]]; then
    echo "Skipped systemd user enable because SSH_AUTO_RESUME_SKIP_SYSTEMD=1."
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; unit installed but not enabled."
    return 0
  fi

  if systemctl --user daemon-reload && systemctl --user enable --now "$SERVICE_NAME"; then
    echo "Enabled user service: ${SERVICE_NAME}"
  else
    echo "Unit installed, but systemd user enable/start failed for this shell."
    echo "Try later from the target user login: systemctl --user enable --now ${SERVICE_NAME}"
  fi

  if command -v loginctl >/dev/null 2>&1; then
    if loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=no'; then
      echo "For boot startup before login, run: sudo loginctl enable-linger $(id -un)"
    fi
  fi
}

cmd_service_install() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required for the cross-boot user service." >&2
    exit 1
  fi

  if [[ ! -r "$TMUX_CONF" ]]; then
    echo "Missing tmux config: ${TMUX_CONF}" >&2
    exit 1
  fi

  write_service_file
  maybe_enable_service
}

cmd_service_status() {
  local unit
  local enabled="unknown"
  local active="unknown"

  unit="$(service_file)"
  if [[ -f "$unit" ]]; then
    echo "unit: installed (${unit})"
  else
    echo "unit: not installed (${unit})"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    enabled="$(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    active="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
    echo "enabled: ${enabled:-unknown}"
    echo "active: ${active:-unknown}"
  else
    echo "systemctl: missing"
  fi
}

cmd_service_rollback() {
  local unit

  unit="$(service_file)"
  if command -v systemctl >/dev/null 2>&1 && [[ "${SSH_AUTO_RESUME_SKIP_SYSTEMD:-0}" != "1" ]]; then
    systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  if [[ -f "$unit" ]]; then
    rm -f "$unit"
    echo "Removed user service unit: ${unit}"
  else
    echo "No user service unit found: ${unit}"
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ "${SSH_AUTO_RESUME_SKIP_SYSTEMD:-0}" != "1" ]]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

ACTION="$1"
shift

case "$ACTION" in
  apply)
    cmd_apply "$@"
    ;;
  rollback)
    cmd_rollback "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  sessions)
    cmd_sessions "$@"
    ;;
  service-install)
    cmd_service_install "$@"
    ;;
  service-status)
    cmd_service_status "$@"
    ;;
  service-rollback)
    cmd_service_rollback "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
