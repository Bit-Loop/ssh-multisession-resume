# This file is sourced from interactive shell profiles for matched SSH sessions.
# shellcheck shell=bash
# Keep it POSIX-ish so both bash and zsh can source it safely.

_ssh_auto_resume_main() {
  _ssh_auto_resume_sanitize() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
  }

  _ssh_auto_resume_source() {
    if [ -n "${SSH_CONNECTION:-}" ]; then
      printf '%s' "${SSH_CONNECTION%% *}"
    elif [ -n "${SSH_CLIENT:-}" ]; then
      printf '%s' "${SSH_CLIENT%% *}"
    else
      printf '%s' "unknown"
    fi
  }

  _ssh_auto_resume_runtime_dir() {
    _ssh_auto_resume_tmp_uid=""
    _ssh_auto_resume_tmp_dir=""

    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}" ]; then
      printf '%s' "$XDG_RUNTIME_DIR"
    else
      _ssh_auto_resume_tmp_uid="$(id -u 2>/dev/null || printf '%s' "$_ssh_auto_resume_user")"
      _ssh_auto_resume_tmp_dir="/tmp/ssh-auto-resume-${_ssh_auto_resume_tmp_uid}"
      if [ -e "$_ssh_auto_resume_tmp_dir" ] && { [ ! -d "$_ssh_auto_resume_tmp_dir" ] || [ ! -O "$_ssh_auto_resume_tmp_dir" ]; }; then
        return 1
      fi
      mkdir -p "$_ssh_auto_resume_tmp_dir" 2>/dev/null || return 1
      [ -O "$_ssh_auto_resume_tmp_dir" ] || return 1
      chmod 700 "$_ssh_auto_resume_tmp_dir" 2>/dev/null || return 1
      printf '%s' "$_ssh_auto_resume_tmp_dir"
    fi
  }

  _ssh_auto_resume_lock() {
    _ssh_auto_resume_wait=0
    _ssh_auto_resume_lock_pid=""
    _ssh_auto_resume_lock_pid_file="${_ssh_auto_resume_lock_dir}/pid"

    while ! mkdir "$_ssh_auto_resume_lock_dir" 2>/dev/null; do
      if [ -f "$_ssh_auto_resume_lock_pid_file" ]; then
        IFS= read -r _ssh_auto_resume_lock_pid < "$_ssh_auto_resume_lock_pid_file" || true
        if [ -z "$_ssh_auto_resume_lock_pid" ] || ! kill -0 "$_ssh_auto_resume_lock_pid" 2>/dev/null; then
          rm -f "$_ssh_auto_resume_lock_pid_file"
          rmdir "$_ssh_auto_resume_lock_dir" 2>/dev/null || true
          _ssh_auto_resume_wait=0
          continue
        fi
      fi

      _ssh_auto_resume_wait=$((_ssh_auto_resume_wait + 1))
      if [ "$_ssh_auto_resume_wait" -gt 50 ]; then
        printf '%s\n' "Timed out waiting for SSH auto-resume slot lock." >&2
        return 1
      fi
      sleep 0.1
    done

    printf '%s\n' "$$" > "$_ssh_auto_resume_lock_pid_file"
  }

  _ssh_auto_resume_unlock() {
    if [ -n "${_ssh_auto_resume_lock_dir:-}" ]; then
      rm -f "${_ssh_auto_resume_lock_dir}/pid" 2>/dev/null || true
      rmdir "$_ssh_auto_resume_lock_dir" 2>/dev/null || true
    fi
  }

  _ssh_auto_resume_reservation_path() {
    printf '%s/%s.pid' "$_ssh_auto_resume_reservation_dir" "$1"
  }

  _ssh_auto_resume_reserved() {
    _ssh_auto_resume_res_file="$(_ssh_auto_resume_reservation_path "$1")"
    _ssh_auto_resume_res_pid=""

    if [ ! -f "$_ssh_auto_resume_res_file" ]; then
      return 1
    fi

    IFS= read -r _ssh_auto_resume_res_pid < "$_ssh_auto_resume_res_file" || true
    if [ -n "$_ssh_auto_resume_res_pid" ] && kill -0 "$_ssh_auto_resume_res_pid" 2>/dev/null; then
      return 0
    fi

    rm -f "$_ssh_auto_resume_res_file"
    return 1
  }

  _ssh_auto_resume_reserve() {
    _ssh_auto_resume_reservation="$(_ssh_auto_resume_reservation_path "$1")"
    printf '%s\n' "$$" > "$_ssh_auto_resume_reservation"
    trap '_ssh_auto_resume_cleanup' EXIT HUP INT TERM
  }

  _ssh_auto_resume_cleanup() {
    if [ -n "${_ssh_auto_resume_reservation:-}" ]; then
      rm -f "$_ssh_auto_resume_reservation"
    fi
    _ssh_auto_resume_unlock
  }

  _ssh_auto_resume_tmux_attached() {
    tmux -L "$_ssh_auto_resume_socket_name" display-message -p -t "$1" '#{session_attached}' 2>/dev/null || printf '%s\n' 0
  }

  _ssh_auto_resume_select_tmux() {
    _ssh_auto_resume_slot=0
    _ssh_auto_resume_max="${SSH_AUTO_RESUME_MAX_SLOTS:-64}"

    while [ "$_ssh_auto_resume_slot" -lt "$_ssh_auto_resume_max" ]; do
      if [ "$_ssh_auto_resume_slot" -eq 0 ] && tmux -L "$_ssh_auto_resume_socket_name" has-session -t main 2>/dev/null; then
        _ssh_auto_resume_candidate="main"
      else
        _ssh_auto_resume_candidate="${_ssh_auto_resume_session_base}-${_ssh_auto_resume_slot}"
      fi

      if ! _ssh_auto_resume_reserved "tmux-${_ssh_auto_resume_candidate}"; then
        if tmux -L "$_ssh_auto_resume_socket_name" has-session -t "$_ssh_auto_resume_candidate" 2>/dev/null; then
          _ssh_auto_resume_attached="$(_ssh_auto_resume_tmux_attached "$_ssh_auto_resume_candidate")"
          if [ "${_ssh_auto_resume_attached:-0}" = "0" ]; then
            _ssh_auto_resume_selected="$_ssh_auto_resume_candidate"
            _ssh_auto_resume_selected_slot="$_ssh_auto_resume_slot"
            return 0
          fi
        else
          _ssh_auto_resume_selected="$_ssh_auto_resume_candidate"
          _ssh_auto_resume_selected_slot="$_ssh_auto_resume_slot"
          return 0
        fi
      fi

      _ssh_auto_resume_slot=$((_ssh_auto_resume_slot + 1))
    done

    printf '%s\n' "No free SSH auto-resume tmux slot found." >&2
    return 1
  }

  _ssh_auto_resume_screen_state() {
    screen -ls 2>/dev/null | awk -v name="$1" '
      {
        session = $1
        sub(/^[0-9]+\./, "", session)
      }
      session == name {
        if ($0 ~ /\(Attached\)/) {
          print "attached"
          found = 1
          exit
        }
        if ($0 ~ /\(Detached\)/) {
          print "detached"
          found = 1
          exit
        }
      }
      END {
        if (!found) {
          print "missing"
        }
      }
    '
  }

  _ssh_auto_resume_select_screen() {
    _ssh_auto_resume_slot=0
    _ssh_auto_resume_max="${SSH_AUTO_RESUME_MAX_SLOTS:-64}"

    while [ "$_ssh_auto_resume_slot" -lt "$_ssh_auto_resume_max" ]; do
      if [ "$_ssh_auto_resume_slot" -eq 0 ] && [ "$(_ssh_auto_resume_screen_state "$_ssh_auto_resume_socket_name")" != "missing" ]; then
        _ssh_auto_resume_candidate="$_ssh_auto_resume_socket_name"
      else
        _ssh_auto_resume_candidate="${_ssh_auto_resume_session_base}-${_ssh_auto_resume_slot}"
      fi

      if ! _ssh_auto_resume_reserved "screen-${_ssh_auto_resume_candidate}"; then
        _ssh_auto_resume_state="$(_ssh_auto_resume_screen_state "$_ssh_auto_resume_candidate")"
        case "$_ssh_auto_resume_state" in
          missing|detached)
            _ssh_auto_resume_selected="$_ssh_auto_resume_candidate"
            _ssh_auto_resume_selected_slot="$_ssh_auto_resume_slot"
            return 0
            ;;
        esac
      fi

      _ssh_auto_resume_slot=$((_ssh_auto_resume_slot + 1))
    done

    printf '%s\n' "No free SSH auto-resume screen slot found." >&2
    return 1
  }

  _ssh_auto_resume_run_tmux() {
    _ssh_auto_resume_status=0
    _ssh_auto_resume_unlock
    if [ -n "${SSH_AUTO_RESUME_TMUX_CONF:-}" ] && [ -r "$SSH_AUTO_RESUME_TMUX_CONF" ]; then
      tmux -L "$_ssh_auto_resume_socket_name" -f "$SSH_AUTO_RESUME_TMUX_CONF" new-session -A -s "$_ssh_auto_resume_selected"
      _ssh_auto_resume_status=$?
    else
      tmux -L "$_ssh_auto_resume_socket_name" new-session -A -s "$_ssh_auto_resume_selected"
      _ssh_auto_resume_status=$?
    fi
    _ssh_auto_resume_cleanup
    exit "$_ssh_auto_resume_status"
  }

  _ssh_auto_resume_run_screen() {
    _ssh_auto_resume_status=0
    _ssh_auto_resume_screen_args=""
    _ssh_auto_resume_unlock
    if [ -n "${SSH_AUTO_RESUME_SCREENRC:-}" ] && [ -r "$SSH_AUTO_RESUME_SCREENRC" ]; then
      _ssh_auto_resume_screen_args="-c $SSH_AUTO_RESUME_SCREENRC"
    fi

    if [ "$(_ssh_auto_resume_screen_state "$_ssh_auto_resume_selected")" = "detached" ]; then
      if [ -n "$_ssh_auto_resume_screen_args" ]; then
        screen -c "$SSH_AUTO_RESUME_SCREENRC" -r "$_ssh_auto_resume_selected"
      else
        screen -r "$_ssh_auto_resume_selected"
      fi
      _ssh_auto_resume_status=$?
    else
      if [ -n "$_ssh_auto_resume_screen_args" ]; then
        screen -c "$SSH_AUTO_RESUME_SCREENRC" -S "$_ssh_auto_resume_selected"
      else
        screen -S "$_ssh_auto_resume_selected"
      fi
      _ssh_auto_resume_status=$?
    fi
    _ssh_auto_resume_cleanup
    exit "$_ssh_auto_resume_status"
  }

  if [ "${SSH_AUTO_RESUME:-}" != "1" ] && [ "${SCREEN_KILL_ON_HANGUP:-}" != "1" ]; then
    return 0
  fi

  case "$-" in
    *i*) ;;
    *) return 0 ;;
  esac

  [ -t 0 ] && [ -t 1 ] || return 0
  [ -z "${TMUX:-}${STY:-}" ] || return 0
  [ -z "${SSH_ORIGINAL_COMMAND:-}" ] || return 0
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 0

  _ssh_auto_resume_user="$(printf '%s' "${USER:-user}" | tr -c 'A-Za-z0-9_.-' '_')"
  _ssh_auto_resume_prefix="${SSH_AUTO_RESUME_SESSION_PREFIX:-ssh-resume}"
  _ssh_auto_resume_socket_name="${_ssh_auto_resume_prefix}-${_ssh_auto_resume_user}"
  _ssh_auto_resume_source="$(_ssh_auto_resume_sanitize "$(_ssh_auto_resume_source)")"
  _ssh_auto_resume_session_base="ip-${_ssh_auto_resume_source}"
  _ssh_auto_resume_runtime="$(_ssh_auto_resume_runtime_dir)" || return 0
  _ssh_auto_resume_lock_dir="${_ssh_auto_resume_runtime}/${_ssh_auto_resume_socket_name}.slot.lock"
  _ssh_auto_resume_reservation_dir="${_ssh_auto_resume_runtime}/${_ssh_auto_resume_socket_name}.reservations"
  _ssh_auto_resume_reservation=""

  mkdir -p "$_ssh_auto_resume_reservation_dir" 2>/dev/null || return 0

  if command -v tmux >/dev/null 2>&1; then
    _ssh_auto_resume_lock || return 0
    if _ssh_auto_resume_select_tmux; then
      _ssh_auto_resume_reserve "tmux-${_ssh_auto_resume_selected}"
      _ssh_auto_resume_run_tmux
    fi
    _ssh_auto_resume_cleanup
    return 0
  fi

  if command -v screen >/dev/null 2>&1; then
    _ssh_auto_resume_lock || return 0
    if _ssh_auto_resume_select_screen; then
      _ssh_auto_resume_reserve "screen-${_ssh_auto_resume_selected}"
      _ssh_auto_resume_run_screen
    fi
    _ssh_auto_resume_cleanup
    return 0
  fi

  printf '%s\n' "tmux or screen is required for this matched SSH session but neither was found." >&2
}

_ssh_auto_resume_main
if [ "${SSH_AUTO_RESUME_KEEP_FUNCTIONS:-0}" != "1" ]; then
  unset -f \
    _ssh_auto_resume_main \
    _ssh_auto_resume_sanitize \
    _ssh_auto_resume_source \
    _ssh_auto_resume_runtime_dir \
    _ssh_auto_resume_lock \
    _ssh_auto_resume_unlock \
    _ssh_auto_resume_reservation_path \
    _ssh_auto_resume_reserved \
    _ssh_auto_resume_reserve \
    _ssh_auto_resume_cleanup \
    _ssh_auto_resume_tmux_attached \
    _ssh_auto_resume_select_tmux \
    _ssh_auto_resume_screen_state \
    _ssh_auto_resume_select_screen \
    _ssh_auto_resume_run_tmux \
    _ssh_auto_resume_run_screen 2>/dev/null || true
fi
