#!/usr/bin/env bash
# Session inspection, cleared/empty terminal detection, interactive preview
# picker, and IP/session ownership management for ssh-multisession-resume.
#
# Safety invariants:
#   1. Active (attached or PID-reserved) sessions are NEVER previewed
#      (capture-pane is strictly skipped whenever attached > 0 or reserved).
#   2. Destructive actions (clean / drop) NEVER target active/attached sessions,
#      the current $TMUX session, or the __ssh_auto_resume_keepalive session.
#   3. All tmux calls explicitly scope -L <managed-socket>.

set -euo pipefail

SM_KEEPALIVE_SESSION="__ssh_auto_resume_keepalive"

sm_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

sm_sanitize() {
  printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_-' '_'
}

sm_sanitize_label() {
  printf '%s' "${1:-}" | tr -d '\000-\037\177' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-48
}

sm_safe_user() {
  local raw="${USER:-}"
  if [[ -z "$raw" ]]; then
    raw="$(id -un 2>/dev/null || printf 'user')"
  fi
  printf '%s' "$raw" | tr -c 'A-Za-z0-9_.-' '_'
}

sm_session_prefix() {
  printf '%s\n' "${SSH_AUTO_RESUME_SESSION_PREFIX:-ssh-resume}"
}

sm_socket_name() {
  printf '%s-%s\n' "$(sm_session_prefix)" "$(sm_safe_user)"
}

sm_current_ip() {
  if [[ -n "${SSH_AUTO_RESUME_CLIENT_IP:-}" ]]; then
    printf '%s\n' "$SSH_AUTO_RESUME_CLIENT_IP"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    printf '%s\n' "${SSH_CONNECTION%% *}"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    printf '%s\n' "${SSH_CLIENT%% *}"
  else
    printf '%s\n' ""
  fi
}

sm_policy_dir() {
  printf '%s/ssh-multisession-resume\n' "${XDG_CONFIG_HOME:-${HOME:-/}/.config}"
}

sm_choices_dir() {
  printf '%s/choices\n' "$(sm_policy_dir)"
}

sm_ips_dir() {
  printf '%s/ips\n' "$(sm_policy_dir)"
}

sm_sessions_dir() {
  printf '%s/sessions\n' "$(sm_policy_dir)"
}

sm_picker_config_path() {
  printf '%s/picker\n' "$(sm_policy_dir)"
}

sm_ensure_private_dir() {
  local base
  base="$(sm_policy_dir)"
  mkdir -p "$base" "$1"
  chmod 700 "$base" 2>/dev/null || true
}

sm_canonical_runtime_dir() {
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" && -w "${XDG_RUNTIME_DIR}" ]]; then
    printf '%s\n' "$XDG_RUNTIME_DIR"
    return 0
  fi

  local uid tmp_dir
  uid="$(id -u 2>/dev/null || sm_safe_user)"
  tmp_dir="/tmp/ssh-auto-resume-${uid}"
  if [[ -e "$tmp_dir" && ( ! -d "$tmp_dir" || ! -O "$tmp_dir" ) ]]; then
    printf '%s\n' "/tmp"
    return 0
  fi
  if mkdir -p "$tmp_dir" 2>/dev/null && [[ -O "$tmp_dir" ]]; then
    chmod 700 "$tmp_dir" 2>/dev/null || true
    printf '%s\n' "$tmp_dir"
    return 0
  fi

  printf '%s\n' "/tmp"
}

sm_resolve_tmux_tmpdir() {
  if [[ -n "${TMUX_TMPDIR:-}" && -d "${TMUX_TMPDIR}" ]]; then
    printf '%s\n' "$TMUX_TMPDIR"
    return 0
  fi

  local uid socket candidate
  uid="$(id -u 2>/dev/null || printf '0')"
  socket="$(sm_socket_name)"

  local -a candidates=()
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    candidates+=("$XDG_RUNTIME_DIR")
  fi
  candidates+=("/tmp/ssh-auto-resume-${uid}" "/run/user/${uid}" "/tmp")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    if [[ -S "${candidate}/tmux-${uid}/${socket}" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  sm_canonical_runtime_dir
}

sm_ensure_tmux_tmpdir() {
  if [[ -z "${TMUX_TMPDIR:-}" ]]; then
    TMUX_TMPDIR="$(sm_resolve_tmux_tmpdir)"
    export TMUX_TMPDIR
  fi
}

sm_reservation_dir() {
  local rt socket
  rt="$(sm_resolve_tmux_tmpdir)"
  socket="$(sm_socket_name)"
  printf '%s/%s.reservations\n' "$rt" "$socket"
}

sm_is_reserved() {
  local key="$1"
  local file pid=""
  file="$(sm_reservation_dir)/${key}.pid"
  [[ -f "$file" ]] || return 1
  IFS= read -r pid < "$file" || true
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  rm -f "$file" 2>/dev/null || true
  return 1
}

sm_current_tmux_session() {
  if [[ -z "${TMUX:-}" ]]; then
    printf '%s\n' ""
    return 0
  fi
  local socket
  socket="$(sm_socket_name)"
  case "$TMUX" in
    *"/${socket},"*)
      if [[ -n "${TMUX_PANE:-}" ]]; then
        tmux display-message -t "$TMUX_PANE" -p '#S' 2>/dev/null || printf '%s\n' ""
      else
        tmux display-message -p '#S' 2>/dev/null || printf '%s\n' ""
      fi
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

# ============================================================
# Key=Value Metadata Store Helpers
# ============================================================

sm_meta_get() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || return 0
  awk -F'=' -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }' "$file" 2>/dev/null || true
}

sm_meta_write() {
  local file="$1"
  shift
  local dir tmp
  dir="$(dirname "$file")"
  sm_ensure_private_dir "$dir"
  tmp="$(mktemp "${dir}/.meta.XXXXXX")"
  chmod 600 "$tmp" 2>/dev/null || true

  local -a keys=()
  local -a vals=()
  local kv k v idx found

  if [[ -r "$file" ]]; then
    while IFS= read -r kv || [[ -n "$kv" ]]; do
      [[ "$kv" == *=* ]] || continue
      k="${kv%%=*}"
      v="${kv#*=}"
      keys+=("$k")
      vals+=("$v")
    done < "$file"
  fi

  for kv in "$@"; do
    [[ "$kv" == *=* ]] || continue
    k="${kv%%=*}"
    v="${kv#*=}"
    v="$(printf '%s' "$v" | tr -d '\r\n')"
    found=0
    for ((idx = 0; idx < ${#keys[@]}; idx++)); do
      if [[ "${keys[$idx]}" == "$k" ]]; then
        vals[$idx]="$v"
        found=1
        break
      fi
    done
    if (( found == 0 )); then
      keys+=("$k")
      vals+=("$v")
    fi
  done

  for ((idx = 0; idx < ${#keys[@]}; idx++)); do
    if [[ -n "${vals[$idx]}" ]]; then
      printf '%s=%s\n' "${keys[$idx]}" "${vals[$idx]}" >> "$tmp"
    fi
  done

  mv -f "$tmp" "$file"
}

sm_ip_meta_path() {
  local safe
  safe="$(sm_sanitize "$1")"
  printf '%s/%s.meta\n' "$(sm_ips_dir)" "$safe"
}

sm_session_meta_path() {
  local safe
  safe="$(sm_sanitize "$1")"
  printf '%s/%s.meta\n' "$(sm_sessions_dir)" "$safe"
}

sm_valid_policy_mode() {
  case "${1:-}" in
    single|multi|skip|per-client) return 0 ;;
    *) return 1 ;;
  esac
}

sm_ip_policy() {
  local safe choice_file mode=""
  safe="$(sm_sanitize "$1")"
  choice_file="$(sm_choices_dir)/${safe}"
  if [[ -r "$choice_file" ]]; then
    IFS= read -r mode < "$choice_file" || true
    if sm_valid_policy_mode "$mode"; then
      printf '%s\n' "$mode"
      return 0
    fi
  fi
  printf '%s\n' "default"
}

sm_ip_display() {
  local input="${1:-}"
  [[ -n "$input" && "$input" != "-" ]] || { printf '%s' "-"; return 0; }
  local safe meta raw label
  safe="$(sm_sanitize "$input")"
  meta="$(sm_ip_meta_path "$safe")"
  raw="$(sm_meta_get "$meta" raw_ip)"
  label="$(sm_meta_get "$meta" label)"
  [[ -n "$raw" ]] || raw="$input"
  if [[ -n "$label" ]]; then
    printf '%s (%s)' "$raw" "$label"
  else
    printf '%s' "$raw"
  fi
}

sm_format_age() {
  local ts="${1:-}"
  if [[ -z "$ts" || ! "$ts" =~ ^[0-9]+$ || "$ts" -eq 0 ]]; then
    printf '%s' "never"
    return 0
  fi
  local now diff
  now="$(date +%s)"
  diff=$((now - ts))
  if (( diff < 0 )); then diff=0; fi
  if (( diff < 10 )); then
    printf 'just now'
  elif (( diff < 60 )); then
    printf '%ds ago' "$diff"
  elif (( diff < 3600 )); then
    printf '%dm ago' $((diff / 60))
  elif (( diff < 86400 )); then
    printf '%dh ago' $((diff / 3600))
  else
    printf '%dd ago' $((diff / 86400))
  fi
}

sm_record_connect() {
  local raw_ip="${1:-}" session_name="${2:-}"
  [[ -n "$raw_ip" ]] || raw_ip="$(sm_current_ip)"
  [[ -n "$raw_ip" ]] || raw_ip="unknown"

  local safe now ip_meta first_seen count
  safe="$(sm_sanitize "$raw_ip")"
  [[ -n "$safe" ]] || safe="unknown"
  now="$(date +%s)"
  ip_meta="$(sm_ip_meta_path "$safe")"

  first_seen="$(sm_meta_get "$ip_meta" first_seen)"
  [[ -n "$first_seen" ]] || first_seen="$now"
  count="$(sm_meta_get "$ip_meta" connect_count)"
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    count=$((count + 1))
  else
    count=1
  fi

  if [[ -n "$session_name" ]]; then
    sm_meta_write "$ip_meta" \
      "raw_ip=${raw_ip}" \
      "safe_ip=${safe}" \
      "first_seen=${first_seen}" \
      "last_seen=${now}" \
      "connect_count=${count}" \
      "last_session=${session_name}"

    local sess_meta created_ip created_at
    sess_meta="$(sm_session_meta_path "$session_name")"
    created_ip="$(sm_meta_get "$sess_meta" created_ip)"
    [[ -n "$created_ip" ]] || created_ip="$raw_ip"
    created_at="$(sm_meta_get "$sess_meta" created_at)"
    [[ -n "$created_at" ]] || created_at="$now"
    sm_meta_write "$sess_meta" \
      "session=${session_name}" \
      "created_ip=${created_ip}" \
      "last_ip=${raw_ip}" \
      "created_at=${created_at}" \
      "last_attached_at=${now}"
  else
    sm_meta_write "$ip_meta" \
      "raw_ip=${raw_ip}" \
      "safe_ip=${safe}" \
      "first_seen=${first_seen}" \
      "last_seen=${now}" \
      "connect_count=${count}"
  fi
}

# ============================================================
# Cleared / Empty Terminal Detection & Safe Pane Preview
# ============================================================

sm_is_shell_cmd() {
  local cmd="${1:-}"
  cmd="${cmd##*/}"
  cmd="${cmd#-}"
  case "$cmd" in
    bash|zsh|sh|dash|ash|fish|ksh|mksh|tcsh|csh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

sm_pid_has_children() {
  local pid="${1:-}"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1

  if [[ -r "/proc/${pid}/task/${pid}/children" ]]; then
    local children=""
    IFS= read -r children < "/proc/${pid}/task/${pid}/children" || true
    [[ -n "${children//[[:space:]]/}" ]]
    return $?
  fi

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$pid" >/dev/null 2>&1
    return $?
  fi

  if command -v ps >/dev/null 2>&1; then
    ps -eo ppid= 2>/dev/null | awk -v p="$pid" '$1 == p { found=1; exit } END { exit(found ? 0 : 1) }'
    return $?
  fi

  return 1
}

sm_shorten_path() {
  local path="${1:-}"
  local home="${HOME:-}"
  if [[ -n "$home" && "$home" != "/" ]]; then
    if [[ "$path" == "$home" ]]; then
      printf '~'
      return 0
    elif [[ "$path" == "${home}/"* ]]; then
      printf '~/%s' "${path#"${home}/"}"
      return 0
    fi
  fi
  printf '%s' "${path:-~}"
}

sm_sanitize_line() {
  local line="${1:-}" max_cols="${2:-76}"
  local cleaned
  cleaned="$(printf '%s' "$line" | tr '\t' '    ' | tr -d '\000-\037\177')"
  if (( ${#cleaned} > max_cols )); then
    if (( max_cols > 3 )); then
      cleaned="${cleaned:0:$((max_cols - 1))}>"
    else
      cleaned="${cleaned:0:$max_cols}"
    fi
  fi
  printf '%s' "$cleaned"
}

# Classify a tmux session into: active | empty | cleared | open
sm_classify_tmux_session() {
  local socket="$1"
  local session="$2"
  local attached="${3:-0}"
  local windows="${4:-1}"
  local panes="${5:-1}"
  local pane_dead="${6:-0}"
  local pane_pid="${7:-}"
  local pane_cmd="${8:-}"
  local pane_path="${9:-}"
  local history_size="${10:-0}"
  local cursor_y="${11:-0}"

  if [[ "${attached}" != "0" ]] || sm_is_reserved "tmux-${session}"; then
    printf 'active\n'
    return 0
  fi

  if [[ "$pane_dead" == "1" ]]; then
    printf 'empty\n'
    return 0
  fi

  if [[ "$windows" != "1" || "$panes" != "1" ]]; then
    printf 'open\n'
    return 0
  fi

  if ! sm_is_shell_cmd "$pane_cmd"; then
    printf 'open\n'
    return 0
  fi

  if sm_pid_has_children "$pane_pid"; then
    printf 'open\n'
    return 0
  fi

  local captured=""
  if ! captured="$(tmux -L "$socket" capture-pane -p -t "=${session}:" 2>/dev/null)"; then
    printf 'open\n'
    return 0
  fi

  local nonblank=0 line trimmed prev_nonblank="" nonblank_last=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line//[[:space:]]/}"
    if [[ -n "$trimmed" ]]; then
      prev_nonblank="$nonblank_last"
      nonblank_last="$trimmed"
      nonblank=$((nonblank + 1))
    fi
  done <<< "$captured"

  local is_blank_screen=0
  if (( nonblank == 0 )); then
    is_blank_screen=1
  elif (( nonblank <= 2 )) && [[ "$cursor_y" =~ ^[0-9]+$ ]] && (( cursor_y <= 2 )); then
    is_blank_screen=1
  elif (( nonblank <= 3 )) && [[ "${prev_nonblank:-}" == *"clear" ]]; then
    is_blank_screen=1
  fi

  if (( is_blank_screen == 1 )); then
    local norm_home="${HOME:-}"
    norm_home="${norm_home%/}"
    local norm_path="${pane_path%/}"
    if [[ "${history_size:-0}" == "0" ]] && { [[ -z "$norm_path" ]] || [[ "$norm_path" == "$norm_home" ]]; }; then
      printf 'empty\n'
    else
      printf 'cleared\n'
    fi
    return 0
  fi

  printf 'open\n'
}

# Render safe preview lines for a session.
# STRICT INVARIANT: Never calls capture-pane on active/attached sessions.
sm_render_preview_lines() {
  local socket="$1"
  local session="$2"
  local state="$3"
  local max_lines="${4:-10}"
  local max_cols="${5:-72}"
  local pane_cmd="${6:-shell}"
  local pane_path="${7:-~}"
  local history_size="${8:-0}"
  local owner_ip="${9:--}"

  # Live re-check of attachment right before any capture (prevents TOCTOU race).
  local live_attached="0"
  if [[ "$state" == "active" ]] || sm_is_reserved "tmux-${session}"; then
    live_attached="1"
  else
    live_attached="$(tmux -L "$socket" display-message -p -t "=${session}:" '#{session_attached}' 2>/dev/null || printf '1')"
  fi

  if [[ "$live_attached" != "0" ]]; then
    printf '%s\n' "[Active session - live preview disabled]"
    printf '%s\n' ""
    printf '%s\n' "This terminal is currently attached by an active client"
    printf '%s\n' "(last recorded IP: $(sm_ip_display "$owner_ip"))."
    printf '%s\n' ""
    printf '%s\n' "Active sessions are never captured or previewed."
    printf '%s\n' "Press [t] only if your previous connection dropped and"
    printf '%s\n' "you want to detach the old client & transfer it here."
    return 0
  fi

  local short_cwd
  short_cwd="$(sm_shorten_path "$pane_path")"

  if [[ "$state" == "empty" ]]; then
    printf '%s\n' "[Empty terminal - untouched idle ${pane_cmd} in ${short_cwd}]"
    printf '%s\n' "No running commands, child jobs, or scrollback history."
    printf '%s\n' "Press [Enter] to reuse this slot or [c] to clean empty terminals."
    return 0
  fi

  if [[ "$state" == "cleared" ]]; then
    printf '%s\n' "[Cleared terminal - idle ${pane_cmd} in ${short_cwd} (scrollback: ${history_size} lines)]"
    printf '%s\n' "Screen was cleared; no foreground or background child processes."
    printf '%s\n' "Press [Enter] to resume here or [c] to clean cleared/empty terminals."
    return 0
  fi

  local raw=""
  if ! raw="$(tmux -L "$socket" capture-pane -p -t "=${session}:" 2>/dev/null)"; then
    printf '%s\n' "(preview unavailable)"
    return 0
  fi

  local -a all_lines=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    all_lines+=("$line")
  done <<< "$raw"

  # Trim trailing whitespace-only lines so the preview shows actual content.
  local count=${#all_lines[@]}
  while (( count > 0 )); do
    local check="${all_lines[$((count - 1))]}"
    if [[ -z "${check//[[:space:]]/}" ]]; then
      count=$((count - 1))
    else
      break
    fi
  done

  if (( count == 0 )); then
    printf '%s\n' "(screen currently blank - cmd: ${pane_cmd} in ${short_cwd})"
    return 0
  fi

  local start=0
  if (( count > max_lines )); then
    start=$((count - max_lines))
  fi

  local idx
  for ((idx = start; idx < count; idx++)); do
    printf '%s\n' "$(sm_sanitize_line "${all_lines[$idx]}" "$max_cols")"
  done
}

# ============================================================
# Live Session Enumeration & Slot Calculation
# ============================================================

sm_describe_slot_name() {
  local name="$1"
  local socket
  socket="$(sm_socket_name)"

  if [[ "$name" == "$SM_KEEPALIVE_SESSION" ]]; then
    printf 'source=- slot=- kind=service'
    return 0
  fi
  if [[ "$name" == "main" ]]; then
    printf 'source=legacy slot=0 kind=session'
    return 0
  fi
  if [[ "$name" == "$socket" ]]; then
    printf 'source=global slot=0 kind=session'
    return 0
  fi
  if [[ "$name" =~ ^ssh-resume-([0-9]+)$ ]]; then
    printf 'source=global slot=%s kind=session' "${BASH_REMATCH[1]}"
    return 0
  fi
  local prefix
  prefix="$(sm_session_prefix)"
  if [[ "$name" =~ ^${prefix}-([0-9]+)$ ]]; then
    printf 'source=global slot=%s kind=session' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$name" =~ ^ip-(.+)-([0-9]+)$ ]]; then
    printf 'source=%s slot=%s kind=session' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  printf 'source=- slot=- kind=session'
}

sm_session_owner_ip() {
  local name="$1"
  local meta last_ip=""
  meta="$(sm_session_meta_path "$name")"
  last_ip="$(sm_meta_get "$meta" last_ip)"
  if [[ -n "$last_ip" ]]; then
    printf '%s\n' "$last_ip"
    return 0
  fi
  if [[ "$name" =~ ^ip-(.+)-([0-9]+)$ ]]; then
    local src_safe="${BASH_REMATCH[1]}"
    local ip_meta raw=""
    ip_meta="$(sm_ip_meta_path "$src_safe")"
    raw="$(sm_meta_get "$ip_meta" raw_ip)"
    printf '%s\n' "${raw:-$src_safe}"
    return 0
  fi
  printf '%s\n' "-"
}

# Outputs pipe-delimited records for user tmux sessions (excludes keepalive unless $1 == "all"):
# name|attached|windows|panes|state|cmd|cwd|history|owner_ip
sm_collect_tmux_sessions() {
  local include_all="${1:-user}"
  command -v tmux >/dev/null 2>&1 || return 0
  sm_ensure_tmux_tmpdir

  local socket fmt raw="" sorted_raw=""
  socket="$(sm_socket_name)"
  fmt='#{session_name}|#{session_attached}|#{session_windows}|#{window_panes}|#{pane_dead}|#{pane_pid}|#{pane_current_command}|#{pane_current_path}|#{history_size}|#{cursor_y}'
  raw="$(tmux -L "$socket" list-sessions -F "$fmt" 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0

  # Sort naturally by group + numeric slot (0, 1, 2, ..., 9, 10, 11 instead of 0, 1, 10, 2).
  sorted_raw="$(printf '%s\n' "$raw" | awk -F'|' -v ka="$SM_KEEPALIVE_SESSION" '
    NF > 0 {
      name = $1
      grp = 3; prefix = name; num = 0
      if (name == ka) {
        grp = 0; prefix = ""; num = 0
      } else if (name == "main") {
        grp = 1; prefix = "main"; num = 0
      } else if (match(name, /^ip-.+-[0-9]+$/)) {
        grp = 2
        dash = match(name, /-[0-9]+$/)
        prefix = substr(name, 1, dash - 1)
        num = substr(name, dash + 1) + 0
      } else if (match(name, /-[0-9]+$/)) {
        grp = 1
        dash = RSTART
        prefix = substr(name, 1, dash - 1)
        num = substr(name, dash + 1) + 0
      }
      printf "%d\t%s\t%09d\t%s\n", grp, prefix, num, $0
    }
  ' | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3n | cut -f4-)"

  local name attached windows panes dead pid cmd cwd hist cy state owner_ip
  while IFS='|' read -r name attached windows panes dead pid cmd cwd hist cy; do
    [[ -n "$name" ]] || continue
    if [[ "$include_all" != "all" && "$name" == "$SM_KEEPALIVE_SESSION" ]]; then
      continue
    fi
    if [[ "$name" == "$SM_KEEPALIVE_SESSION" ]]; then
      state="service"
      owner_ip="-"
    else
      state="$(sm_classify_tmux_session "$socket" "$name" "${attached:-0}" "${windows:-1}" "${panes:-1}" "${dead:-0}" "${pid:-}" "${cmd:-}" "${cwd:-}" "${hist:-0}" "${cy:-0}")"
      owner_ip="$(sm_session_owner_ip "$name")"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$name" "${attached:-0}" "${windows:-1}" "${panes:-1}" "$state" "${cmd:--}" "${cwd:-~}" "${hist:-0}" "$owner_ip"
  done <<< "$sorted_raw"
}

sm_next_free_tmux_slot() {
  local base="$1"
  sm_ensure_tmux_tmpdir
  local socket max slot candidate
  socket="$(sm_socket_name)"
  max="${SSH_AUTO_RESUME_MAX_SLOTS:-64}"

  local existing=""
  if command -v tmux >/dev/null 2>&1; then
    existing="$(tmux -L "$socket" list-sessions -F '#{session_name}' 2>/dev/null || true)"
  fi

  for ((slot = 0; slot < max; slot++)); do
    candidate="${base}-${slot}"
    if sm_is_reserved "tmux-${candidate}"; then
      continue
    fi
    if [[ -n "$existing" ]] && printf '%s\n' "$existing" | grep -Fxq "$candidate"; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

# ============================================================
# Session CLI Operations: list, clean, drop, transfer
# ============================================================

sm_cmd_sessions_list() {
  sm_ensure_tmux_tmpdir
  local socket
  socket="$(sm_socket_name)"
  echo "managed socket: ${socket}"

  if command -v tmux >/dev/null 2>&1; then
    echo "tmux sessions:"
    local rows=""
    rows="$(sm_collect_tmux_sessions all)"
    if [[ -n "$rows" ]]; then
      local name attached windows panes state cmd cwd hist owner_ip short_cwd ip_disp
      while IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip; do
        [[ -n "$name" ]] || continue
        short_cwd="$(sm_shorten_path "$cwd")"
        ip_disp="$(sm_ip_display "$owner_ip")"
        printf '  %s name=%s attached=%s windows=%s state=%s cmd=%s cwd=%s ip=%s\n' \
          "$(sm_describe_slot_name "$name")" "$name" "$attached" "$windows" "$state" "$cmd" "$short_cwd" "$ip_disp"
      done <<< "$rows"
    else
      echo "  none"
    fi
  else
    echo "tmux sessions:"
    echo "  tmux: missing"
  fi

  echo "screen sessions:"
  local printed=0 session_field rest name state
  if command -v screen >/dev/null 2>&1; then
    while read -r session_field rest; do
      [[ "${session_field:-}" == *.* ]] || continue
      name="${session_field#*.}"
      [[ "$name" == "$socket" || "$name" =~ ^ssh-resume-[0-9]+$ || "$name" =~ ^ip-(.+)-([0-9]+)$ ]] || continue
      state="unknown"
      [[ "${rest:-}" == *"(Attached)"* ]] && state="attached"
      [[ "${rest:-}" == *"(Detached)"* ]] && state="detached"
      printf '  %s name=%s state=%s\n' "$(sm_describe_slot_name "$name")" "$name" "$state"
      printed=1
    done < <(screen -ls 2>/dev/null || true)
    (( printed == 1 )) || echo "  none"
  else
    echo "  screen fallback: missing"
  fi
}

sm_cmd_sessions_clean() {
  local include_cleared=0 dry_run=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cleared|--all|-a) include_cleared=1; shift ;;
      --dry-run|-n)       dry_run=1; shift ;;
      --quiet|-q)         quiet=1; shift ;;
      *) sm_die "Unknown sessions clean flag: $1 (use --cleared, --dry-run)" ;;
    esac
  done

  command -v tmux >/dev/null 2>&1 || {
    (( quiet == 1 )) || echo "tmux is not installed."
    return 0
  }

  sm_ensure_tmux_tmpdir
  local socket current_sess rows="" cleaned=0
  socket="$(sm_socket_name)"
  current_sess="$(sm_current_tmux_session)"
  rows="$(sm_collect_tmux_sessions user)"

  if [[ -z "$rows" ]]; then
    (( quiet == 1 )) || echo "No managed tmux sessions found."
    return 0
  fi

  local name attached windows panes state cmd cwd hist owner_ip live_att
  while IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip; do
    [[ -n "$name" ]] || continue
    [[ "$name" != "$SM_KEEPALIVE_SESSION" ]] || continue
    [[ "$name" != "$current_sess" ]] || continue
    [[ "$attached" == "0" ]] || continue
    [[ "$state" != "active" ]] || continue

    local eligible=0
    if [[ "$state" == "empty" ]]; then
      eligible=1
    elif (( include_cleared == 1 )) && [[ "$state" == "cleared" ]]; then
      eligible=1
    fi
    (( eligible == 1 )) || continue

    # Re-verify detached right before killing.
    live_att="$(tmux -L "$socket" display-message -p -t "=${name}:" '#{session_attached}' 2>/dev/null || printf '1')"
    [[ "$live_att" == "0" ]] || continue
    sm_is_reserved "tmux-${name}" && continue

    if (( dry_run == 1 )); then
      (( quiet == 1 )) || echo "Would clean ${state} session: ${name}"
      cleaned=$((cleaned + 1))
    else
      if tmux -L "$socket" kill-session -t "=${name}" 2>/dev/null; then
        rm -f "$(sm_session_meta_path "$name")" 2>/dev/null || true
        (( quiet == 1 )) || echo "Cleaned ${state} session: ${name}"
        cleaned=$((cleaned + 1))
      fi
    fi
  done <<< "$rows"

  if (( quiet == 0 && cleaned == 0 )); then
    if (( include_cleared == 1 )); then
      echo "No detached empty or cleared sessions to clean."
    else
      echo "No detached empty sessions to clean (pass --cleared to also clean cleared shells)."
    fi
  fi
}

sm_cmd_session_drop() {
  local target="${1:-}"
  [[ -n "$target" ]] || sm_die "Usage: ssh-multisession-resume sessions drop SESSION_NAME"
  [[ "$target" != "$SM_KEEPALIVE_SESSION" ]] || sm_die "Refusing to drop keepalive service session."

  command -v tmux >/dev/null 2>&1 || sm_die "tmux is required."
  sm_ensure_tmux_tmpdir
  local socket current_sess
  socket="$(sm_socket_name)"
  current_sess="$(sm_current_tmux_session)"

  if [[ -n "$current_sess" && "$target" == "$current_sess" ]]; then
    sm_die "Refusing to drop the currently active tmux session (${target})."
  fi

  local existing=""
  existing="$(tmux -L "$socket" list-sessions -F '#{session_name}' 2>/dev/null || true)"
  if ! printf '%s\n' "$existing" | grep -Fxq "$target"; then
    sm_die "Managed tmux session not found: ${target}"
  fi

  local attached="0"
  attached="$(tmux -L "$socket" display-message -p -t "=${target}:" '#{session_attached}' 2>/dev/null || printf '0')"
  if [[ "$attached" != "0" ]] || sm_is_reserved "tmux-${target}"; then
    sm_die "Refusing to drop active/attached session: ${target} (detach it first)."
  fi

  tmux -L "$socket" kill-session -t "=${target}"
  rm -f "$(sm_session_meta_path "$target")" 2>/dev/null || true
  echo "Dropped detached session: ${target}"
}

sm_cmd_session_transfer() {
  local target="" new_ip="" do_detach=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detach|-d) do_detach=1; shift ;;
      --*) sm_die "Unknown flag: $1" ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
        elif [[ -z "$new_ip" ]]; then
          new_ip="$1"
        else
          sm_die "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$target" ]] || sm_die "Usage: ssh-multisession-resume sessions transfer SESSION_NAME [NEW_IP] [--detach]"
  [[ "$target" != "$SM_KEEPALIVE_SESSION" ]] || sm_die "Refusing to transfer keepalive session."
  if [[ -z "$new_ip" ]]; then
    new_ip="$(sm_current_ip)"
    [[ -n "$new_ip" ]] || sm_die "Could not detect current SSH IP; pass NEW_IP explicitly."
  fi

  command -v tmux >/dev/null 2>&1 || sm_die "tmux is required."
  sm_ensure_tmux_tmpdir
  local socket existing=""
  socket="$(sm_socket_name)"
  existing="$(tmux -L "$socket" list-sessions -F '#{session_name}' 2>/dev/null || true)"
  printf '%s\n' "$existing" | grep -Fxq "$target" || sm_die "Managed tmux session not found: ${target}"

  if (( do_detach == 1 )); then
    tmux -L "$socket" detach-client -s "=${target}" 2>/dev/null || true
  fi

  local final_name="$target"
  local new_safe policy
  new_safe="$(sm_sanitize "$new_ip")"
  policy="$(sm_ip_policy "$new_safe")"

  if [[ "$target" =~ ^ip-(.+)-([0-9]+)$ ]] && [[ "${BASH_REMATCH[1]}" != "$new_safe" ]]; then
    local base="ssh-resume"
    if [[ "$policy" == "per-client" ]]; then
      base="ip-${new_safe}"
    else
      base="$(sm_session_prefix)"
    fi
    local renamed=""
    renamed="$(sm_next_free_tmux_slot "$base")"
    if [[ -n "$renamed" ]] && tmux -L "$socket" rename-session -t "=${target}" "$renamed" 2>/dev/null; then
      rm -f "$(sm_session_meta_path "$target")" 2>/dev/null || true
      final_name="$renamed"
    fi
  fi

  sm_record_connect "$new_ip" "$final_name"
  if [[ "$final_name" != "$target" ]]; then
    echo "Transferred session ${target} -> ${final_name} (owner IP: ${new_ip})"
  else
    echo "Transferred session ${target} to IP ${new_ip}"
  fi
}

# ============================================================
# IP Management Operations: show, label, transfer, drop, prune
# ============================================================

# Collect all known safe_ip keys across ips/*.meta, choices/*, sessions/*.meta, and live ip-* sessions.
sm_all_known_safe_ips() {
  local -a found=()
  local f name safe val

  if [[ -d "$(sm_ips_dir)" ]]; then
    while IFS= read -r -d '' f; do
      name="$(basename "$f" .meta)"
      [[ -n "$name" ]] && found+=("$name")
    done < <(find "$(sm_ips_dir)" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  fi

  if [[ -d "$(sm_choices_dir)" ]]; then
    while IFS= read -r -d '' f; do
      name="$(basename "$f")"
      [[ -n "$name" ]] && found+=("$name")
    done < <(find "$(sm_choices_dir)" -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  if [[ -d "$(sm_sessions_dir)" ]]; then
    while IFS= read -r -d '' f; do
      val="$(sm_meta_get "$f" last_ip)"
      safe="$(sm_sanitize "$val")"
      [[ -n "$safe" && "$safe" != "-" ]] && found+=("$safe")
    done < <(find "$(sm_sessions_dir)" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  fi

  local rows="" sname rest
  rows="$(sm_collect_tmux_sessions user)"
  if [[ -n "$rows" ]]; then
    while IFS='|' read -r sname rest; do
      if [[ "$sname" =~ ^ip-(.+)-([0-9]+)$ ]]; then
        found+=("${BASH_REMATCH[1]}")
      fi
    done <<< "$rows"
  fi

  if [[ ${#found[@]} -gt 0 ]]; then
    printf '%s\n' "${found[@]}" | awk 'NF && !seen[$0]++' | sort
  fi
}

sm_sessions_for_safe_ip() {
  local target_safe="$1"
  local rows="${2:-}"
  [[ -n "$rows" ]] || rows="$(sm_collect_tmux_sessions user)"
  [[ -n "$rows" ]] || return 0

  local name attached windows panes state cmd cwd hist owner_ip owner_safe
  local -a matches=()
  while IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip; do
    [[ -n "$name" ]] || continue
    owner_safe="$(sm_sanitize "$owner_ip")"
    if [[ "$owner_safe" == "$target_safe" ]] || [[ "$name" =~ ^ip-${target_safe}-[0-9]+$ ]]; then
      matches+=("${name}[${state}]")
    fi
  done <<< "$rows"

  if [[ ${#matches[@]} -gt 0 ]]; then
    local IFS=", "
    printf '%s' "${matches[*]}"
  fi
}

sm_cmd_ip_show() {
  local filter_ip="${1:-}"
  local current_raw current_safe
  current_raw="$(sm_current_ip)"
  current_safe="$(sm_sanitize "$current_raw")"

  local keys=""
  if [[ -n "$filter_ip" ]]; then
    keys="$(sm_sanitize "$filter_ip")"
  else
    keys="$(sm_all_known_safe_ips)"
  fi

  if [[ -z "$keys" ]]; then
    echo "(no stored IP records)"
    return 0
  fi

  local live_rows=""
  live_rows="$(sm_collect_tmux_sessions user)"

  local safe meta raw label policy last_seen count age sess_list cur_tag disp
  local printed=0
  while IFS= read -r safe; do
    [[ -n "$safe" ]] || continue
    meta="$(sm_ip_meta_path "$safe")"
    if [[ -n "$filter_ip" && ! -f "$meta" && ! -f "$(sm_choices_dir)/${safe}" ]]; then
      sess_list="$(sm_sessions_for_safe_ip "$safe" "$live_rows")"
      if [[ -z "$sess_list" ]]; then
        echo "(no stored IP record for ${filter_ip})"
        return 1
      fi
    fi

    raw="$(sm_meta_get "$meta" raw_ip)"
    [[ -n "$raw" ]] || raw="$safe"
    label="$(sm_meta_get "$meta" label)"
    policy="$(sm_ip_policy "$safe")"
    [[ "$policy" == "default" ]] && policy="default(multi)"
    last_seen="$(sm_meta_get "$meta" last_seen)"
    count="$(sm_meta_get "$meta" connect_count)"
    [[ -n "$count" ]] || count="0"
    age="$(sm_format_age "$last_seen")"
    sess_list="$(sm_sessions_for_safe_ip "$safe" "$live_rows")"
    [[ -n "$sess_list" ]] || sess_list="none"

    cur_tag=""
    if [[ -n "$current_safe" && "$safe" == "$current_safe" ]]; then
      cur_tag=" [current]"
    fi
    disp="$raw"
    [[ -n "$label" ]] && disp="${raw} (${label})"

    printf '  %s%s\n' "$disp" "$cur_tag" 2>/dev/null || return 0
    printf '    key=%s policy=%s connects=%s last_seen=%s\n' "$safe" "$policy" "$count" "$age" 2>/dev/null || return 0
    printf '    sessions: %s\n' "$sess_list" 2>/dev/null || return 0
    printed=1
  done <<< "$keys"

  if (( printed == 0 )); then
    echo "(no stored IP records)"
  fi
}

sm_cmd_ip_label() {
  local ip="${1:-}" label="${2:-}"
  [[ -n "$ip" && -n "$label" ]] || sm_die "Usage: ssh-multisession-resume ip label IP LABEL"
  local safe clean_label meta raw
  safe="$(sm_sanitize "$ip")"
  [[ -n "$safe" ]] || sm_die "Invalid IP."
  clean_label="$(sm_sanitize_label "$label")"
  [[ -n "$clean_label" ]] || sm_die "Label cannot be empty."

  meta="$(sm_ip_meta_path "$safe")"
  raw="$(sm_meta_get "$meta" raw_ip)"
  [[ -n "$raw" ]] || raw="$ip"
  sm_meta_write "$meta" "raw_ip=${raw}" "safe_ip=${safe}" "label=${clean_label}"
  echo "Labeled IP ${raw} as '${clean_label}'"
}

sm_cmd_ip_unlabel() {
  local ip="${1:-}"
  [[ -n "$ip" ]] || sm_die "Usage: ssh-multisession-resume ip unlabel IP"
  local safe meta
  safe="$(sm_sanitize "$ip")"
  meta="$(sm_ip_meta_path "$safe")"
  if [[ -f "$meta" ]]; then
    sm_meta_write "$meta" "label="
    echo "Cleared label for ${ip}"
  else
    echo "No stored metadata for ${ip}"
  fi
}

sm_cmd_ip_transfer() {
  local old_ip="" new_ip="" do_detach=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detach|-d) do_detach=1; shift ;;
      --*) sm_die "Unknown flag: $1" ;;
      *)
        if [[ -z "$old_ip" ]]; then
          old_ip="$1"
        elif [[ -z "$new_ip" ]]; then
          new_ip="$1"
        else
          sm_die "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$old_ip" ]] || sm_die "Usage: ssh-multisession-resume ip transfer OLD_IP [NEW_IP] [--detach]"
  if [[ -z "$new_ip" ]]; then
    new_ip="$(sm_current_ip)"
    [[ -n "$new_ip" ]] || sm_die "Could not detect current SSH IP; pass NEW_IP explicitly."
  fi

  local old_safe new_safe
  old_safe="$(sm_sanitize "$old_ip")"
  new_safe="$(sm_sanitize "$new_ip")"
  [[ -n "$old_safe" && -n "$new_safe" ]] || sm_die "Invalid IP address."
  if [[ "$old_safe" == "$new_safe" ]]; then
    echo "Source and destination IP are identical (${new_ip}); nothing to transfer."
    return 0
  fi

  local moved_policy=0 moved_meta=0 renamed_count=0 handed_off=0 detached_count=0

  # 1. Transfer saved policy if present.
  local old_choice new_choice
  old_choice="$(sm_choices_dir)/${old_safe}"
  new_choice="$(sm_choices_dir)/${new_safe}"
  if [[ -f "$old_choice" ]]; then
    sm_ensure_private_dir "$(sm_choices_dir)"
    mv -f "$old_choice" "$new_choice"
    moved_policy=1
  fi

  # 2. Merge IP metadata (preserve new label if already set, else carry old label).
  local old_meta new_meta now old_label new_label old_count new_count total_count first_seen
  old_meta="$(sm_ip_meta_path "$old_safe")"
  new_meta="$(sm_ip_meta_path "$new_safe")"
  now="$(date +%s)"
  old_label="$(sm_meta_get "$old_meta" label)"
  new_label="$(sm_meta_get "$new_meta" label)"
  [[ -n "$new_label" ]] || new_label="$old_label"

  old_count="$(sm_meta_get "$old_meta" connect_count)"
  new_count="$(sm_meta_get "$new_meta" connect_count)"
  [[ "$old_count" =~ ^[0-9]+$ ]] || old_count=0
  [[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
  total_count=$((old_count + new_count))
  first_seen="$(sm_meta_get "$new_meta" first_seen)"
  [[ -n "$first_seen" ]] || first_seen="$(sm_meta_get "$old_meta" first_seen)"
  [[ -n "$first_seen" ]] || first_seen="$now"

  local raw_new="$new_ip"
  if [[ "$new_ip" == "$new_safe" ]]; then
    local existing_raw
    existing_raw="$(sm_meta_get "$new_meta" raw_ip)"
    [[ -n "$existing_raw" ]] && raw_new="$existing_raw"
  fi

  sm_meta_write "$new_meta" \
    "raw_ip=${raw_new}" \
    "safe_ip=${new_safe}" \
    "label=${new_label}" \
    "first_seen=${first_seen}" \
    "last_seen=${now}" \
    "connect_count=${total_count}"

  if [[ -f "$old_meta" ]]; then
    rm -f "$old_meta"
    moved_meta=1
  fi

  # 3. Rename per-client sessions (ip-<old_safe>-N -> ip-<new_safe>-M) & hand off ownership.
  if command -v tmux >/dev/null 2>&1; then
    sm_ensure_tmux_tmpdir
    local socket rows=""
    socket="$(sm_socket_name)"
    rows="$(sm_collect_tmux_sessions user)"
    if [[ -n "$rows" ]]; then
      local name attached windows panes state cmd cwd hist owner_ip owner_safe target_name
      while IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip; do
        [[ -n "$name" ]] || continue
        owner_safe="$(sm_sanitize "$owner_ip")"
        if [[ "$owner_safe" != "$old_safe" ]] && [[ ! "$name" =~ ^ip-${old_safe}-[0-9]+$ ]]; then
          continue
        fi

        if (( do_detach == 1 )) && [[ "$attached" != "0" ]]; then
          if tmux -L "$socket" detach-client -s "=${name}" 2>/dev/null; then
            detached_count=$((detached_count + 1))
          fi
        fi

        target_name="$name"
        if [[ "$name" =~ ^ip-${old_safe}-[0-9]+$ ]]; then
          local next_slot=""
          next_slot="$(sm_next_free_tmux_slot "ip-${new_safe}")"
          if [[ -n "$next_slot" ]] && tmux -L "$socket" rename-session -t "=${name}" "$next_slot" 2>/dev/null; then
            rm -f "$(sm_session_meta_path "$name")" 2>/dev/null || true
            target_name="$next_slot"
            renamed_count=$((renamed_count + 1))
          fi
        fi

        sm_meta_write "$(sm_session_meta_path "$target_name")" \
          "session=${target_name}" \
          "last_ip=${raw_new}" \
          "last_attached_at=${now}"
        handed_off=$((handed_off + 1))
      done <<< "$rows"
    fi
  fi

  # 4. Update any remaining session metadata files referencing old_safe.
  if [[ -d "$(sm_sessions_dir)" ]]; then
    local sf s_last
    while IFS= read -r -d '' sf; do
      s_last="$(sm_meta_get "$sf" last_ip)"
      if [[ "$(sm_sanitize "$s_last")" == "$old_safe" ]]; then
        sm_meta_write "$sf" "last_ip=${raw_new}"
      fi
    done < <(find "$(sm_sessions_dir)" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  fi

  echo "Transferred IP ${old_ip} -> ${raw_new} (policy=${moved_policy}, meta=${moved_meta}, sessions=${handed_off}, renamed=${renamed_count}, detached=${detached_count})"
}

sm_cmd_ip_drop() {
  local target_ip="" do_detach=0 kill_detached=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detach|-d)        do_detach=1; shift ;;
      --kill-detached|-k) kill_detached=1; shift ;;
      --*) sm_die "Unknown flag: $1" ;;
      *)
        [[ -z "$target_ip" ]] || sm_die "Unexpected argument: $1"
        target_ip="$1"
        shift
        ;;
    esac
  done

  [[ -n "$target_ip" ]] || sm_die "Usage: ssh-multisession-resume ip drop IP [--detach] [--kill-detached]"
  local safe
  safe="$(sm_sanitize "$target_ip")"
  [[ -n "$safe" ]] || sm_die "Invalid IP."

  rm -f "$(sm_choices_dir)/${safe}" "$(sm_ip_meta_path "$safe")" 2>/dev/null || true

  local migrated=0 killed=0 detached_count=0 skipped_active=0
  if command -v tmux >/dev/null 2>&1; then
    sm_ensure_tmux_tmpdir
    local socket current_sess rows=""
    socket="$(sm_socket_name)"
    current_sess="$(sm_current_tmux_session)"
    rows="$(sm_collect_tmux_sessions user)"
    if [[ -n "$rows" ]]; then
      local name attached windows panes state cmd cwd hist owner_ip owner_safe
      while IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip; do
        [[ -n "$name" ]] || continue
        owner_safe="$(sm_sanitize "$owner_ip")"
        if [[ "$owner_safe" != "$safe" ]] && [[ ! "$name" =~ ^ip-${safe}-[0-9]+$ ]]; then
          continue
        fi

        if (( do_detach == 1 )) && [[ "$attached" != "0" ]] && [[ "$name" != "$current_sess" ]]; then
          if tmux -L "$socket" detach-client -s "=${name}" 2>/dev/null; then
            attached="0"
            detached_count=$((detached_count + 1))
          fi
        fi

        if (( kill_detached == 1 )); then
          if [[ "$attached" == "0" && "$state" != "active" && "$name" != "$current_sess" ]] && ! sm_is_reserved "tmux-${name}"; then
            if tmux -L "$socket" kill-session -t "=${name}" 2>/dev/null; then
              rm -f "$(sm_session_meta_path "$name")" 2>/dev/null || true
              killed=$((killed + 1))
              continue
            fi
          else
            skipped_active=$((skipped_active + 1))
          fi
        fi

        # Safe default: migrate per-client `ip-<safe>-N` sessions into the shared pool (`ssh-resume-M`)
        # so dropping an IP record never orphans or destroys open work.
        if [[ "$name" =~ ^ip-${safe}-[0-9]+$ ]]; then
          local global_slot=""
          global_slot="$(sm_next_free_tmux_slot "$(sm_session_prefix)")"
          if [[ -n "$global_slot" ]] && tmux -L "$socket" rename-session -t "=${name}" "$global_slot" 2>/dev/null; then
            rm -f "$(sm_session_meta_path "$name")" 2>/dev/null || true
            migrated=$((migrated + 1))
          fi
        else
          rm -f "$(sm_session_meta_path "$name")" 2>/dev/null || true
        fi
      done <<< "$rows"
    fi
  fi

  if [[ -d "$(sm_sessions_dir)" ]]; then
    local sf s_last
    while IFS= read -r -d '' sf; do
      s_last="$(sm_meta_get "$sf" last_ip)"
      if [[ "$(sm_sanitize "$s_last")" == "$safe" ]]; then
        sm_meta_write "$sf" "last_ip="
      fi
    done < <(find "$(sm_sessions_dir)" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  fi

  echo "Dropped IP ${target_ip} (migrated=${migrated}, killed_detached=${killed}, detached=${detached_count}, active_preserved=${skipped_active})"
}

sm_cmd_ip_prune() {
  local max_days=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days)
        [[ $# -ge 2 && "${2:-}" =~ ^[0-9]+$ ]] || sm_die "Invalid --days value"
        max_days="$2"
        shift 2
        ;;
      *) sm_die "Unknown ip prune flag: $1" ;;
    esac
  done

  local live_rows="" live_names="" pruned_sess=0 pruned_ips=0
  live_rows="$(sm_collect_tmux_sessions all)"
  if [[ -n "$live_rows" ]]; then
    live_names="$(printf '%s\n' "$live_rows" | cut -d'|' -f1)"
  fi

  if command -v tmux >/dev/null 2>&1 && [[ -d "$(sm_sessions_dir)" ]]; then
    local sf sname
    while IFS= read -r -d '' sf; do
      sname="$(sm_meta_get "$sf" session)"
      if [[ -z "$sname" ]] || { [[ -n "$live_names" ]] && ! printf '%s\n' "$live_names" | grep -Fxq "$sname"; } || [[ -z "$live_names" ]]; then
        rm -f "$sf" 2>/dev/null || true
        pruned_sess=$((pruned_sess + 1))
      fi
    done < <(find "$(sm_sessions_dir)" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  fi

  local now cutoff=0
  now="$(date +%s)"
  if (( max_days > 0 )); then
    cutoff=$((now - max_days * 86400))
  fi

  if [[ -d "$(sm_ips_dir)" ]]; then
    local im safe policy label last_seen sess_list
    while IFS= read -r -d '' im; do
      safe="$(basename "$im" .meta)"
      policy="$(sm_ip_policy "$safe")"
      label="$(sm_meta_get "$im" label)"
      last_seen="$(sm_meta_get "$im" last_seen)"
      sess_list="$(sm_sessions_for_safe_ip "$safe" "$live_rows")"
      [[ "$policy" == "default" && -z "$label" && -z "$sess_list" ]] || continue
      if (( cutoff == 0 )) || { [[ "$last_seen" =~ ^[0-9]+$ ]] && (( last_seen <= cutoff )); }; then
        rm -f "$im" 2>/dev/null || true
        pruned_ips=$((pruned_ips + 1))
      fi
    done < <(find "$(sm_ips_dir)" -maxdepth 1 -type f -name '*.meta' -print0 2>/dev/null)
  fi

  echo "Pruned ${pruned_sess} stale session record(s) and ${pruned_ips} idle IP record(s)."
}

# ============================================================
# Picker Configuration: show | auto | on | off
# ============================================================

sm_picker_mode() {
  local raw="${SSH_AUTO_RESUME_PICKER:-}"
  if [[ -z "$raw" && -r "$(sm_picker_config_path)" ]]; then
    IFS= read -r raw < "$(sm_picker_config_path)" || true
  fi
  case "$raw" in
    ''|auto|default) printf 'auto\n' ;;
    1|on|always|yes|true) printf 'on\n' ;;
    0|off|never|no|false) printf 'off\n' ;;
    *) printf 'auto\n' ;;
  esac
}

sm_cmd_picker_config() {
  local sub="${1:-show}" path mode
  path="$(sm_picker_config_path)"
  case "$sub" in
    show|status)
      mode="$(sm_picker_mode)"
      if [[ "$mode" == "auto" && ! -r "$path" ]]; then
        echo "picker: auto (default - opens when sessions exist)"
      else
        echo "picker: ${mode} (${path})"
      fi
      ;;
    auto|default)
      rm -f "$path" 2>/dev/null || true
      echo "Picker set to auto (default - opens on new connects when sessions exist)."
      ;;
    on|always|enable|1)
      sm_ensure_private_dir "$(sm_policy_dir)"
      printf 'on\n' > "$path"
      echo "Picker enabled (always): ${path}"
      ;;
    off|never|disable|0)
      sm_ensure_private_dir "$(sm_policy_dir)"
      printf 'off\n' > "$path"
      echo "Picker disabled: ${path}"
      ;;
    -h|--help)
      echo "Usage: ssh-multisession-resume picker show|auto|on|off"
      ;;
    *)
      sm_die "Usage: ssh-multisession-resume picker show|auto|on|off"
      ;;
  esac
}

# ============================================================
# Interactive Session Picker + Preview + IP Manager TUI
# ============================================================

SM_SAVED_STTY=""
SM_TUI_ACTIVE=0

sm_tui_enter() {
  if [[ -t 0 && -t 1 ]]; then
    SM_SAVED_STTY="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf '\033[?1049h\033[?25l'
    SM_TUI_ACTIVE=1
  fi
}

sm_tui_leave() {
  if (( SM_TUI_ACTIVE == 1 )); then
    printf '\033[?25h\033[?1049l'
    if [[ -n "$SM_SAVED_STTY" ]]; then
      stty "$SM_SAVED_STTY" 2>/dev/null || true
    else
      stty sane 2>/dev/null || true
    fi
    SM_TUI_ACTIVE=0
  fi
}

sm_tui_read_line() {
  local prompt="$1" reply=""
  if (( SM_TUI_ACTIVE == 1 )); then
    printf '\033[?25h'
    if [[ -n "$SM_SAVED_STTY" ]]; then
      stty "$SM_SAVED_STTY" 2>/dev/null || true
    else
      stty echo icanon 2>/dev/null || true
    fi
  fi
  printf '%s' "$prompt"
  IFS= read -r reply || true
  if (( SM_TUI_ACTIVE == 1 )); then
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf '\033[?25l'
  fi
  printf '%s' "$reply"
}

# Reads one logical key into SM_KEY:
# UP, DOWN, LEFT, RIGHT, ENTER, ESC, EOF, or literal char / multi-digit number.
SM_KEY=""
sm_read_key() {
  local max_num="${1:-9}"
  local ch="" next1="" next2=""
  SM_KEY=""

  if ! IFS= read -r -s -n 1 ch; then
    SM_KEY="EOF"
    return 0
  fi

  case "$ch" in
    ''|$'\n'|$'\r')
      SM_KEY="ENTER"
      return 0
      ;;
    $'\e')
      if IFS= read -r -s -n 1 -t 0.12 next1; then
        if [[ "$next1" == "[" || "$next1" == "O" ]]; then
          if IFS= read -r -s -n 1 -t 0.12 next2; then
            case "$next2" in
              A) SM_KEY="UP"; return 0 ;;
              B) SM_KEY="DOWN"; return 0 ;;
              C) SM_KEY="RIGHT"; return 0 ;;
              D) SM_KEY="LEFT"; return 0 ;;
            esac
          fi
        fi
      fi
      SM_KEY="ESC"
      return 0
      ;;
    [1-9])
      local num="$ch"
      if (( max_num >= ch * 10 )); then
        if IFS= read -r -s -n 1 -t 0.45 next1; then
          if [[ "$next1" =~ ^[0-9]$ ]]; then
            num="${ch}${next1}"
          fi
        fi
      fi
      SM_KEY="NUM:${num}"
      return 0
      ;;
    *)
      SM_KEY="$ch"
      return 0
      ;;
  esac
}

sm_term_dims() {
  local cols=80 lines=24 sz=""
  if [[ -t 1 ]] && sz="$(stty size 2>/dev/null)" && [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    lines="${BASH_REMATCH[1]}"
    cols="${BASH_REMATCH[2]}"
  else
    cols="${COLUMNS:-80}"
    lines="${LINES:-24}"
  fi
  (( cols < 60 )) && cols=60
  (( lines < 18 )) && lines=18
  printf '%s %s\n' "$cols" "$lines"
}

sm_hr() {
  local cols="$1"
  local bar=""
  printf -v bar '%*s' "$cols" ''
  printf '%s' "${bar// /-}"
}

# Interactive IP Manager sub-screen invoked via [i] inside the Picker.
sm_tui_ip_screen() {
  local current_ip="$1"
  local current_safe
  current_safe="$(sm_sanitize "$current_ip")"
  local cursor=-1 flash=""

  while true; do
    local -a ip_keys=()
    local k
    while IFS= read -r k; do
      [[ -n "$k" ]] && ip_keys+=("$k")
    done < <(sm_all_known_safe_ips)

    if [[ -n "$current_safe" ]] && { [[ ${#ip_keys[@]} -eq 0 ]] || ! printf '%s\n' "${ip_keys[@]}" | grep -Fxq "$current_safe"; }; then
      ip_keys=("$current_safe" "${ip_keys[@]}")
    fi

    local total=${#ip_keys[@]}
    if (( cursor < 0 )); then
      cursor=0
      if (( total > 1 )) && [[ -n "$current_safe" && "${ip_keys[0]}" == "$current_safe" ]]; then
        cursor=1
      fi
    fi
    if (( cursor >= total )); then cursor=$(( total > 0 ? total - 1 : 0 )); fi
    if (( cursor < 0 )); then cursor=0; fi

    local dims cols lines
    dims="$(sm_term_dims)"
    cols="${dims%% *}"
    lines="${dims#* }"
    local inner=$((cols - 2))
    local live_rows=""
    live_rows="$(sm_collect_tmux_sessions user)"

    local c_bold=$'\033[1m' c_cyan=$'\033[1;36m' c_yel=$'\033[1;33m' c_dim=$'\033[2m' c_rst=$'\033[0m'
    if [[ -n "${NO_COLOR:-}" ]]; then
      c_bold=""; c_cyan=""; c_yel=""; c_dim=""; c_rst=""
    fi

    printf '\033[H'
    printf ' %sIP & Session Management%s  |  current client: %s%s%s\033[K\n' \
      "$c_cyan" "$c_rst" "$c_bold" "$(sm_ip_display "${current_ip:-local}")" "$c_rst"
    printf '%s\033[K\n' "$(sm_hr "$cols")"

    if (( total == 0 )); then
      printf '  (no stored IP records)\033[K\n'
    else
      local idx safe meta raw label pol seen sess_str tag prefix_mark
      local list_max=$((lines - 12))
      (( list_max < 4 )) && list_max=4
      local start=0
      if (( cursor >= list_max )); then start=$((cursor - list_max + 1)); fi
      local end=$((start + list_max))
      (( end > total )) && end=$total

      for ((idx = start; idx < end; idx++)); do
        safe="${ip_keys[$idx]}"
        meta="$(sm_ip_meta_path "$safe")"
        raw="$(sm_meta_get "$meta" raw_ip)"
        [[ -n "$raw" ]] || raw="$safe"
        label="$(sm_meta_get "$meta" label)"
        pol="$(sm_ip_policy "$safe")"
        seen="$(sm_format_age "$(sm_meta_get "$meta" last_seen)")"
        sess_str="$(sm_sessions_for_safe_ip "$safe" "$live_rows")"
        [[ -n "$sess_str" ]] || sess_str="none"
        tag=""
        [[ -n "$current_safe" && "$safe" == "$current_safe" ]] && tag=" [current]"
        local row_text
        row_text="$(printf '[%d] %-24s  policy=%-10s  seen=%-8s  sessions=%s' \
          "$((idx + 1))" "${raw}${label:+ ($label)}${tag}" "$pol" "$seen" "$sess_str")"
        row_text="$(sm_sanitize_line "$row_text" $((inner - 3)))"
        if (( idx == cursor )); then
          prefix_mark="${c_yel}>${c_rst}"
          printf ' %s %s%s%s\033[K\n' "$prefix_mark" "$c_bold" "$row_text" "$c_rst"
        else
          printf '   %s\033[K\n' "$row_text"
        fi
      done
    fi

    printf '%s\033[K\n' "$(sm_hr "$cols")"
    if (( total > 0 )); then
      local sel_safe="${ip_keys[$cursor]}"
      local sel_meta sel_raw sel_pol sel_cnt sel_sess
      sel_meta="$(sm_ip_meta_path "$sel_safe")"
      sel_raw="$(sm_meta_get "$sel_meta" raw_ip)"
      [[ -n "$sel_raw" ]] || sel_raw="$sel_safe"
      sel_pol="$(sm_ip_policy "$sel_safe")"
      sel_cnt="$(sm_meta_get "$sel_meta" connect_count)"
      sel_sess="$(sm_sessions_for_safe_ip "$sel_safe" "$live_rows")"
      printf ' Selected IP : %s%s%s (key: %s)\033[K\n' "$c_bold" "$(sm_ip_display "$sel_safe")" "$c_rst" "$sel_safe"
      printf ' Policy      : %s  |  Connections: %s\033[K\n' "$sel_pol" "${sel_cnt:-0}"
      printf ' Sessions    : %s\033[K\n' "$(sm_sanitize_line "${sel_sess:-none}" $((inner - 15)))"
    fi

    printf '%s\033[K\n' "$(sm_hr "$cols")"
    if [[ -n "$flash" ]]; then
      printf ' %s%s%s\033[K\n' "$c_yel" "$(sm_sanitize_line "$flash" "$inner")" "$c_rst"
      flash=""
    else
      printf ' %s[Up/Down/1-9]%s select  %s[t]%s transfer -> current IP  %s[m]%s cycle policy\033[K\n' \
        "$c_bold" "$c_rst" "$c_bold" "$c_rst" "$c_bold" "$c_rst"
    fi
    printf ' %s[l]%s set label  %s[x]%s drop IP (migrates sessions)  %s[b/Esc/q]%s back to sessions\033[K\033[J' \
      "$c_bold" "$c_rst" "$c_bold" "$c_rst" "$c_bold" "$c_rst"

    sm_read_key "$total"
    case "$SM_KEY" in
      UP|k|K)
        (( total > 0 )) && cursor=$(( (cursor - 1 + total) % total ))
        ;;
      DOWN|j|J)
        (( total > 0 )) && cursor=$(( (cursor + 1) % total ))
        ;;
      NUM:*)
        local n="${SM_KEY#NUM:}"
        if (( n >= 1 && n <= total )); then
          cursor=$((n - 1))
        fi
        ;;
      t|T)
        if (( total > 0 )); then
          local src_safe="${ip_keys[$cursor]}"
          if [[ -z "$current_ip" ]]; then
            flash="Cannot transfer: no current SSH client IP detected."
          elif [[ "$src_safe" == "$current_safe" ]]; then
            flash="Selected IP is already your current IP."
          else
            local src_raw
            src_raw="$(sm_meta_get "$(sm_ip_meta_path "$src_safe")" raw_ip)"
            [[ -n "$src_raw" ]] || src_raw="$src_safe"
            flash="$(sm_cmd_ip_transfer "$src_raw" "$current_ip" --detach 2>&1 || true)"
          fi
        fi
        ;;
      m|M)
        if (( total > 0 )); then
          local m_safe="${ip_keys[$cursor]}"
          local cur_p next_p
          cur_p="$(sm_ip_policy "$m_safe")"
          case "$cur_p" in
            default)    next_p="multi" ;;
            multi)      next_p="single" ;;
            single)     next_p="per-client" ;;
            per-client) next_p="skip" ;;
            skip)       next_p="default" ;;
            *)          next_p="default" ;;
          esac
          if [[ "$next_p" == "default" ]]; then
            rm -f "$(sm_choices_dir)/${m_safe}" 2>/dev/null || true
          else
            sm_ensure_private_dir "$(sm_choices_dir)"
            printf '%s\n' "$next_p" > "$(sm_choices_dir)/${m_safe}"
          fi
          flash="Updated policy for ${m_safe} -> ${next_p}"
        fi
        ;;
      l|L)
        if (( total > 0 )); then
          printf '\r\033[K'
          local new_lbl="" l_safe="${ip_keys[$cursor]}" l_raw
          l_raw="$(sm_meta_get "$(sm_ip_meta_path "$l_safe")" raw_ip)"
          [[ -n "$l_raw" ]] || l_raw="$l_safe"
          new_lbl="$(sm_tui_read_line " Label for ${l_raw} (blank to clear): ")"
          new_lbl="$(sm_sanitize_label "$new_lbl")"
          if [[ -n "$new_lbl" ]]; then
            sm_cmd_ip_label "$l_raw" "$new_lbl" >/dev/null
            flash="Labeled ${l_raw} as '${new_lbl}'."
          else
            sm_cmd_ip_unlabel "$l_raw" >/dev/null
            flash="Cleared label for ${l_raw}."
          fi
        fi
        ;;
      x|X)
        if (( total > 0 )); then
          local d_safe="${ip_keys[$cursor]}" d_raw
          d_raw="$(sm_meta_get "$(sm_ip_meta_path "$d_safe")" raw_ip)"
          [[ -n "$d_raw" ]] || d_raw="$d_safe"
          flash="$(sm_cmd_ip_drop "$d_raw" 2>&1 || true)"
        fi
        ;;
      b|B|q|Q|ESC|EOF|ENTER)
        return 0
        ;;
    esac
  done
}

# Main interactive picker.
# Writes ACTION|TARGET to $result_file (if provided) or handles CLI switch/attach.
sm_run_picker() {
  local context="cli" result_file="" session_base="" policy_mode="multi" force_tty=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context)      context="${2:?}"; shift 2 ;;
      --result-file)  result_file="${2:?}"; shift 2 ;;
      --session-base) session_base="${2:?}"; shift 2 ;;
      --mode)         policy_mode="${2:?}"; shift 2 ;;
      --force-tty)    force_tty=1; shift ;;
      *) sm_die "Unknown picker arg: $1" ;;
    esac
  done

  [[ -n "$session_base" ]] || session_base="$(sm_session_prefix)"
  local picker_cfg
  picker_cfg="$(sm_picker_mode)"

  if [[ "$context" == "login" ]]; then
    if [[ "$picker_cfg" == "off" ]]; then
      [[ -n "$result_file" ]] && printf 'AUTO|\n' > "$result_file"
      return 0
    fi
    if (( force_tty == 0 )) && { [[ "${TERM:-}" == "dumb" ]] || [[ ! -t 0 || ! -t 1 ]]; }; then
      [[ -n "$result_file" ]] && printf 'AUTO|\n' > "$result_file"
      return 0
    fi
    if [[ "$picker_cfg" == "auto" ]]; then
      if [[ "$policy_mode" == "single" || "$policy_mode" == "skip" ]]; then
        [[ -n "$result_file" ]] && printf 'AUTO|\n' > "$result_file"
        return 0
      fi
      local init_rows=""
      init_rows="$(sm_collect_tmux_sessions user)"
      if [[ -z "$init_rows" ]]; then
        [[ -n "$result_file" ]] && printf 'AUTO|\n' > "$result_file"
        return 0
      fi
    fi
  else
    if (( force_tty == 0 )) && [[ ! -t 0 || ! -t 1 ]]; then
      sm_die "Interactive picker requires a TTY."
    fi
  fi

  sm_ensure_tmux_tmpdir
  local socket current_ip current_sess
  socket="$(sm_socket_name)"
  current_ip="$(sm_current_ip)"
  current_sess="$(sm_current_tmux_session)"

  local cursor=-1 flash="" chosen_action="" chosen_target=""
  trap 'sm_tui_leave' EXIT INT TERM HUP
  if (( force_tty == 0 )); then
    sm_tui_enter
  fi

  while true; do
    local rows=""
    rows="$(sm_collect_tmux_sessions user)"

    # Build ordered item list:
    #   1. Detached 'open' sessions
    #   2. Detached 'cleared' and 'empty' sessions
    #   3. '+ New terminal'
    #   4. '-> Plain shell' (on login) or '-> Cancel' (on CLI)
    #   5. Active sessions (marked [active], NEVER previewed!)
    local -a item_kind=()
    local -a item_target=()
    local -a item_state=()
    local -a item_win=()
    local -a item_cmd=()
    local -a item_cwd=()
    local -a item_hist=()
    local -a item_ip=()

    local -a open_rows=() idle_rows=() active_rows=()
    if [[ -n "$rows" ]]; then
      local r_line r_state
      while IFS= read -r r_line; do
        [[ -n "$r_line" ]] || continue
        IFS='|' read -r _ _ _ _ r_state _ <<< "$r_line"
        case "$r_state" in
          active)        active_rows+=("$r_line") ;;
          empty|cleared) idle_rows+=("$r_line") ;;
          *)             open_rows+=("$r_line") ;;
        esac
      done <<< "$rows"
    fi

    local r name attached windows panes state cmd cwd hist owner_ip
    if (( ${#open_rows[@]} > 0 )); then
      for r in "${open_rows[@]}"; do
        IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip <<< "$r"
        item_kind+=("SESSION")
        item_target+=("$name")
        item_state+=("$state")
        item_win+=("$windows")
        item_cmd+=("$cmd")
        item_cwd+=("$cwd")
        item_hist+=("$hist")
        item_ip+=("$owner_ip")
      done
    fi
    if (( ${#idle_rows[@]} > 0 )); then
      for r in "${idle_rows[@]}"; do
        IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip <<< "$r"
        item_kind+=("SESSION")
        item_target+=("$name")
        item_state+=("$state")
        item_win+=("$windows")
        item_cmd+=("$cmd")
        item_cwd+=("$cwd")
        item_hist+=("$hist")
        item_ip+=("$owner_ip")
      done
    fi

    local next_slot=""
    next_slot="$(sm_next_free_tmux_slot "$session_base" || printf '%s-new' "$session_base")"
    local new_idx=${#item_kind[@]}
    item_kind+=("NEW")
    item_target+=("$next_slot")
    item_state+=("new")
    item_win+=("-")
    item_cmd+=("-")
    item_cwd+=("${HOME:-~}")
    item_hist+=("0")
    item_ip+=("${current_ip:--}")

    item_kind+=("SKIP")
    item_target+=("")
    item_state+=("skip")
    item_win+=("-")
    item_cmd+=("-")
    item_cwd+=("-")
    item_hist+=("0")
    item_ip+=("-")

    if (( ${#active_rows[@]} > 0 )); then
      for r in "${active_rows[@]}"; do
        IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip <<< "$r"
        item_kind+=("ACTIVE")
        item_target+=("$name")
        item_state+=("active")
        item_win+=("$windows")
        item_cmd+=("$cmd")
        item_cwd+=("$cwd")
        item_hist+=("$hist")
        item_ip+=("$owner_ip")
      done
    fi

    local total=${#item_kind[@]}
    if (( cursor < 0 )); then
      if (( ${#open_rows[@]} > 0 || ${#idle_rows[@]} > 0 )); then
        cursor=0
      else
        cursor=$new_idx
      fi
    fi
    if (( cursor >= total )); then cursor=$((total - 1)); fi
    if (( cursor < 0 )); then cursor=0; fi

    local dims cols lines
    dims="$(sm_term_dims)"
    cols="${dims%% *}"
    lines="${dims#* }"
    local inner=$((cols - 2))

    local c_bold=$'\033[1m' c_cyan=$'\033[1;36m' c_grn=$'\033[1;32m'
    local c_yel=$'\033[1;33m' c_mag=$'\033[1;35m' c_dim=$'\033[2m' c_rst=$'\033[0m'
    if [[ -n "${NO_COLOR:-}" ]]; then
      c_bold=""; c_cyan=""; c_grn=""; c_yel=""; c_mag=""; c_dim=""; c_rst=""
    fi

    printf '\033[H'
    printf ' %sSSH Multisession Resume%s  |  client: %s%s%s  |  mode: %s\033[K\n' \
      "$c_cyan" "$c_rst" "$c_bold" "$(sm_ip_display "${current_ip:-local}")" "$c_rst" "$policy_mode"
    printf '%s\033[K\n' "$(sm_hr "$cols")"

    local list_budget=$(( (lines - 8) / 2 ))
    (( list_budget < 4 )) && list_budget=4
    (( list_budget > total )) && list_budget=$total

    local l_start=0
    if (( cursor >= list_budget )); then
      l_start=$((cursor - list_budget + 1))
    fi
    local l_end=$((l_start + list_budget))
    (( l_end > total )) && l_end=$total

    local idx kind tgt st badge desc ip_note line_txt
    for ((idx = l_start; idx < l_end; idx++)); do
      kind="${item_kind[$idx]}"
      tgt="${item_target[$idx]}"
      st="${item_state[$idx]}"
      case "$kind" in
        SESSION)
          case "$st" in
            open)    badge="[open]   " ;;
            cleared) badge="[cleared]" ;;
            empty)   badge="[empty]  " ;;
            *)       badge="[open]   " ;;
          esac
          ip_note=""
          [[ "${item_ip[$idx]}" != "-" ]] && ip_note="  ip:$(sm_ip_display "${item_ip[$idx]}")"
          desc="$(printf '%-16s %s %sw  %s · %s%s' \
            "$tgt" "$badge" "${item_win[$idx]}" "${item_cmd[$idx]}" "$(sm_shorten_path "${item_cwd[$idx]}")" "$ip_note")"
          ;;
        NEW)
          desc="$(printf '%-16s [create]      open fresh slot (%s)' '+ New terminal' "$tgt")"
          ;;
        SKIP)
          if [[ "$context" == "login" ]]; then
            desc="$(printf '%-16s [shell]       plain login shell (skip multiplexer)' '-> Plain shell')"
          else
            desc="$(printf '%-16s [exit]        close picker without switching' '-> Cancel')"
          fi
          ;;
        ACTIVE)
          ip_note=""
          [[ "${item_ip[$idx]}" != "-" ]] && ip_note=" @ $(sm_ip_display "${item_ip[$idx]}")"
          local self_note=""
          [[ -n "$current_sess" && "$tgt" == "$current_sess" ]] && self_note=" (this session)"
          desc="$(printf '%-16s [active]  %sw  attached%s%s - preview hidden' \
            "$tgt" "${item_win[$idx]}" "$ip_note" "$self_note")"
          ;;
      esac

      line_txt="$(printf '[%d] %s' "$((idx + 1))" "$desc")"
      line_txt="$(sm_sanitize_line "$line_txt" $((inner - 3)))"
      if (( idx == cursor )); then
        printf ' %s>%s %s%s%s\033[K\n' "$c_yel" "$c_rst" "$c_bold" "$line_txt" "$c_rst"
      else
        if [[ "$kind" == "ACTIVE" ]]; then
          printf '   %s%s%s\033[K\n' "$c_dim" "$line_txt" "$c_rst"
        else
          printf '   %s\033[K\n' "$line_txt"
        fi
      fi
    done

    printf '%s\033[K\n' "$(sm_hr "$cols")"

    # Preview box (strictly skips active sessions!)
    local cur_kind="${item_kind[$cursor]}"
    local cur_tgt="${item_target[$cursor]}"
    local cur_state="${item_state[$cursor]}"
    local preview_budget=$(( lines - (l_end - l_start) - 8 ))
    (( preview_budget < 4 )) && preview_budget=4

    local preview_header=""
    local -a preview_lines=()
    case "$cur_kind" in
      SESSION)
        preview_header="Preview: ${cur_tgt} (${cur_state} · ${item_win[$cursor]}w · ${item_cmd[$cursor]} · $(sm_shorten_path "${item_cwd[$cursor]}"))"
        local pl
        while IFS= read -r pl; do
          preview_lines+=("$pl")
        done < <(sm_render_preview_lines "$socket" "$cur_tgt" "$cur_state" "$preview_budget" $((inner - 3)) \
          "${item_cmd[$cursor]}" "${item_cwd[$cursor]}" "${item_hist[$cursor]}" "${item_ip[$cursor]}")
        ;;
      ACTIVE)
        preview_header="Preview: ${cur_tgt} (active - preview disabled)"
        local pl
        while IFS= read -r pl; do
          preview_lines+=("$pl")
        done < <(sm_render_preview_lines "$socket" "$cur_tgt" "active" "$preview_budget" $((inner - 3)) \
          "${item_cmd[$cursor]}" "${item_cwd[$cursor]}" "${item_hist[$cursor]}" "${item_ip[$cursor]}")
        ;;
      NEW)
        preview_header="Preview: + New terminal (${cur_tgt})"
        preview_lines=(
          "Creates and attaches a fresh managed tmux session (${cur_tgt})."
          "Existing detached and active sessions stay untouched."
        )
        ;;
      SKIP)
        if [[ "$context" == "login" ]]; then
          preview_header="Preview: Plain shell"
          preview_lines=(
            "Continues into a regular SSH shell without attaching tmux/screen."
            "Your saved policy is unchanged for future logins."
          )
        else
          preview_header="Preview: Cancel"
          preview_lines=("Exits the session picker without changing sessions.")
        fi
        ;;
    esac

    printf ' %s%s%s\033[K\n' "$c_grn" "$(sm_sanitize_line "$preview_header" "$inner")" "$c_rst"
    local p_idx
    for ((p_idx = 0; p_idx < preview_budget; p_idx++)); do
      if (( p_idx < ${#preview_lines[@]} )); then
        printf ' %s|%s %s\033[K\n' "$c_dim" "$c_rst" "$(sm_sanitize_line "${preview_lines[$p_idx]}" $((inner - 3)))"
      else
        printf ' %s|%s\033[K\n' "$c_dim" "$c_rst"
      fi
    done

    printf '%s\033[K\n' "$(sm_hr "$cols")"
    if [[ -n "$flash" ]]; then
      printf ' %s%s%s\033[K\n' "$c_yel" "$(sm_sanitize_line "$flash" "$inner")" "$c_rst"
      flash=""
    else
      printf ' %s[Up/Down]%s preview  %s[1-9/Enter]%s select  %s[n]%s new  %s[c]%s clean empty/cleared\033[K\n' \
        "$c_bold" "$c_rst" "$c_bold" "$c_rst" "$c_bold" "$c_rst" "$c_bold" "$c_rst"
    fi
    printf ' %s[t]%s transfer here  %s[d]%s drop detached  %s[i]%s IP manager  %s[s/q]%s plain shell\033[K\033[J' \
      "$c_bold" "$c_rst" "$c_bold" "$c_rst" "$c_bold" "$c_rst" "$c_bold" "$c_rst"

    sm_read_key "$total"

    local activate_idx=-1
    case "$SM_KEY" in
      UP|k|K)
        cursor=$(( (cursor - 1 + total) % total ))
        ;;
      DOWN|j|J)
        cursor=$(( (cursor + 1) % total ))
        ;;
      NUM:*)
        local num="${SM_KEY#NUM:}"
        if (( num >= 1 && num <= total )); then
          cursor=$((num - 1))
          activate_idx=$cursor
        else
          flash="Invalid selection [${num}] (choose 1-${total})."
        fi
        ;;
      ENTER)
        activate_idx=$cursor
        ;;
      n|N)
        chosen_action="NEW"
        chosen_target="$next_slot"
        break
        ;;
      s|S|q|Q|ESC)
        chosen_action="SKIP"
        chosen_target=""
        break
        ;;
      EOF)
        # Non-interactive closed stdin fallback: activate default highlighted option cleanly.
        activate_idx=$cursor
        ;;
      c|C)
        local clean_msg=""
        clean_msg="$(sm_cmd_sessions_clean --cleared 2>&1 || true)"
        flash="${clean_msg:-Cleaned empty/cleared sessions.}"
        cursor=-1
        ;;
      d|D)
        if [[ "${item_kind[$cursor]}" == "SESSION" ]]; then
          local drop_tgt="${item_target[$cursor]}"
          printf '\r\033[K %sDrop detached session %s? [y/N]: %s' "$c_mag" "$drop_tgt" "$c_rst"
          sm_read_key 1
          if [[ "$SM_KEY" == "y" || "$SM_KEY" == "Y" ]]; then
            flash="$(sm_cmd_session_drop "$drop_tgt" 2>&1 || true)"
            cursor=-1
          else
            flash="Drop cancelled."
          fi
        elif [[ "${item_kind[$cursor]}" == "ACTIVE" ]]; then
          flash="Refusing to drop active session (${item_target[$cursor]})."
        else
          flash="Highlight a detached session first to drop it."
        fi
        ;;
      t|T)
        if [[ "${item_kind[$cursor]}" == "SESSION" || "${item_kind[$cursor]}" == "ACTIVE" ]]; then
          local take_tgt="${item_target[$cursor]}"
          if [[ -n "$current_sess" && "$take_tgt" == "$current_sess" ]]; then
            flash="You are already inside ${take_tgt}."
          else
            chosen_action="TAKEOVER"
            chosen_target="$take_tgt"
            break
          fi
        else
          flash="Highlight a session first (or press [i] for full IP transfer)."
        fi
        ;;
      i|I)
        sm_tui_ip_screen "$current_ip"
        cursor=-1
        ;;
    esac

    if (( activate_idx >= 0 )); then
      case "${item_kind[$activate_idx]}" in
        SESSION)
          chosen_action="ATTACH"
          chosen_target="${item_target[$activate_idx]}"
          break
          ;;
        NEW)
          chosen_action="NEW"
          chosen_target="${item_target[$activate_idx]}"
          break
          ;;
        SKIP)
          chosen_action="SKIP"
          chosen_target=""
          break
          ;;
        ACTIVE)
          if [[ -n "$current_sess" && "${item_target[$activate_idx]}" == "$current_sess" ]]; then
            flash="Already attached to ${current_sess}."
          else
            flash="${item_target[$activate_idx]} is active elsewhere (preview hidden). Press [t] to transfer/takeover."
          fi
          ;;
      esac
    fi
  done

  sm_tui_leave
  trap - EXIT INT TERM HUP

  if [[ -n "$result_file" ]]; then
    printf '%s|%s\n' "$chosen_action" "$chosen_target" > "$result_file"
    return 0
  fi

  # Direct CLI execution (`ssh-multisession-resume pick`)
  case "$chosen_action" in
    SKIP|'')
      return 0
      ;;
    TAKEOVER)
      tmux -L "$socket" detach-client -s "=${chosen_target}" 2>/dev/null || true
      [[ -n "$current_ip" ]] && sm_record_connect "$current_ip" "$chosen_target"
      if [[ -n "$current_sess" ]]; then
        tmux -L "$socket" switch-client -t "=${chosen_target}"
      else
        tmux -L "$socket" attach-session -t "=${chosen_target}"
      fi
      ;;
    ATTACH)
      [[ -n "$current_ip" ]] && sm_record_connect "$current_ip" "$chosen_target"
      if [[ -n "$current_sess" ]]; then
        tmux -L "$socket" switch-client -t "=${chosen_target}"
      else
        tmux -L "$socket" attach-session -t "=${chosen_target}"
      fi
      ;;
    NEW)
      local script_dir tmux_conf
      script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
      tmux_conf="${SSH_AUTO_RESUME_TMUX_CONF:-${script_dir}/tmux-auto-resume.conf}"
      [[ -n "$current_ip" ]] && sm_record_connect "$current_ip" "$chosen_target"
      if [[ -n "$current_sess" ]]; then
        if [[ -r "$tmux_conf" ]]; then
          tmux -L "$socket" -f "$tmux_conf" new-session -d -s "$chosen_target"
        else
          tmux -L "$socket" new-session -d -s "$chosen_target"
        fi
        tmux -L "$socket" switch-client -t "=${chosen_target}"
      else
        if [[ -r "$tmux_conf" ]]; then
          tmux -L "$socket" -f "$tmux_conf" new-session -A -s "$chosen_target"
        else
          tmux -L "$socket" new-session -A -s "$chosen_target"
        fi
      fi
      ;;
  esac
}

# ============================================================
# CLI Dispatcher
# ============================================================

sm_main() {
  local action="${1:-sessions}"
  [[ $# -gt 0 ]] && shift

  case "$action" in
    sessions|list)
      local sub="${1:-list}"
      case "$sub" in
        list)
          sm_cmd_sessions_list
          ;;
        clean|prune)
          shift
          sm_cmd_sessions_clean "$@"
          ;;
        drop|kill|rm)
          shift
          sm_cmd_session_drop "$@"
          ;;
        transfer|move|mv)
          shift
          sm_cmd_session_transfer "$@"
          ;;
        *)
          sm_die "Unknown sessions subcommand: ${sub} (use list, clean, drop, or transfer)"
          ;;
      esac
      ;;
    ip|ips)
      local sub="${1:-show}"
      [[ $# -gt 0 ]] && shift
      case "$sub" in
        show|list|status)
          sm_cmd_ip_show "$@"
          ;;
        record)
          sm_record_connect "$@"
          ;;
        label|name|tag)
          sm_cmd_ip_label "$@"
          ;;
        unlabel|untag)
          sm_cmd_ip_unlabel "$@"
          ;;
        transfer|move|mv|migrate)
          sm_cmd_ip_transfer "$@"
          ;;
        drop|forget|rm|delete)
          sm_cmd_ip_drop "$@"
          ;;
        prune|clean|gc)
          sm_cmd_ip_prune "$@"
          ;;
        *)
          sm_die "Unknown ip subcommand: ${sub} (use show, label, unlabel, transfer, drop, or prune)"
          ;;
      esac
      ;;
    picker)
      sm_cmd_picker_config "$@"
      ;;
    pick|preview|login-pick)
      if [[ "$action" == "login-pick" ]]; then
        sm_run_picker --context login "$@"
      else
        sm_run_picker --context cli "$@"
      fi
      ;;
    record-connect)
      sm_record_connect "$@"
      ;;
    classify)
      # Direct test/inspection helper: classify SESSION_NAME
      local target="${1:?missing session name}"
      sm_ensure_tmux_tmpdir
      local rows="" line name attached windows panes state rest
      rows="$(sm_collect_tmux_sessions all)"
      while IFS= read -r line; do
        IFS='|' read -r name attached windows panes state rest <<< "$line"
        if [[ "$name" == "$target" ]]; then
          printf '%s\n' "$state"
          return 0
        fi
      done <<< "$rows"
      return 1
      ;;
    preview-text)
      # Direct test/inspection helper: preview-text SESSION_NAME [MAX_LINES] [MAX_COLS]
      local target="${1:?missing session name}"
      local mlines="${2:-10}" mcols="${3:-72}"
      sm_ensure_tmux_tmpdir
      local socket rows="" line name attached windows panes state cmd cwd hist owner_ip
      socket="$(sm_socket_name)"
      rows="$(sm_collect_tmux_sessions all)"
      while IFS= read -r line; do
        IFS='|' read -r name attached windows panes state cmd cwd hist owner_ip <<< "$line"
        if [[ "$name" == "$target" ]]; then
          sm_render_preview_lines "$socket" "$name" "$state" "$mlines" "$mcols" "$cmd" "$cwd" "$hist" "$owner_ip"
          return 0
        fi
      done <<< "$rows"
      return 1
      ;;
    resolve-tmpdir)
      sm_resolve_tmux_tmpdir
      ;;
    *)
      sm_die "Unknown session-manager action: ${action}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sm_main "$@"
fi
