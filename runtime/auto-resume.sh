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

    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}" ] && [ -w "${XDG_RUNTIME_DIR:-}" ]; then
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
      if [ "$_ssh_auto_resume_wait" -gt "${SSH_AUTO_RESUME_LOCK_RETRIES:-50}" ]; then
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
      _ssh_auto_resume_reservation=""
    fi
    _ssh_auto_resume_unlock
    trap - EXIT HUP INT TERM
  }

  _ssh_auto_resume_tmux_has_exact() {
    _ssh_auto_resume_names=""
    if _ssh_auto_resume_names="$(tmux -L "$_ssh_auto_resume_socket_name" list-sessions -F '#{session_name}' 2>/dev/null)"; then
      printf '%s\n' "$_ssh_auto_resume_names" | cut -d'|' -f1 | grep -Fxq "$1"
      return $?
    fi
    tmux -L "$_ssh_auto_resume_socket_name" has-session -t "$1" 2>/dev/null
  }

  _ssh_auto_resume_tmux_attached() {
    tmux -L "$_ssh_auto_resume_socket_name" display-message -p -t "$1" '#{session_attached}' 2>/dev/null || printf '%s\n' 0
  }

  _ssh_auto_resume_has_term_checker() {
    command -v infocmp >/dev/null 2>&1 || command -v tput >/dev/null 2>&1
  }

  _ssh_auto_resume_term_usable() {
    [ -n "${1:-}" ] && [ "$1" != "dumb" ] || return 1

    if command -v infocmp >/dev/null 2>&1; then
      infocmp "$1" >/dev/null 2>&1
      return $?
    fi

    if command -v tput >/dev/null 2>&1; then
      TERM="$1" tput cols >/dev/null 2>&1
      return $?
    fi

    return 0
  }

  _ssh_auto_resume_prepare_term() {
    if _ssh_auto_resume_term_usable "${TERM:-}"; then
      return 0
    fi

    _ssh_auto_resume_has_term_checker || return 0

    for _ssh_auto_resume_fallback_term in xterm-256color xterm vt100; do
      if _ssh_auto_resume_term_usable "$_ssh_auto_resume_fallback_term"; then
        TERM="$_ssh_auto_resume_fallback_term"
        export TERM
        return 0
      fi
    done

    return 0
  }

  _ssh_auto_resume_select_tmux() {
    if [ "${_ssh_auto_resume_mode:-multi}" = "single" ]; then
      _ssh_auto_resume_selected="${_ssh_auto_resume_session_base}-0"
      _ssh_auto_resume_selected_slot=0
      return 0
    fi

    _ssh_auto_resume_slot=0
    _ssh_auto_resume_max="${SSH_AUTO_RESUME_MAX_SLOTS:-64}"

    while [ "$_ssh_auto_resume_slot" -lt "$_ssh_auto_resume_max" ]; do
      if [ "$_ssh_auto_resume_slot" -eq 0 ] && _ssh_auto_resume_tmux_has_exact main; then
        _ssh_auto_resume_candidate="main"
      else
        _ssh_auto_resume_candidate="${_ssh_auto_resume_session_base}-${_ssh_auto_resume_slot}"
      fi

      if ! _ssh_auto_resume_reserved "tmux-${_ssh_auto_resume_candidate}"; then
        if _ssh_auto_resume_tmux_has_exact "$_ssh_auto_resume_candidate"; then
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
    if [ "${_ssh_auto_resume_mode:-multi}" = "single" ]; then
      _ssh_auto_resume_selected="${_ssh_auto_resume_session_base}-0"
      _ssh_auto_resume_selected_slot=0
      return 0
    fi

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
      if tmux -L "$_ssh_auto_resume_socket_name" list-sessions >/dev/null 2>&1; then
        tmux -L "$_ssh_auto_resume_socket_name" source-file "$SSH_AUTO_RESUME_TMUX_CONF" >/dev/null 2>&1 || true
      fi
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
    _ssh_auto_resume_has_screenrc=0
    _ssh_auto_resume_unlock
    if [ -n "${SSH_AUTO_RESUME_SCREENRC:-}" ] && [ -r "$SSH_AUTO_RESUME_SCREENRC" ]; then
      _ssh_auto_resume_has_screenrc=1
    fi

    if [ "$(_ssh_auto_resume_screen_state "$_ssh_auto_resume_selected")" = "detached" ]; then
      if [ "$_ssh_auto_resume_has_screenrc" = "1" ]; then
        screen -c "$SSH_AUTO_RESUME_SCREENRC" -r "$_ssh_auto_resume_selected"
      else
        screen -r "$_ssh_auto_resume_selected"
      fi
      _ssh_auto_resume_status=$?
    else
      if [ "$_ssh_auto_resume_has_screenrc" = "1" ]; then
        screen -c "$SSH_AUTO_RESUME_SCREENRC" -S "$_ssh_auto_resume_selected"
      else
        screen -S "$_ssh_auto_resume_selected"
      fi
      _ssh_auto_resume_status=$?
    fi
    _ssh_auto_resume_cleanup
    exit "$_ssh_auto_resume_status"
  }

  _ssh_auto_resume_policy_dir() {
    printf '%s/ssh-multisession-resume' "${XDG_CONFIG_HOME:-${HOME:-/}/.config}"
  }

  _ssh_auto_resume_choice_path() {
    printf '%s/choices/%s' "$(_ssh_auto_resume_policy_dir)" "$1"
  }

  _ssh_auto_resume_read_choice() {
    _ssh_auto_resume_choice=""
    _ssh_auto_resume_choice_file="$(_ssh_auto_resume_choice_path "$1")"
    [ -f "$_ssh_auto_resume_choice_file" ] || return 1
    IFS= read -r _ssh_auto_resume_choice < "$_ssh_auto_resume_choice_file" || return 1
    case "$_ssh_auto_resume_choice" in
      single|multi|skip|per-client) return 0 ;;
      *) _ssh_auto_resume_choice=""; return 1 ;;
    esac
  }

  _ssh_auto_resume_save_choice() {
    _ssh_auto_resume_save_dir="$(_ssh_auto_resume_policy_dir)/choices"
    mkdir -p "$_ssh_auto_resume_save_dir" 2>/dev/null || return 1
    chmod 700 "$(_ssh_auto_resume_policy_dir)" 2>/dev/null || true
    printf '%s\n' "$2" > "$(_ssh_auto_resume_choice_path "$1")"
  }

  _ssh_auto_resume_menu_enabled() {
    case "${SSH_AUTO_RESUME_MENU:-}" in
      1|on|yes|true) return 0 ;;
      0|off|no|false) return 1 ;;
      '') ;;
      *) return 1 ;;
    esac

    _ssh_auto_resume_menu_cfg="$(_ssh_auto_resume_policy_dir)/menu"
    [ -r "$_ssh_auto_resume_menu_cfg" ] || return 1
    IFS= read -r _ssh_auto_resume_menu_value < "$_ssh_auto_resume_menu_cfg" || return 1
    case "$_ssh_auto_resume_menu_value" in
      1|on|yes|true) return 0 ;;
      *) return 1 ;;
    esac
  }

  _ssh_auto_resume_menu() {
    _ssh_auto_resume_menu_ip="$1"
    _ssh_auto_resume_choice=""
    _ssh_auto_resume_menu_input=""

    printf '\n'
    printf '  SSH multi-session resume - first connect from %s\n' "$_ssh_auto_resume_menu_ip"
    printf '\n'
    printf '    [1] single      one persistent terminal (shared)\n'
    printf '    [2] shared     global multi-session pool (default)\n'
    printf '    [3] skip       plain shell; do not auto-attach this source\n'
    printf '    [4] per-client separate session pool per source IP\n'
    printf '\n'
    printf '  Choice is remembered. Change later via:\n'
    printf '    ssh-multisession-resume policy set %s <mode>\n' "$_ssh_auto_resume_menu_ip"
    printf '    ssh-multisession-resume policy forget %s\n' "$_ssh_auto_resume_menu_ip"
    printf '\n'

    _ssh_auto_resume_menu_attempts=0
    while [ "$_ssh_auto_resume_menu_attempts" -lt 3 ]; do
      printf 'Select 1/2/3/4 [default 2-shared]: '
      if ! IFS= read -r _ssh_auto_resume_menu_input; then
        printf '\n'
        _ssh_auto_resume_choice="skip"
        return 0
      fi
      case "$_ssh_auto_resume_menu_input" in
        1|single|s|S) _ssh_auto_resume_choice="single"; return 0 ;;
        ''|2|multi|m|M|shared) _ssh_auto_resume_choice="multi"; return 0 ;;
        3|skip|n|N|q|Q) _ssh_auto_resume_choice="skip"; return 0 ;;
        4|per-client|p|P|client) _ssh_auto_resume_choice="per-client"; return 0 ;;
        *) printf '  (enter 1, 2, 3, or 4)\n' ;;
      esac
      _ssh_auto_resume_menu_attempts=$((_ssh_auto_resume_menu_attempts + 1))
    done

    _ssh_auto_resume_choice="skip"
    return 0
  }

  _ssh_auto_resume_find_manager() {
    if [ -n "${SSH_AUTO_RESUME_SESSION_MANAGER:-}" ] && [ -r "${SSH_AUTO_RESUME_SESSION_MANAGER}" ]; then
      printf '%s' "${SSH_AUTO_RESUME_SESSION_MANAGER}"
      return 0
    fi
    for _ssh_auto_resume_ref in "${SSH_AUTO_RESUME_HELPER:-}" "${SSH_AUTO_RESUME_TMUX_CONF:-}" "${SSH_AUTO_RESUME_SCREENRC:-}"; do
      if [ -n "$_ssh_auto_resume_ref" ]; then
        _ssh_auto_resume_cand="$(dirname "$_ssh_auto_resume_ref")/session-manager.sh"
        if [ -r "$_ssh_auto_resume_cand" ]; then
          printf '%s' "$_ssh_auto_resume_cand"
          return 0
        fi
      fi
    done
    return 1
  }

  _ssh_auto_resume_record_connect() {
    if [ -n "${_ssh_auto_resume_mgr:-}" ] && command -v bash >/dev/null 2>&1; then
      SSH_AUTO_RESUME_CLIENT_IP="$_ssh_auto_resume_raw_source" \
        SSH_AUTO_RESUME_SESSION_PREFIX="$_ssh_auto_resume_prefix" \
        TMUX_TMPDIR="$TMUX_TMPDIR" \
        bash "$_ssh_auto_resume_mgr" record-connect "$_ssh_auto_resume_raw_source" "${1:-}" >/dev/null 2>&1 || true
    fi
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
  _ssh_auto_resume_raw_source="$(_ssh_auto_resume_source)"
  _ssh_auto_resume_source="$(_ssh_auto_resume_sanitize "$_ssh_auto_resume_raw_source")"
  _ssh_auto_resume_runtime="$(_ssh_auto_resume_runtime_dir)" || return 0
  if [ -z "${TMUX_TMPDIR:-}" ]; then
    TMUX_TMPDIR="$_ssh_auto_resume_runtime"
    export TMUX_TMPDIR
  fi
  _ssh_auto_resume_lock_dir="${_ssh_auto_resume_runtime}/${_ssh_auto_resume_socket_name}.slot.lock"
  _ssh_auto_resume_reservation_dir="${_ssh_auto_resume_runtime}/${_ssh_auto_resume_socket_name}.reservations"
  _ssh_auto_resume_reservation=""
  _ssh_auto_resume_mgr="$(_ssh_auto_resume_find_manager 2>/dev/null || true)"

  # Explicit override wins; else load saved choice; else the opt-in menu (off
  # by default); else default to multi (shared pool, no prompt).
  if [ -n "${SSH_AUTO_RESUME_MODE:-}" ]; then
    case "$SSH_AUTO_RESUME_MODE" in
      single|multi|skip|per-client) _ssh_auto_resume_mode="$SSH_AUTO_RESUME_MODE" ;;
      *) _ssh_auto_resume_mode="multi" ;;
    esac
  elif _ssh_auto_resume_read_choice "$_ssh_auto_resume_source"; then
    _ssh_auto_resume_mode="$_ssh_auto_resume_choice"
  elif _ssh_auto_resume_menu_enabled; then
    _ssh_auto_resume_menu "$_ssh_auto_resume_source"
    _ssh_auto_resume_mode="$_ssh_auto_resume_choice"
    _ssh_auto_resume_save_choice "$_ssh_auto_resume_source" "$_ssh_auto_resume_mode" || true
  else
    _ssh_auto_resume_mode="multi"
  fi

  if [ "$_ssh_auto_resume_mode" = "per-client" ]; then
    _ssh_auto_resume_session_base="ip-${_ssh_auto_resume_source}"
  else
    _ssh_auto_resume_session_base="${_ssh_auto_resume_prefix}"
  fi

  if [ "$_ssh_auto_resume_mode" = "skip" ]; then
    return 0
  fi

  mkdir -p "$_ssh_auto_resume_reservation_dir" 2>/dev/null || return 0
  _ssh_auto_resume_prepare_term

  if command -v tmux >/dev/null 2>&1; then
    _ssh_auto_resume_pick_action="AUTO"
    _ssh_auto_resume_pick_target=""

    if [ -n "$_ssh_auto_resume_mgr" ] && command -v bash >/dev/null 2>&1; then
      _ssh_auto_resume_pick_file="${_ssh_auto_resume_runtime}/${_ssh_auto_resume_socket_name}.pick.$$"
      : > "$_ssh_auto_resume_pick_file" 2>/dev/null || _ssh_auto_resume_pick_file=""
      if [ -n "$_ssh_auto_resume_pick_file" ]; then
        chmod 600 "$_ssh_auto_resume_pick_file" 2>/dev/null || true
        if SSH_AUTO_RESUME_CLIENT_IP="$_ssh_auto_resume_raw_source" \
             SSH_AUTO_RESUME_SESSION_PREFIX="$_ssh_auto_resume_prefix" \
             TMUX_TMPDIR="$TMUX_TMPDIR" \
             bash "$_ssh_auto_resume_mgr" login-pick \
               --result-file "$_ssh_auto_resume_pick_file" \
               --session-base "$_ssh_auto_resume_session_base" \
               --mode "$_ssh_auto_resume_mode"; then
          _ssh_auto_resume_pick_line=""
          IFS= read -r _ssh_auto_resume_pick_line < "$_ssh_auto_resume_pick_file" || true
          case "$_ssh_auto_resume_pick_line" in
            *\|*)
              _ssh_auto_resume_pick_action="${_ssh_auto_resume_pick_line%%|*}"
              _ssh_auto_resume_pick_target="${_ssh_auto_resume_pick_line#*|}"
              ;;
          esac
        fi
        rm -f "$_ssh_auto_resume_pick_file" 2>/dev/null || true
      fi
    fi

    if [ "$_ssh_auto_resume_pick_action" = "SKIP" ]; then
      _ssh_auto_resume_record_connect ""
      return 0
    fi

    _ssh_auto_resume_lock || return 0

    if [ "$_ssh_auto_resume_pick_action" = "TAKEOVER" ] && [ -n "$_ssh_auto_resume_pick_target" ]; then
      tmux -L "$_ssh_auto_resume_socket_name" detach-client -s "=${_ssh_auto_resume_pick_target}" 2>/dev/null || true
      _ssh_auto_resume_selected="$_ssh_auto_resume_pick_target"
      _ssh_auto_resume_reserve "tmux-${_ssh_auto_resume_selected}"
      _ssh_auto_resume_record_connect "$_ssh_auto_resume_selected"
      _ssh_auto_resume_run_tmux
    elif [ "$_ssh_auto_resume_pick_action" = "ATTACH" ] || [ "$_ssh_auto_resume_pick_action" = "NEW" ]; then
      if [ -n "$_ssh_auto_resume_pick_target" ] && ! _ssh_auto_resume_reserved "tmux-${_ssh_auto_resume_pick_target}"; then
        _ssh_auto_resume_pick_att="$(_ssh_auto_resume_tmux_attached "$_ssh_auto_resume_pick_target")"
        if ! _ssh_auto_resume_tmux_has_exact "$_ssh_auto_resume_pick_target" || [ "${_ssh_auto_resume_pick_att:-0}" = "0" ]; then
          _ssh_auto_resume_selected="$_ssh_auto_resume_pick_target"
          _ssh_auto_resume_reserve "tmux-${_ssh_auto_resume_selected}"
          _ssh_auto_resume_record_connect "$_ssh_auto_resume_selected"
          _ssh_auto_resume_run_tmux
        fi
      fi
    fi

    if _ssh_auto_resume_select_tmux; then
      _ssh_auto_resume_reserve "tmux-${_ssh_auto_resume_selected}"
      _ssh_auto_resume_record_connect "$_ssh_auto_resume_selected"
      _ssh_auto_resume_run_tmux
    fi
    _ssh_auto_resume_cleanup
    return 0
  fi

  if command -v screen >/dev/null 2>&1; then
    _ssh_auto_resume_lock || return 0
    if _ssh_auto_resume_select_screen; then
      _ssh_auto_resume_reserve "screen-${_ssh_auto_resume_selected}"
      _ssh_auto_resume_record_connect "$_ssh_auto_resume_selected"
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
    _ssh_auto_resume_tmux_has_exact \
    _ssh_auto_resume_tmux_attached \
    _ssh_auto_resume_has_term_checker \
    _ssh_auto_resume_term_usable \
    _ssh_auto_resume_prepare_term \
    _ssh_auto_resume_select_tmux \
    _ssh_auto_resume_screen_state \
    _ssh_auto_resume_select_screen \
    _ssh_auto_resume_run_tmux \
    _ssh_auto_resume_run_screen \
    _ssh_auto_resume_policy_dir \
    _ssh_auto_resume_choice_path \
    _ssh_auto_resume_read_choice \
    _ssh_auto_resume_save_choice \
    _ssh_auto_resume_menu_enabled \
    _ssh_auto_resume_menu \
    _ssh_auto_resume_find_manager \
    _ssh_auto_resume_record_connect 2>/dev/null || true
fi
