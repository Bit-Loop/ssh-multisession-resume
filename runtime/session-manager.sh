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

# Byte-exact UTF-8 + ANSI SGR + 8-col tab-stop stream formatter.
# Works identically across gawk, mawk, and busybox awk under LC_ALL=C.
sm_format_stream_lines() {
  local max_cols="${1:-76}"
  local pan_x="${2:-0}"
  local keep_color="${3:-0}"
  local pad_right="${4:-0}"
  local report_meta="${5:-0}"
  local ellipsis="${6:-}"

  LC_ALL=C awk \
    -v max_cols="$max_cols" \
    -v pan_x="$pan_x" \
    -v keep_color="$keep_color" \
    -v pad_right="$pad_right" \
    -v report_meta="$report_meta" \
    -v ellipsis="$ellipsis" '
    BEGIN {
      for (b = 0; b < 256; b++) ord[sprintf("%c", b)] = b
      max_seen = 0
      line_count = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      lines[++line_count] = line
    }
    END {
      eff_max = max_cols
      for ( r = 1; r <= line_count; r++ ) {
        line = lines[r]
        n = length(line)
        # First pass for line width so ellipsis only appears when clipped
        i = 1; total_w = 0
        while (i <= n) {
          b1 = ord[substr(line, i, 1)]
          if (b1 == 27) {
            if (i + 1 <= n) {
              nx = substr(line, i + 1, 1)
              if (nx == "[") {
                j = i + 2
                while (j <= n) { cb = ord[substr(line, j, 1)]; if (cb >= 64 && cb <= 126) break; j++ }
                i = j + 1; continue
              } else if (nx == "]") {
                j = i + 2
                while (j <= n) {
                  cb = ord[substr(line, j, 1)]
                  if (cb == 7) { j++; break }
                  if (cb == 27 && j + 1 <= n && substr(line, j + 1, 1) == "\\") { j += 2; break }
                  j++
                }
                i = j; continue
              } else if (nx == "(" || nx == ")" || nx == "*" || nx == "+") {
                i += 3; continue
              }
            }
            i += 2; continue
          }
          if (b1 == 9) { total_w += 8 - (total_w % 8); i++; continue }
          if (b1 < 32 || b1 == 127) { i++; continue }
          seq_len = 1; cw = 1
          if (b1 >= 194 && b1 <= 223 && i + 1 <= n) { seq_len = 2; cw = 1 }
          else if (b1 >= 224 && b1 <= 239 && i + 2 <= n) {
            seq_len = 3; b2 = ord[substr(line, i + 1, 1)]
            if ((b1 == 225 && b2 >= 132 && b2 <= 133) || (b1 == 226 && b2 >= 186) ||
                (b1 >= 227 && b1 <= 233) || (b1 >= 234 && b1 <= 237 && !(b1 == 237 && b2 >= 160)) ||
                (b1 == 239 && b2 >= 164 && b2 <= 190)) cw = 2
          } else if (b1 >= 240 && b1 <= 244 && i + 3 <= n) { seq_len = 4; cw = 2 }
          total_w += cw
          i += seq_len
        }
        if (total_w > max_seen) max_seen = total_w
        widths[r] = total_w
      }

      if (report_meta) {
        printf "%d\n", max_seen
      }

      for ( r = 1; r <= line_count; r++ ) {
        line = lines[r]
        n = length(line)
        need_ellip = (ellipsis != "" && max_cols > 3 && widths[r] > pan_x + max_cols) ? 1 : 0
        limit_cols = need_ellip ? (max_cols - 1) : max_cols

        i = 1; col = 0; out = ""; out_cols = 0; active_sgr = ""; used_sgr = 0
        while (i <= n) {
          b1 = ord[substr(line, i, 1)]
          if (b1 == 27) {
            if (i + 1 <= n) {
              nx = substr(line, i + 1, 1)
              if (nx == "[") {
                j = i + 2
                while (j <= n) { cb = ord[substr(line, j, 1)]; if (cb >= 64 && cb <= 126) break; j++ }
                if (j <= n) {
                  seq = substr(line, i, j - i + 1)
                  if (substr(line, j, 1) == "m" && keep_color) {
                    if (seq == "\033[0m" || seq == "\033[m") active_sgr = ""
                    else active_sgr = active_sgr seq
                    if (col >= pan_x && out_cols < limit_cols) {
                      out = out seq
                      used_sgr = 1
                    }
                  }
                }
                i = j + 1; continue
              } else if (nx == "]") {
                j = i + 2
                while (j <= n) {
                  cb = ord[substr(line, j, 1)]
                  if (cb == 7) { j++; break }
                  if (cb == 27 && j + 1 <= n && substr(line, j + 1, 1) == "\\") { j += 2; break }
                  j++
                }
                i = j; continue
              } else if (nx == "(" || nx == ")" || nx == "*" || nx == "+") {
                i += 3; continue
              }
            }
            i += 2; continue
          }

          if (b1 == 9) {
            spaces = 8 - (col % 8)
            for (s = 0; s < spaces; s++) {
              if (col >= pan_x && out_cols < limit_cols) {
                if (out_cols == 0 && active_sgr != "") { out = out active_sgr; used_sgr = 1 }
                out = out " "; out_cols++
              }
              col++
            }
            i++; continue
          }

          if (b1 < 32 || b1 == 127) { i++; continue }

          seq_len = 1; cw = 1
          if (b1 >= 194 && b1 <= 223 && i + 1 <= n) { seq_len = 2; cw = 1 }
          else if (b1 >= 224 && b1 <= 239 && i + 2 <= n) {
            seq_len = 3; b2 = ord[substr(line, i + 1, 1)]
            if ((b1 == 225 && b2 >= 132 && b2 <= 133) || (b1 == 226 && b2 >= 186) ||
                (b1 >= 227 && b1 <= 233) || (b1 >= 234 && b1 <= 237 && !(b1 == 237 && b2 >= 160)) ||
                (b1 == 239 && b2 >= 164 && b2 <= 190)) cw = 2
          } else if (b1 >= 240 && b1 <= 244 && i + 3 <= n) { seq_len = 4; cw = 2 }

          glyph = substr(line, i, seq_len)
          if (col < pan_x && col + cw > pan_x) {
            if (out_cols < limit_cols) { out = out " "; out_cols++ }
          } else if (col >= pan_x) {
            if (out_cols + cw <= limit_cols) {
              if (out_cols == 0 && active_sgr != "") { out = out active_sgr; used_sgr = 1 }
              out = out glyph
              out_cols += cw
            } else if (out_cols < limit_cols) {
              out = out " "
              out_cols++
            }
          }
          col += cw
          i += seq_len
        }

        if (keep_color && used_sgr) {
          out = out "\033[0m"
        }
        if (need_ellip && out_cols < max_cols) {
          out = out ellipsis
          out_cols++
        }
        if (pad_right && out_cols < max_cols) {
          out = out sprintf("%*s", max_cols - out_cols, "")
        }
        printf "%s\n", out
      }
    }
  '
}

# Zero-fork ASCII fast-path sanitizer with UTF-8/tab fallback.
sm_sanitize_line() {
  local line="${1:-}" max_cols="${2:-76}"
  (( max_cols < 1 )) && { printf ''; return 0; }
  local LC_ALL=C
  if [[ "$line" != *[^$'\x20'-$'\x7e']* ]]; then
    if (( ${#line} > max_cols )); then
      if (( max_cols > 3 )); then
        printf '%s>' "${line:0:$((max_cols - 1))}"
      else
        printf '%s' "${line:0:$max_cols}"
      fi
    else
      printf '%s' "$line"
    fi
    return 0
  fi
  local formatted=""
  formatted="$(printf '%s\n' "$line" | sm_format_stream_lines "$max_cols" 0 0 0 0 ">")"
  printf '%s' "$formatted"
}

# Fit plain text to exact display width (pad right with spaces, clip with ellipsis if longer).
sm_fit_plain() {
  local text="${1:-}" width="${2:-16}" ellip="${3:->}"
  (( width < 1 )) && { printf ''; return 0; }
  local LC_ALL=C
  if [[ "$text" != *[^$'\x20'-$'\x7e']* ]]; then
    local len=${#text}
    if (( len > width )); then
      if (( width > 3 )); then
        printf '%s%s' "${text:0:$((width - 1))}" "$ellip"
      else
        printf '%s' "${text:0:$width}"
      fi
    elif (( len < width )); then
      printf '%-*s' "$width" "$text"
    else
      printf '%s' "$text"
    fi
    return 0
  fi
  local formatted=""
  formatted="$(printf '%s\n' "$text" | sm_format_stream_lines "$width" 0 0 1 0 "$ellip")"
  printf '%s' "$formatted"
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
  if (( count > start )); then
    printf '%s\n' "${all_lines[@]:$start:$((count - start))}" | sm_format_stream_lines "$max_cols" 0 0 0 0 ">"
  fi
}

# Rich TUI preview capture: returns header line "pane_w|pane_h|total_lines|max_src_width|start_line"
# followed by exact `max_lines` padded lines (preserving safe SGR colors when keep_color=1).
# STRICT INVARIANT: Never calls capture-pane on active/attached sessions.
sm_capture_tui_preview() {
  local socket="$1"
  local session="$2"
  local state="$3"
  local max_lines="${4:-10}"
  local max_cols="${5:-72}"
  local pane_cmd="${6:-shell}"
  local pane_path="${7:-~}"
  local history_size="${8:-0}"
  local owner_ip="${9:--}"
  local pan_x="${10:-0}"
  local keep_color="${11:-1}"

  local live_info="" live_attached="0" pane_w="80" pane_h="24"
  if [[ "$state" == "active" ]] || sm_is_reserved "tmux-${session}"; then
    live_attached="1"
  else
    live_info="$(tmux -L "$socket" display-message -p -t "=${session}:" '#{session_attached}|#{pane_width}|#{pane_height}' 2>/dev/null || printf '1|80|24')"
    IFS='|' read -r live_attached pane_w pane_h <<< "$live_info"
    [[ -n "$live_attached" ]] || live_attached="1"
    [[ "$pane_w" =~ ^[0-9]+$ ]] || pane_w=80
    [[ "$pane_h" =~ ^[0-9]+$ ]] || pane_h=24
  fi

  if [[ "$live_attached" != "0" ]]; then
    printf '0|0|7|0|0\n'
    local -a msg=(
      "[Active session - live preview disabled]"
      ""
      "This terminal is currently attached by an active client (IP: $(sm_ip_display "$owner_ip"))."
      "Active sessions are strictly isolated and never captured or previewed."
      ""
      "Tip: Press [t] only if your previous SSH connection dropped and you want"
      "     to detach the stale client and transfer this session here."
    )
    printf '%s\n' "${msg[@]}" | sm_format_stream_lines "$max_cols" 0 0 1 0 ">"
    return 0
  fi

  local short_cwd
  short_cwd="$(sm_shorten_path "$pane_path")"

  if [[ "$state" == "empty" ]]; then
    printf '%s|%s|4|0|0\n' "$pane_w" "$pane_h"
    local -a msg=(
      "[Empty terminal - untouched idle ${pane_cmd} in ${short_cwd}]"
      ""
      "No running foreground/background child processes or scrollback history."
      "Press [Enter] to reuse this clean slot, or [c] to prune idle shells."
    )
    printf '%s\n' "${msg[@]}" | sm_format_stream_lines "$max_cols" 0 0 1 0 ">"
    return 0
  fi

  if [[ "$state" == "cleared" ]]; then
    printf '%s|%s|4|0|0\n' "$pane_w" "$pane_h"
    local -a msg=(
      "[Cleared terminal - idle ${pane_cmd} in ${short_cwd} · scrollback: ${history_size} lines]"
      ""
      "Screen was cleared (Ctrl-L / clear); no active foreground or child jobs."
      "Press [Enter] to resume here, or [c] to clean empty & cleared terminals."
    )
    printf '%s\n' "${msg[@]}" | sm_format_stream_lines "$max_cols" 0 0 1 0 ">"
    return 0
  fi

  local raw=""
  if (( keep_color == 1 )); then
    if ! raw="$(tmux -L "$socket" capture-pane -e -p -t "=${session}:" 2>/dev/null)"; then
      printf '%s|%s|1|0|0\n' "$pane_w" "$pane_h"
      printf '%s\n' "(preview unavailable)" | sm_format_stream_lines "$max_cols" 0 0 1 0 ">"
      return 0
    fi
  else
    if ! raw="$(tmux -L "$socket" capture-pane -p -t "=${session}:" 2>/dev/null)"; then
      printf '%s|%s|1|0|0\n' "$pane_w" "$pane_h"
      printf '%s\n' "(preview unavailable)" | sm_format_stream_lines "$max_cols" 0 0 1 0 ">"
      return 0
    fi
  fi

  local -a all_lines=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    all_lines+=("$line")
  done <<< "$raw"

  # Strip ANSI temporarily just to check trailing blank lines accurately
  local count=${#all_lines[@]}
  while (( count > 0 )); do
    local check="${all_lines[$((count - 1))]}"
    check="$(printf '%s' "$check" | sed $'s/\033\\[[0-9;:]*[A-Za-z]//g')"
    if [[ -z "${check//[[:space:]]/}" ]]; then
      count=$((count - 1))
    else
      break
    fi
  done

  if (( count == 0 )); then
    printf '%s|%s|1|0|0\n' "$pane_w" "$pane_h"
    printf '%s\n' "(screen currently blank · ${pane_cmd} in ${short_cwd})" | sm_format_stream_lines "$max_cols" 0 0 1 0 ">"
    return 0
  fi

  local start=0
  if (( count > max_lines )); then
    start=$((count - max_lines))
  fi

  local formatted_out="" max_src_w="0"
  formatted_out="$(printf '%s\n' "${all_lines[@]:$start:$((count - start))}" | sm_format_stream_lines "$max_cols" "$pan_x" "$keep_color" 1 1 "")"
  max_src_w="${formatted_out%%$'\n'*}"
  [[ "$max_src_w" =~ ^[0-9]+$ ]] || max_src_w=0
  printf '%s|%s|%s|%s|%s\n' "$pane_w" "$pane_h" "$count" "$max_src_w" "$start"
  if [[ "$formatted_out" == *$'\n'* ]]; then
    printf '%s\n' "${formatted_out#*$'\n'}"
  fi
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
SM_FORCE_TTY=0
SM_COLS=80
SM_LINES=24
SM_WINCH=0
SM_ACTIVE_RESULT_FILE=""
SM_LINE_CANCELLED=0

# Theme & glyph globals populated by sm_init_theme
SM_UTF8=1
SM_COLOR=1
C_RST="" C_BOLD="" C_DIM=""
C_BORDER="" C_BRAND="" C_ACCENT="" C_TEXT="" C_MUTED=""
C_OPEN="" C_IDLE="" C_EMPTY="" C_ACTIVE="" C_NEW="" C_WARN="" C_ERR=""
C_SEL_BG="" C_KEY_BG="" C_KEY_FG=""
G_TL="+" G_TR="+" G_BL="+" G_BR="+" G_H="-" G_V="|" G_ML="+" G_MR="+"
G_BAR=">" G_THUMB="#" G_DOT_OPEN="*" G_DOT_IDLE="o" G_DOT_EMPTY="." G_DOT_ACT="#"
G_NEW="+" G_SKIP="->" G_CHECK="+" G_SEP="|"

sm_init_theme() {
  local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "$loc" == *[Uu][Tt][Ff]-8* || "$loc" == *[Uu][Tt][Ff]8* ]]; then
    SM_UTF8=1
  elif [[ -z "$loc" ]]; then
    export LC_CTYPE="C.UTF-8" 2>/dev/null || true
    SM_UTF8=1
  else
    SM_UTF8=0
  fi

  if (( SM_UTF8 == 1 )); then
    G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"; G_H="─"; G_V="│"; G_ML="├"; G_MR="┤"
    G_BAR="▎"; G_THUMB="┃"; G_DOT_OPEN="●"; G_DOT_IDLE="◌"; G_DOT_EMPTY="○"; G_DOT_ACT="◆"
    G_NEW="+"; G_SKIP="→"; G_CHECK="✓"; G_SEP="·"
  else
    G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"; G_H="-"; G_V="|"; G_ML="+"; G_MR="+"
    G_BAR=">"; G_THUMB="#"; G_DOT_OPEN="*"; G_DOT_IDLE="o"; G_DOT_EMPTY="."; G_DOT_ACT="#"
    G_NEW="+"; G_SKIP=">"; G_CHECK="+"; G_SEP="|"
  fi

  if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
    SM_COLOR=0
    C_RST=""; C_BOLD=""; C_DIM=""
    C_BORDER=""; C_BRAND=""; C_ACCENT=""; C_TEXT=""; C_MUTED=""
    C_OPEN=""; C_IDLE=""; C_EMPTY=""; C_ACTIVE=""; C_NEW=""; C_WARN=""; C_ERR=""
    C_SEL_BG=""; C_KEY_BG=""; C_KEY_FG=""
    return 0
  fi

  SM_COLOR=1
  C_RST=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'

  case "${TERM:-}" in
    *256color*|*truecolor*|xterm*|tmux*|screen*|kitty*|ghostty*|alacritty*|wezterm*|foot*)
      C_BORDER=$'\033[38;5;239m'
      C_BRAND=$'\033[1;38;5;81m'
      C_ACCENT=$'\033[38;5;81m'
      C_TEXT=$'\033[38;5;253m'
      C_MUTED=$'\033[38;5;244m'
      C_OPEN=$'\033[38;5;78m'
      C_IDLE=$'\033[38;5;215m'
      C_EMPTY=$'\033[38;5;243m'
      C_ACTIVE=$'\033[38;5;141m'
      C_NEW=$'\033[38;5;117m'
      C_WARN=$'\033[1;38;5;221m'
      C_ERR=$'\033[1;38;5;204m'
      C_SEL_BG=$'\033[48;5;236m'
      C_KEY_BG=$'\033[48;5;237m\033[38;5;117m'
      C_KEY_FG=$'\033[38;5;247m'
      ;;
    *)
      C_BORDER=$'\033[2;37m'
      C_BRAND=$'\033[1;36m'
      C_ACCENT=$'\033[36m'
      C_TEXT=$'\033[0;37m'
      C_MUTED=$'\033[2;37m'
      C_OPEN=$'\033[1;32m'
      C_IDLE=$'\033[1;33m'
      C_EMPTY=$'\033[2;37m'
      C_ACTIVE=$'\033[1;35m'
      C_NEW=$'\033[1;36m'
      C_WARN=$'\033[1;33m'
      C_ERR=$'\033[1;31m'
      C_SEL_BG=$'\033[7m'
      C_KEY_BG=$'\033[1;36m'
      C_KEY_FG=$'\033[0;37m'
      ;;
  esac
}

sm_tui_enter() {
  if [[ -t 0 && -t 1 ]]; then
    SM_SAVED_STTY="$(stty -g <&0 2>/dev/null || true)"
    # -isig intercepts Ctrl+C (\x03), Ctrl+D (\x04), Ctrl+Z (\x1a) cleanly as bytes
    # without sending SIGINT/SIGTSTP to the parent login shell.
    stty -echo -icanon -isig min 1 time 0 <&0 2>/dev/null || true
    # Enter alt-screen (?1049h), hide cursor (?25l), disable line auto-wrap (?7l)
    printf '\033[?1049h\033[?25l\033[?7l\033[2J\033[H'
    SM_TUI_ACTIVE=1
  fi
}

sm_tui_leave() {
  if (( SM_TUI_ACTIVE == 1 )); then
    printf '\033[0m\033[?2026l\033[?7h\033[?25h\033[?1049l'
    if [[ -n "$SM_SAVED_STTY" ]]; then
      stty "$SM_SAVED_STTY" <&0 2>/dev/null || true
    else
      stty sane <&0 2>/dev/null || true
    fi
    SM_TUI_ACTIVE=0
  fi
}

sm_handle_signal() {
  sm_tui_leave
  if [[ -n "${SM_ACTIVE_RESULT_FILE:-}" ]]; then
    printf 'SKIP|\n' > "$SM_ACTIVE_RESULT_FILE" 2>/dev/null || true
  fi
  exit 130
}

# Inline raw line editor that keeps -isig active so Ctrl+C / Esc cancels cleanly.
sm_tui_read_line() {
  local prompt="$1"
  local buf="" ch="" nx1="" nx2=""
  SM_LINE_CANCELLED=0

  if (( SM_FORCE_TTY == 1 )); then
    IFS= read -r buf || true
    printf '%s' "$buf"
    return 0
  fi

  printf '\033[?25h' >&2
  while true; do
    printf '\r\033[K%s%s' "$prompt" "$buf" >&2
    if ! IFS= read -r -s -n 1 ch; then
      break
    fi
    case "$ch" in
      ''|$'\n'|$'\r')
        break
        ;;
      $'\x03'|$'\x04')
        SM_LINE_CANCELLED=1
        buf=""
        break
        ;;
      $'\e')
        # Drain any arrow sequence, otherwise treat bare Esc as cancel
        if IFS= read -r -s -n 1 -t 0.05 nx1; then
          IFS= read -r -s -n 2 -t 0.05 nx2 || true
        else
          SM_LINE_CANCELLED=1
          buf=""
          break
        fi
        ;;
      $'\x7f'|$'\x08')
        if [[ -n "$buf" ]]; then
          buf="${buf%?}"
        fi
        ;;
      $'\x15')
        buf=""
        ;;
      *)
        if [[ "$ch" != [$'\x00'-$'\x1f'] ]] && (( ${#buf} < 48 )); then
          buf="${buf}${ch}"
        fi
        ;;
    esac
  done
  printf '\033[?25l' >&2
  printf '%s' "$buf"
}

# Reads one logical key into SM_KEY:
# UP, DOWN, LEFT, RIGHT, HOME, PGDN, PGUP, ENTER, ESC, CTRL_C, CTRL_D, REDRAW, TICK, EOF, or literal / NUM:N
SM_KEY=""
sm_read_key() {
  local max_num="${1:-9}"
  local allow_tick="${2:-0}"
  local ch="" next1="" next2="" next3="" rc=0
  SM_KEY=""

  if (( SM_WINCH == 1 )); then
    SM_WINCH=0
    SM_KEY="TICK"
    return 0
  fi

  if (( allow_tick == 1 && SM_FORCE_TTY == 0 )); then
    IFS= read -r -s -n 1 -t 0.25 ch || rc=$?
    if (( rc != 0 )); then
      if (( rc > 128 || SM_WINCH == 1 )); then
        SM_WINCH=0
        SM_KEY="TICK"
        return 0
      fi
      SM_KEY="EOF"
      return 0
    fi
  else
    if ! IFS= read -r -s -n 1 ch; then
      SM_KEY="EOF"
      return 0
    fi
  fi

  case "$ch" in
    ''|$'\n'|$'\r')
      SM_KEY="ENTER"
      return 0
      ;;
    $'\x03')
      SM_KEY="CTRL_C"
      return 0
      ;;
    $'\x04')
      SM_KEY="CTRL_D"
      return 0
      ;;
    $'\x1a')
      # Ignore Ctrl+Z so login shell hooks can never be suspended into background
      SM_KEY="TICK"
      return 0
      ;;
    $'\x0c')
      SM_KEY="REDRAW"
      return 0
      ;;
    $'\e')
      if IFS= read -r -s -n 1 -t 0.08 next1; then
        if [[ "$next1" == "[" || "$next1" == "O" ]]; then
          if IFS= read -r -s -n 1 -t 0.08 next2; then
            case "$next2" in
              A) SM_KEY="UP"; return 0 ;;
              B) SM_KEY="DOWN"; return 0 ;;
              C) SM_KEY="RIGHT"; return 0 ;;
              D) SM_KEY="LEFT"; return 0 ;;
              H) SM_KEY="HOME"; return 0 ;;
              F) SM_KEY="END"; return 0 ;;
              [0-9])
                IFS= read -r -s -n 1 -t 0.05 next3 || true
                case "${next2}${next3}" in
                  1~|7~) SM_KEY="HOME"; return 0 ;;
                  4~|8~) SM_KEY="END"; return 0 ;;
                  5~)    SM_KEY="PGUP"; return 0 ;;
                  6~)    SM_KEY="PGDN"; return 0 ;;
                esac
                SM_KEY="TICK"
                return 0
                ;;
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
        if IFS= read -r -s -n 1 -t 0.35 next1; then
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

# Queries real terminal dimensions directly on fd 0 / /dev/tty (never broken by subshell stdout pipes!).
sm_update_term_dims() {
  local cols="" lines="" sz=""
  if (( SM_FORCE_TTY == 0 )); then
    if [[ -t 0 ]] && sz="$(stty size <&0 2>/dev/null)" && [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
      lines="${BASH_REMATCH[1]}"
      cols="${BASH_REMATCH[2]}"
    elif [[ -r /dev/tty ]] && sz="$(stty size </dev/tty 2>/dev/null)" && [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
      lines="${BASH_REMATCH[1]}"
      cols="${BASH_REMATCH[2]}"
    fi
  fi
  [[ -n "$cols" && "$cols" != "0" ]] || cols="${COLUMNS:-80}"
  [[ -n "$lines" && "$lines" != "0" ]] || lines="${LINES:-24}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
  (( cols < 60 )) && cols=60
  (( lines < 18 )) && lines=18
  SM_COLS="$cols"
  SM_LINES="$lines"
}

sm_repeat_glyph() {
  local glyph="$1" count="$2"
  (( count <= 0 )) && { printf ''; return 0; }
  local pad=""
  printf -v pad '%*s' "$count" ''
  printf '%s' "${pad// /$glyph}"
}

# Build a horizontal border line of exact SM_COLS display width:
# left_corner + "─ " + styled_left (plain width left_w) + " " + ─*fill + (" " + styled_right + " ─") + right_corner
sm_box_rule() {
  local l_corner="$1" r_corner="$2"
  local left_styled="$3" left_w="$4"
  local right_styled="${5:-}" right_w="${6:-0}"
  local inner=$((SM_COLS - 2))

  if (( left_w == 0 && right_w == 0 )); then
    printf '%s%s%s%s' "$C_BORDER" "$l_corner" "$(sm_repeat_glyph "$G_H" "$inner")" "${r_corner}${C_RST}"
    return 0
  fi

  local used=0
  (( left_w > 0 )) && used=$((used + left_w + 3))
  (( right_w > 0 )) && used=$((used + right_w + 3))

  if (( used > inner )); then
    # Fallback on very narrow screens: drop right ornament first
    right_styled=""
    right_w=0
    used=$(( left_w > 0 ? left_w + 3 : 0 ))
    if (( used > inner )); then
      printf '%s%s%s%s' "$C_BORDER" "$l_corner" "$(sm_repeat_glyph "$G_H" "$inner")" "${r_corner}${C_RST}"
      return 0
    fi
  fi

  local fill=$((inner - used))
  local out="${C_BORDER}${l_corner}"
  if (( left_w > 0 )); then
    out+="${G_H} ${C_RST}${left_styled}${C_BORDER} "
  fi
  out+="$(sm_repeat_glyph "$G_H" "$fill")"
  if (( right_w > 0 )); then
    out+=" ${C_RST}${right_styled}${C_BORDER} ${G_H}"
  fi
  out+="${r_corner}${C_RST}"
  printf '%s' "$out"
}

sm_pulse_glyph() {
  local tick="${1:-0}"
  if (( SM_UTF8 == 0 )); then
    printf '*'
    return 0
  fi
  case $(( tick % 4 )) in
    0|2) printf '●' ;;
    1)   printf '◉' ;;
    3)   printf '∙' ;;
  esac
}

sm_keycap() {
  local k="$1" lbl="$2"
  if (( SM_COLOR == 1 )); then
    printf '%s %s %s %s%s%s' "$C_KEY_BG" "$k" "$C_RST" "$C_KEY_FG" "$lbl" "$C_RST"
  else
    printf '[%s] %s' "$k" "$lbl"
  fi
}

# Subtle non-blocking 3-frame card curtain reveal (~48ms total) on interactive TTY.
sm_play_intro_animation() {
  (( SM_FORCE_TTY == 0 && SM_COLOR == 1 && SM_TUI_ACTIVE == 1 )) || return 0
  # Skip immediately if user already buffered a keystroke!
  local ready=""
  if IFS= read -r -s -n 0 -t 0.001 ready 2>/dev/null; then
    return 0
  fi

  sm_update_term_dims
  local step h top mid r buf
  for step in 1 2; do
    if (( step == 1 )); then
      h=$(( SM_LINES / 3 ))
    else
      h=$(( (SM_LINES * 2) / 3 ))
    fi
    (( h < 4 )) && h=4
    top=$(( (SM_LINES - h) / 2 ))
    buf=$'\033[?2026h\033[H'
    for ((r = 0; r < SM_LINES; r++)); do
      if (( r == top )); then
        buf+="$(sm_box_rule "$G_TL" "$G_TR" "${C_BRAND}SSH Multisession Resume${C_RST}" 23 "" 0)"
      elif (( r == top + h - 1 )); then
        buf+="$(sm_box_rule "$G_BL" "$G_BR" "" 0 "" 0)"
      elif (( r > top && r < top + h - 1 )); then
        buf+="${C_BORDER}${G_V}${C_RST}$(printf '%*s' $((SM_COLS - 2)) '')${C_BORDER}${G_V}${C_RST}"
      else
        buf+=$'\033[K'
      fi
      (( r < SM_LINES - 1 )) && buf+=$'\n'
    done
    buf+=$'\033[?2026l'
    printf '%s' "$buf"
    sleep 0.022 2>/dev/null || true
  done
}

# Subtle 50ms launch confirmation banner in footer on interactive attach/create.
sm_play_connect_flash() {
  local label="$1"
  (( SM_FORCE_TTY == 0 && SM_COLOR == 1 && SM_TUI_ACTIVE == 1 )) || return 0
  sm_update_term_dims
  local inner=$((SM_COLS - 2))
  local msg=" ${G_CHECK} Connecting to ${label}..."
  local pad_len=$(( inner - ${#msg} ))
  (( pad_len < 0 )) && pad_len=0
  printf '\033[?2026h\033[%d;1H%s%s%s%s%s%*s%s%s%s\033[?2026l' \
    "$((SM_LINES - 1))" \
    "$C_BORDER" "$G_V" "$C_RST" \
    "$C_OPEN" "$C_BOLD$msg" "$pad_len" "" "$C_RST" \
    "$C_BORDER" "$G_V$C_RST"
  sleep 0.05 2>/dev/null || true
}

# Interactive IP Manager sub-screen invoked via [i] inside the Picker.
sm_tui_ip_screen() {
  local current_ip="$1"
  local current_safe
  current_safe="$(sm_sanitize "$current_ip")"
  local cursor=-1 flash="" tick=0
  local cached_rows="" cache_ticks=0

  while true; do
    sm_update_term_dims
    local cols="$SM_COLS" lines="$SM_LINES"
    local inner=$((cols - 2))
    local content_w=$((inner - 2))

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

    if [[ -z "$cached_rows" ]] || (( cache_ticks >= 4 || SM_FORCE_TTY == 1 )); then
      cached_rows="$(sm_collect_tmux_sessions user)"
      cache_ticks=0
    fi

    local cur_disp pulse_ch title_styled right_ascii right_styled
    cur_disp="$(sm_sanitize_line "$(sm_ip_display "${current_ip:-local}")" 36)"
    pulse_ch="$(sm_pulse_glyph "$tick")"
    title_styled="${C_ACCENT}${pulse_ch}${C_RST} ${C_BRAND}IP & Session Management${C_RST}"
    right_ascii="current ${cur_disp} | ${total} IPs"
    right_styled="${C_MUTED}current${C_RST} ${C_TEXT}${C_BOLD}${cur_disp}${C_RST}${C_MUTED} ${G_SEP} ${total} IPs${C_RST}"

    local buf=""
    (( SM_TUI_ACTIVE == 1 )) && buf+=$'\033[?2026h'
    buf+=$'\033[H'
    buf+="$(sm_box_rule "$G_TL" "$G_TR" "$title_styled" 25 "$right_styled" "${#right_ascii}")"$'\n'

    # Layout math: top(1) + list_h + div(1) + details(4) + div(1) + footer(2) + bottom(1) = lines
    local list_h=$(( lines - 10 ))
    (( list_h < 4 )) && list_h=4

    if (( total == 0 )); then
      local empty_msg
      empty_msg="$(sm_fit_plain "  (no stored IP records yet)" "$inner")"
      buf+="${C_BORDER}${G_V}${C_RST}${C_MUTED}${empty_msg}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
      local r_pad
      for ((r_pad = 1; r_pad < list_h; r_pad++)); do
        buf+="${C_BORDER}${G_V}${C_RST}$(printf '%*s' "$inner" '')${C_BORDER}${G_V}${C_RST}"$'\n'
      done
    else
      local start=0
      if (( cursor >= list_h )); then start=$((cursor - list_h + 1)); fi
      local end=$((start + list_h))
      (( end > total )) && end=$total

      local w_ip=28 w_pol=12 w_seen=10
      if (( content_w >= 100 )); then w_ip=34; w_pol=14; w_seen=12; fi
      local w_sess=$(( content_w - 6 - w_ip - w_pol - w_seen - 6 ))
      (( w_sess < 10 )) && w_sess=10

      local idx safe meta raw label pol seen sess_str tag num_tag c_ip c_pol c_seen c_sess plain_row
      for ((idx = start; idx < end; idx++)); do
        safe="${ip_keys[$idx]}"
        meta="$(sm_ip_meta_path "$safe")"
        raw="$(sm_meta_get "$meta" raw_ip)"
        [[ -n "$raw" ]] || raw="$safe"
        label="$(sm_meta_get "$meta" label)"
        pol="$(sm_ip_policy "$safe")"
        seen="$(sm_format_age "$(sm_meta_get "$meta" last_seen)")"
        sess_str="$(sm_sessions_for_safe_ip "$safe" "$cached_rows")"
        [[ -n "$sess_str" ]] || sess_str="-"
        tag=""
        [[ -n "$current_safe" && "$safe" == "$current_safe" ]] && tag=" [you]"

        printf -v num_tag '[%d]' "$((idx + 1))"
        num_tag="$(sm_fit_plain "$num_tag" 4)"
        c_ip="$(sm_fit_plain "${raw}${label:+ ($label)}${tag}" "$w_ip")"
        c_pol="$(sm_fit_plain "mode:${pol}" "$w_pol")"
        c_seen="$(sm_fit_plain "$seen" "$w_seen")"
        c_sess="$(sm_fit_plain "$sess_str" "$w_sess")"
        plain_row="$(sm_fit_plain "${num_tag} ${c_ip}  ${c_pol}  ${c_seen}  ${c_sess}" "$content_w")"

        if (( idx == cursor )); then
          buf+="${C_BORDER}${G_V}${C_RST}${C_SEL_BG}${C_ACCENT}${G_BAR}${C_RST}${C_SEL_BG} ${C_BOLD}${C_TEXT}${plain_row}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
        else
          buf+="${C_BORDER}${G_V}${C_RST}  ${C_TEXT}${plain_row}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
        fi
      done

      local rendered=$((end - start))
      local r_pad
      for ((r_pad = rendered; r_pad < list_h; r_pad++)); do
        buf+="${C_BORDER}${G_V}${C_RST}$(printf '%*s' "$inner" '')${C_BORDER}${G_V}${C_RST}"$'\n'
      done
    fi

    buf+="$(sm_box_rule "$G_ML" "$G_MR" "${C_ACCENT}Selected Client Details${C_RST}" 23 "" 0)"$'\n'

    if (( total > 0 )); then
      local sel_safe="${ip_keys[$cursor]}"
      local sel_meta sel_pol sel_cnt sel_sess sel_first d1 d2 d3 d4
      sel_meta="$(sm_ip_meta_path "$sel_safe")"
      sel_pol="$(sm_ip_policy "$sel_safe")"
      sel_cnt="$(sm_meta_get "$sel_meta" connect_count)"
      sel_first="$(sm_format_age "$(sm_meta_get "$sel_meta" first_seen)")"
      sel_sess="$(sm_sessions_for_safe_ip "$sel_safe" "$cached_rows")"

      d1="$(sm_fit_plain "  Address     : $(sm_ip_display "$sel_safe")  (key: ${sel_safe})" "$inner")"
      d2="$(sm_fit_plain "  Policy Mode : ${sel_pol}   ·   Connections: ${sel_cnt:-0}   ·   First seen: ${sel_first}" "$inner")"
      d3="$(sm_fit_plain "  Sessions    : ${sel_sess:-none}" "$inner")"
      d4="$(sm_fit_plain "  Actions     : [t] migrates policy + sessions to ${current_ip:-current IP} · [x] safely returns slots to global pool" "$inner")"
      buf+="${C_BORDER}${G_V}${C_RST}${C_BOLD}${C_TEXT}${d1}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
      buf+="${C_BORDER}${G_V}${C_RST}${C_TEXT}${d2}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
      buf+="${C_BORDER}${G_V}${C_RST}${C_OPEN}${d3}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
      buf+="${C_BORDER}${G_V}${C_RST}${C_MUTED}${d4}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
    else
      local r_pad
      for ((r_pad = 0; r_pad < 4; r_pad++)); do
        buf+="${C_BORDER}${G_V}${C_RST}$(printf '%*s' "$inner" '')${C_BORDER}${G_V}${C_RST}"$'\n'
      done
    fi

    buf+="$(sm_box_rule "$G_ML" "$G_MR" "" 0 "" 0)"$'\n'

    if [[ -n "$flash" ]]; then
      local fl_line
      fl_line="$(sm_fit_plain "  ${flash}" "$inner")"
      buf+="${C_BORDER}${G_V}${C_RST}${C_WARN}${fl_line}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
      flash=""
    else
      local f1
      f1="$(sm_fit_plain "  [Up/Down/1-9] select IP   [t] transfer -> current IP   [m] cycle policy (default/multi/single/per-client/skip)" "$inner")"
      buf+="${C_BORDER}${G_V}${C_RST}${C_KEY_FG}${f1}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
    fi
    local f2
    f2="$(sm_fit_plain "  [l] label device   [x] drop IP (migrates sessions safely)   [b / Esc / q / Ctrl+C] back to session picker" "$inner")"
    buf+="${C_BORDER}${G_V}${C_RST}${C_MUTED}${f2}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
    buf+="$(sm_box_rule "$G_BL" "$G_BR" "" 0 "" 0)"
    (( SM_TUI_ACTIVE == 1 )) && buf+=$'\033[?2026l'

    printf '%s' "$buf"

    sm_read_key "$total" 1
    case "$SM_KEY" in
      TICK)
        tick=$((tick + 1))
        cache_ticks=$((cache_ticks + 1))
        ;;
      REDRAW)
        printf '\033[2J'
        cached_rows=""
        ;;
      UP|k|K)
        (( total > 0 )) && cursor=$(( (cursor - 1 + total) % total ))
        ;;
      DOWN|j|J)
        (( total > 0 )) && cursor=$(( (cursor + 1) % total ))
        ;;
      HOME)
        cursor=0
        ;;
      END)
        (( total > 0 )) && cursor=$((total - 1))
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
            cached_rows=""
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
          local new_lbl="" l_safe="${ip_keys[$cursor]}" l_raw
          l_raw="$(sm_meta_get "$(sm_ip_meta_path "$l_safe")" raw_ip)"
          [[ -n "$l_raw" ]] || l_raw="$l_safe"
          printf '\033[%d;2H' "$((lines - 2))"
          new_lbl="$(sm_tui_read_line " Label for ${l_raw} (Enter to save, blank to clear, Esc/Ctrl+C cancel): ")"
          if (( SM_LINE_CANCELLED == 1 )); then
            flash="Label edit cancelled."
          else
            new_lbl="$(sm_sanitize_label "$new_lbl")"
            if [[ -n "$new_lbl" ]]; then
              sm_cmd_ip_label "$l_raw" "$new_lbl" >/dev/null
              flash="Labeled ${l_raw} as '${new_lbl}'."
            else
              sm_cmd_ip_unlabel "$l_raw" >/dev/null
              flash="Cleared label for ${l_raw}."
            fi
          fi
        fi
        ;;
      x|X)
        if (( total > 0 )); then
          local d_safe="${ip_keys[$cursor]}" d_raw
          d_raw="$(sm_meta_get "$(sm_ip_meta_path "$d_safe")" raw_ip)"
          [[ -n "$d_raw" ]] || d_raw="$d_safe"
          flash="$(sm_cmd_ip_drop "$d_raw" 2>&1 || true)"
          cached_rows=""
        fi
        ;;
      b|B|q|Q|ESC|CTRL_C|CTRL_D|EOF|ENTER)
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

  SM_FORCE_TTY="$force_tty"
  SM_ACTIVE_RESULT_FILE="$result_file"
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
  sm_init_theme

  local socket current_ip current_sess
  socket="$(sm_socket_name)"
  current_ip="$(sm_current_ip)"
  current_sess="$(sm_current_tmux_session)"

  local cursor=-1 prev_cursor=-1 pan_x=0 flash="" flash_kind="info"
  local chosen_action="" chosen_target="" tick=0
  local cached_rows="" cache_ticks=0

  trap 'sm_tui_leave' EXIT
  trap 'sm_handle_signal' INT TERM HUP
  trap 'SM_WINCH=1' WINCH

  if (( force_tty == 0 )); then
    sm_tui_enter
    sm_play_intro_animation
  fi

  while true; do
    sm_update_term_dims
    local cols="$SM_COLS" lines="$SM_LINES"
    local inner=$((cols - 2))
    local content_w=$((inner - 2))

    if [[ -z "$cached_rows" ]] || (( cache_ticks >= 4 || force_tty == 1 )); then
      cached_rows="$(sm_collect_tmux_sessions user)"
      cache_ticks=0
    fi
    local rows="$cached_rows"

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
    if (( cursor != prev_cursor )); then
      pan_x=0
      prev_cursor=$cursor
    fi

    # Frame layout budget:
    # top(1) + list_rows(list_budget) + preview_div(1) + preview_rows(preview_budget) + foot_div(1) + footer(2) + bottom(1) = lines
    local avail_rows=$(( lines - 6 ))
    (( avail_rows < 8 )) && avail_rows=8
    local list_budget=$(( (avail_rows * 42) / 100 ))
    (( list_budget < 4 )) && list_budget=4
    (( list_budget > total )) && list_budget=$total
    (( list_budget > avail_rows - 4 )) && list_budget=$((avail_rows - 4))
    local preview_budget=$(( avail_rows - list_budget ))
    (( preview_budget < 4 )) && preview_budget=4

    local l_start=0
    if (( cursor >= list_budget )); then
      l_start=$((cursor - list_budget + 1))
    fi
    local l_end=$((l_start + list_budget))
    (( l_end > total )) && l_end=$total

    # Top title bar with live pulse + summary counts
    local n_open=${#open_rows[@]} n_idle=${#idle_rows[@]} n_act=${#active_rows[@]}
    local cur_ip_disp pulse_ch hdr_l_styled hdr_r_ascii hdr_r_styled
    cur_ip_disp="$(sm_sanitize_line "$(sm_ip_display "${current_ip:-local}")" 32)"
    pulse_ch="$(sm_pulse_glyph "$tick")"
    hdr_l_styled="${C_OPEN}${pulse_ch}${C_RST} ${C_BRAND}SSH Multisession Resume${C_RST}"
    hdr_r_ascii="client ${cur_ip_disp} | ${policy_mode} | ${n_open} open | ${n_idle} idle | ${n_act} active"
    hdr_r_styled="${C_MUTED}client${C_RST} ${C_TEXT}${C_BOLD}${cur_ip_disp}${C_RST}${C_MUTED} ${G_SEP} ${policy_mode} ${G_SEP} ${C_RST}${C_OPEN}${n_open} open${C_RST}${C_MUTED} ${G_SEP} ${C_RST}${C_IDLE}${n_idle} idle${C_RST}${C_MUTED} ${G_SEP} ${C_RST}${C_ACTIVE}${n_act} active${C_RST}"

    local buf=""
    (( SM_TUI_ACTIVE == 1 )) && buf+=$'\033[?2026h'
    buf+=$'\033[H'
    buf+="$(sm_box_rule "$G_TL" "$G_TR" "$hdr_l_styled" 25 "$hdr_r_styled" "${#hdr_r_ascii}")"$'\n'

    # Responsive column widths across terminal width (60 cols -> 240+ cols)
    local w_num=4 w_name=16 w_badge=10 w_win=4 w_cmd=12 w_hist=0 w_ip=0 w_cwd=20
    if (( content_w >= 128 )); then
      w_name=18; w_badge=11; w_win=4; w_cmd=14; w_hist=8; w_ip=20
      w_cwd=$(( content_w - w_num - w_name - w_badge - w_win - w_cmd - w_hist - w_ip - 13 ))
    elif (( content_w >= 92 )); then
      w_name=16; w_badge=10; w_win=4; w_cmd=12; w_hist=0; w_ip=16
      w_cwd=$(( content_w - w_num - w_name - w_badge - w_win - w_cmd - w_ip - 11 ))
    else
      w_name=15; w_badge=10; w_win=0; w_cmd=10; w_hist=0; w_ip=0
      w_cwd=$(( content_w - w_num - w_name - w_badge - w_cmd - 7 ))
    fi
    (( w_cwd < 8 )) && w_cwd=8

    local idx kind tgt st num_s name_s badge_plain badge_color win_s cmd_s cwd_s hist_s ip_s
    for ((idx = l_start; idx < l_end; idx++)); do
      kind="${item_kind[$idx]}"
      tgt="${item_target[$idx]}"
      st="${item_state[$idx]}"
      printf -v num_s '[%d]' "$((idx + 1))"
      num_s="$(sm_fit_plain "$num_s" "$w_num")"

      case "$kind" in
        SESSION)
          name_s="$(sm_fit_plain "$tgt" "$w_name")"
          local b_icon="$G_DOT_OPEN" b_word="open"
          case "$st" in
            open)    b_icon="$G_DOT_OPEN";  b_word="open";    badge_color="$C_OPEN" ;;
            cleared) b_icon="$G_DOT_IDLE";  b_word="cleared"; badge_color="$C_IDLE" ;;
            empty)   b_icon="$G_DOT_EMPTY"; b_word="empty";   badge_color="$C_EMPTY" ;;
            *)       b_icon="$G_DOT_OPEN";  b_word="open";    badge_color="$C_OPEN" ;;
          esac
          badge_plain="${b_icon} $(sm_fit_plain "$b_word" $((w_badge - 2)))"
          win_s="$(sm_fit_plain "${item_win[$idx]}w" "$w_win")"
          cmd_s="$(sm_fit_plain "${item_cmd[$idx]}" "$w_cmd")"
          cwd_s="$(sm_fit_plain "$(sm_shorten_path "${item_cwd[$idx]}")" "$w_cwd")"
          hist_s="$(sm_fit_plain "${item_hist[$idx]}L" "$w_hist")"
          if [[ "${item_ip[$idx]}" != "-" ]]; then
            ip_s="$(sm_fit_plain "$(sm_ip_display "${item_ip[$idx]}")" "$w_ip")"
          else
            ip_s="$(sm_fit_plain "" "$w_ip")"
          fi
          ;;
        NEW)
          name_s="$(sm_fit_plain "+ New terminal" "$w_name")"
          badge_plain="${G_NEW} $(sm_fit_plain "create" $((w_badge - 2)))"
          badge_color="$C_NEW"
          win_s="$(sm_fit_plain "-" "$w_win")"
          cmd_s="$(sm_fit_plain "fresh slot" "$w_cmd")"
          cwd_s="$(sm_fit_plain "allocates ${tgt}" "$w_cwd")"
          hist_s="$(sm_fit_plain "" "$w_hist")"
          ip_s="$(sm_fit_plain "" "$w_ip")"
          ;;
        SKIP)
          if [[ "$context" == "login" ]]; then
            name_s="$(sm_fit_plain "-> Plain shell" "$w_name")"
            badge_plain="${G_SKIP} $(sm_fit_plain "shell" $((w_badge - 2)))"
            cmd_s="$(sm_fit_plain "no mux" "$w_cmd")"
            cwd_s="$(sm_fit_plain "plain SSH login shell" "$w_cwd")"
          else
            name_s="$(sm_fit_plain "-> Cancel" "$w_name")"
            badge_plain="${G_SKIP} $(sm_fit_plain "exit" $((w_badge - 2)))"
            cmd_s="$(sm_fit_plain "close" "$w_cmd")"
            cwd_s="$(sm_fit_plain "return without switching" "$w_cwd")"
          fi
          badge_color="$C_MUTED"
          win_s="$(sm_fit_plain "-" "$w_win")"
          hist_s="$(sm_fit_plain "" "$w_hist")"
          ip_s="$(sm_fit_plain "" "$w_ip")"
          ;;
        ACTIVE)
          name_s="$(sm_fit_plain "$tgt" "$w_name")"
          badge_plain="${G_DOT_ACT} $(sm_fit_plain "active" $((w_badge - 2)))"
          badge_color="$C_ACTIVE"
          win_s="$(sm_fit_plain "${item_win[$idx]}w" "$w_win")"
          cmd_s="$(sm_fit_plain "attached" "$w_cmd")"
          local self_note="preview hidden"
          [[ -n "$current_sess" && "$tgt" == "$current_sess" ]] && self_note="this session · preview hidden"
          cwd_s="$(sm_fit_plain "$self_note" "$w_cwd")"
          hist_s="$(sm_fit_plain "" "$w_hist")"
          if [[ "${item_ip[$idx]}" != "-" ]]; then
            ip_s="$(sm_fit_plain "$(sm_ip_display "${item_ip[$idx]}")" "$w_ip")"
          else
            ip_s="$(sm_fit_plain "" "$w_ip")"
          fi
          ;;
      esac

      local row_bg="" txt_c="$C_TEXT" dim_c="$C_MUTED" lead="  "
      if (( idx == cursor )); then
        row_bg="$C_SEL_BG"
        txt_c="${C_BOLD}${C_TEXT}"
        dim_c="$C_TEXT"
        lead="${C_SEL_BG}${C_ACCENT}${G_BAR}${C_RST}${C_SEL_BG} "
      elif [[ "$kind" == "ACTIVE" ]]; then
        txt_c="$C_MUTED"
      fi

      local row_str="${lead}${row_bg}${dim_c}${num_s} ${txt_c}${name_s}  ${badge_color}${badge_plain}${C_RST}${row_bg}"
      local used_cols=$(( 2 + w_num + 1 + w_name + 2 + w_badge ))
      if (( w_win > 0 )); then
        row_str+="  ${dim_c}${win_s}"
        used_cols=$((used_cols + 2 + w_win))
      fi
      row_str+="  ${txt_c}${cmd_s}  ${dim_c}${cwd_s}"
      used_cols=$((used_cols + 2 + w_cmd + 2 + w_cwd))
      if (( w_hist > 0 )); then
        row_str+="  ${dim_c}${hist_s}"
        used_cols=$((used_cols + 2 + w_hist))
      fi
      if (( w_ip > 0 )); then
        row_str+="  ${dim_c}${ip_s}"
        used_cols=$((used_cols + 2 + w_ip))
      fi
      local trail_pad=$(( inner - used_cols ))
      (( trail_pad < 0 )) && trail_pad=0
      if (( trail_pad > 0 )); then
        row_str+="$(printf '%*s' "$trail_pad" '')"
      fi
      row_str+="${C_RST}"

      local r_border="$G_V"
      if (( total > list_budget )); then
        local list_thumb=$(( ((idx - l_start) * list_budget) / list_budget ))
        local active_thumb=$(( (cursor * (list_budget - 1)) / (total - 1) ))
        if (( idx - l_start == active_thumb )); then
          r_border="${C_ACCENT}${G_THUMB}${C_BORDER}"
        fi
      fi
      buf+="${C_BORDER}${G_V}${C_RST}${row_str}${C_BORDER}${r_border}${C_RST}"$'\n'
    done

    # Pad unused list budget if any
    local rendered_list=$((l_end - l_start))
    local lp
    for ((lp = rendered_list; lp < list_budget; lp++)); do
      buf+="${C_BORDER}${G_V}${C_RST}$(printf '%*s' "$inner" '')${C_BORDER}${G_V}${C_RST}"$'\n'
    done

    # Capture & format preview for current selection (strictly skips active sessions!)
    local cur_kind="${item_kind[$cursor]}"
    local cur_tgt="${item_target[$cursor]}"
    local cur_state="${item_state[$cursor]}"
    local prev_w=$((inner - 2))
    local prev_l_plain="" prev_l_styled="" prev_r_plain="" prev_r_styled=""
    local -a preview_lines=()
    local p_pane_w=0 p_pane_h=0 p_total_lines=0 p_max_src_w=0 p_start_line=0

    case "$cur_kind" in
      SESSION)
        local short_p_cwd cap_out meta_hdr
        short_p_cwd="$(sm_shorten_path "${item_cwd[$cursor]}")"
        cap_out="$(sm_capture_tui_preview "$socket" "$cur_tgt" "$cur_state" "$preview_budget" "$prev_w" \
          "${item_cmd[$cursor]}" "${item_cwd[$cursor]}" "${item_hist[$cursor]}" "${item_ip[$cursor]}" \
          "$pan_x" "$SM_COLOR")"
        meta_hdr="${cap_out%%$'\n'*}"
        IFS='|' read -r p_pane_w p_pane_h p_total_lines p_max_src_w p_start_line <<< "$meta_hdr"
        if [[ "$cap_out" == *$'\n'* ]]; then
          local pl
          while IFS= read -r pl; do
            preview_lines+=("$pl")
          done <<< "${cap_out#*$'\n'}"
        fi
        prev_l_plain="Preview | ${cur_tgt} | ${cur_state} | ${item_win[$cursor]}w | ${item_cmd[$cursor]} | $(sm_sanitize_line "$short_p_cwd" 42)"
        prev_l_styled="${C_OPEN}Preview${C_RST}${C_MUTED} ${G_SEP} ${C_RST}${C_BOLD}${C_TEXT}${cur_tgt}${C_RST}${C_MUTED} ${G_SEP} ${cur_state} ${G_SEP} ${item_win[$cursor]}w ${G_SEP} ${item_cmd[$cursor]} ${G_SEP} $(sm_sanitize_line "$short_p_cwd" 42)${C_RST}"
        if (( p_max_src_w > prev_w || pan_x > 0 )); then
          # Clamp pan_x if user panned past content
          if (( pan_x > 0 && p_max_src_w > prev_w && pan_x > p_max_src_w - prev_w + 8 )); then
            pan_x=$((p_max_src_w - prev_w))
            (( pan_x < 0 )) && pan_x=0
          fi
          prev_r_plain="pane ${p_pane_w}x${p_pane_h} | <-/-> pan +${pan_x}/${p_max_src_w}c"
          prev_r_styled="${C_MUTED}pane ${p_pane_w}x${p_pane_h} ${G_SEP} ${C_RST}${C_ACCENT}<-/-> pan +${pan_x}/${p_max_src_w}c${C_RST}"
        elif (( p_pane_w > 0 )); then
          prev_r_plain="pane ${p_pane_w}x${p_pane_h} | ${item_hist[$cursor]}L history"
          prev_r_styled="${C_MUTED}pane ${p_pane_w}x${p_pane_h} ${G_SEP} ${item_hist[$cursor]}L history${C_RST}"
        fi
        ;;
      ACTIVE)
        local cap_out
        cap_out="$(sm_capture_tui_preview "$socket" "$cur_tgt" "active" "$preview_budget" "$prev_w" \
          "${item_cmd[$cursor]}" "${item_cwd[$cursor]}" "${item_hist[$cursor]}" "${item_ip[$cursor]}" 0 0)"
        if [[ "$cap_out" == *$'\n'* ]]; then
          local pl
          while IFS= read -r pl; do
            preview_lines+=("$pl")
          done <<< "${cap_out#*$'\n'}"
        fi
        prev_l_plain="Preview | ${cur_tgt} | active (privacy guard)"
        prev_l_styled="${C_ACTIVE}Preview ${G_SEP} ${cur_tgt} ${G_SEP} active (privacy guard)${C_RST}"
        prev_r_plain="capture-pane skipped"
        prev_r_styled="${C_MUTED}capture-pane skipped${C_RST}"
        ;;
      NEW)
        prev_l_plain="Preview | + New terminal (${cur_tgt})"
        prev_l_styled="${C_NEW}Preview ${G_SEP} + New terminal (${cur_tgt})${C_RST}"
        local -a nlines=(
          "Creates and attaches a fresh managed tmux session (${cur_tgt})."
          "Includes 200,000-line scrollback, native mouse/TUI scrolling, and OSC 52 clipboard."
          "All existing detached and active sessions remain untouched."
        )
        local nl
        while IFS= read -r nl; do
          preview_lines+=("$nl")
        done < <(printf '%s\n' "${nlines[@]}" | sm_format_stream_lines "$prev_w" 0 0 1 0 ">")
        ;;
      SKIP)
        if [[ "$context" == "login" ]]; then
          prev_l_plain="Preview | Plain SSH login shell"
          prev_l_styled="${C_MUTED}Preview ${G_SEP} Plain SSH login shell${C_RST}"
          local -a slines=(
            "Enters a standard interactive shell for this SSH connection without attaching tmux."
            "Your saved client policy remains unchanged for future connections."
          )
          local sl
          while IFS= read -r sl; do
            preview_lines+=("$sl")
          done < <(printf '%s\n' "${slines[@]}" | sm_format_stream_lines "$prev_w" 0 0 1 0 ">")
        else
          prev_l_plain="Preview | Cancel picker"
          prev_l_styled="${C_MUTED}Preview ${G_SEP} Cancel picker${C_RST}"
          local sl
          sl="$(sm_fit_plain "Closes the session picker and returns to your current shell." "$prev_w")"
          preview_lines+=("$sl")
        fi
        ;;
    esac

    # Clip preview header neatly if narrow
    local max_prev_l=$(( inner - ${#prev_r_plain} - 8 ))
    if (( ${#prev_l_plain} > max_prev_l && max_prev_l > 16 )); then
      prev_l_plain="$(sm_sanitize_line "$prev_l_plain" "$max_prev_l")"
      prev_l_styled="${C_ACCENT}${prev_l_plain}${C_RST}"
    fi

    buf+="$(sm_box_rule "$G_ML" "$G_MR" "$prev_l_styled" "${#prev_l_plain}" "$prev_r_styled" "${#prev_r_plain}")"$'\n'

    local p_idx blank_prev
    printf -v blank_prev '%*s' "$prev_w" ''
    for ((p_idx = 0; p_idx < preview_budget; p_idx++)); do
      local r_edge="$G_V"
      if (( p_total_lines > preview_budget && preview_budget > 1 )); then
        # Subtle right-edge scroll indicator showing bottom-anchored viewport
        local thumb_start=$(( (p_start_line * preview_budget) / p_total_lines ))
        (( thumb_start < 0 )) && thumb_start=0
        if (( p_idx >= thumb_start )); then
          r_edge="${C_ACCENT}${G_THUMB}${C_BORDER}"
        fi
      fi
      if (( p_idx < ${#preview_lines[@]} )); then
        local pl_color="" pl_end=""
        if [[ "$cur_kind" == "ACTIVE" ]]; then
          pl_color="$C_MUTED"; pl_end="$C_RST"
        elif [[ "$cur_kind" == "NEW" || "$cur_kind" == "SKIP" || "$cur_state" == "empty" || "$cur_state" == "cleared" ]]; then
          pl_color="$C_TEXT"; pl_end="$C_RST"
        fi
        buf+="${C_BORDER}${G_V}${C_RST} ${pl_color}${preview_lines[$p_idx]}${pl_end} ${C_BORDER}${r_edge}${C_RST}"$'\n'
      else
        buf+="${C_BORDER}${G_V}${C_RST} ${blank_prev} ${C_BORDER}${r_edge}${C_RST}"$'\n'
      fi
    done

    buf+="$(sm_box_rule "$G_ML" "$G_MR" "" 0 "" 0)"$'\n'

    # Footer rows (2 lines inside card)
    if [[ -n "$flash" ]]; then
      local fl_c="$C_WARN"
      [[ "$flash_kind" == "err" ]] && fl_c="$C_ERR"
      [[ "$flash_kind" == "ok" ]] && fl_c="$C_OPEN"
      local fl_txt
      fl_txt="$(sm_fit_plain " ${flash}" "$inner")"
      buf+="${C_BORDER}${G_V}${C_RST}${fl_c}${fl_txt}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
      flash=""
      flash_kind="info"
    else
      local fk1
      if (( cols >= 96 )); then
        fk1="$(sm_fit_plain " [Up/Down] browse   [1-9 / Enter] connect   [Left/Right] pan preview   [n] new slot   [c] clean empty/cleared" "$inner")"
      else
        fk1="$(sm_fit_plain " [Up/Down] browse  [1-9/Enter] open  [<-/->] pan  [n] new  [c] clean" "$inner")"
      fi
      buf+="${C_BORDER}${G_V}${C_RST}${C_KEY_FG}${fk1}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
    fi

    local exit_lbl="plain shell"
    [[ "$context" != "login" ]] && exit_lbl="exit"
    local fk2
    if (( cols >= 96 )); then
      fk2="$(sm_fit_plain " [t] transfer here   [d] drop detached   [i] IP manager   [s / q / Esc / Ctrl+C] ${exit_lbl}" "$inner")"
    else
      fk2="$(sm_fit_plain " [t] transfer  [d] drop  [i] IPs  [q/Esc/^C] ${exit_lbl}" "$inner")"
    fi
    buf+="${C_BORDER}${G_V}${C_RST}${C_MUTED}${fk2}${C_RST}${C_BORDER}${G_V}${C_RST}"$'\n'
    buf+="$(sm_box_rule "$G_BL" "$G_BR" "" 0 "" 0)"
    (( SM_TUI_ACTIVE == 1 )) && buf+=$'\033[?2026l'

    printf '%s' "$buf"

    sm_read_key "$total" 1

    local activate_idx=-1
    case "$SM_KEY" in
      TICK)
        tick=$((tick + 1))
        cache_ticks=$((cache_ticks + 1))
        ;;
      REDRAW)
        printf '\033[2J'
        cached_rows=""
        ;;
      UP|k|K)
        cursor=$(( (cursor - 1 + total) % total ))
        ;;
      DOWN|j|J)
        cursor=$(( (cursor + 1) % total ))
        ;;
      PGUP)
        cursor=$(( cursor - 5 ))
        (( cursor < 0 )) && cursor=0
        ;;
      PGDN)
        cursor=$(( cursor + 5 ))
        (( cursor >= total )) && cursor=$((total - 1))
        ;;
      HOME)
        if (( pan_x > 0 )); then
          pan_x=0
        else
          cursor=0
        fi
        ;;
      END)
        cursor=$((total - 1))
        ;;
      LEFT)
        if (( pan_x >= 12 )); then
          pan_x=$((pan_x - 12))
        else
          pan_x=0
        fi
        ;;
      RIGHT)
        if [[ "${item_kind[$cursor]}" == "SESSION" ]] && (( p_max_src_w > prev_w )); then
          local max_pan=$(( p_max_src_w - prev_w ))
          (( max_pan < 0 )) && max_pan=0
          pan_x=$((pan_x + 12))
          (( pan_x > max_pan )) && pan_x=$max_pan
        fi
        ;;
      0)
        pan_x=0
        ;;
      r|R)
        cached_rows=""
        flash="Refreshed session list."
        flash_kind="ok"
        ;;
      NUM:*)
        local num="${SM_KEY#NUM:}"
        if (( num >= 1 && num <= total )); then
          cursor=$((num - 1))
          activate_idx=$cursor
        else
          flash="Invalid selection [${num}] (choose 1-${total})."
          flash_kind="warn"
        fi
        ;;
      ENTER)
        activate_idx=$cursor
        ;;
      n|N)
        chosen_action="NEW"
        chosen_target="$next_slot"
        sm_play_connect_flash "$chosen_target"
        break
        ;;
      s|S|q|Q|ESC|CTRL_C|CTRL_D)
        chosen_action="SKIP"
        chosen_target=""
        break
        ;;
      EOF)
        # Non-interactive closed stdin fallback (e.g. scripted tests): activate highlighted option.
        activate_idx=$cursor
        ;;
      c|C)
        local clean_msg=""
        clean_msg="$(sm_cmd_sessions_clean --cleared 2>&1 || true)"
        flash="${clean_msg:-Cleaned empty/cleared sessions.}"
        flash_kind="ok"
        cached_rows=""
        cursor=-1
        ;;
      d|D)
        if [[ "${item_kind[$cursor]}" == "SESSION" ]]; then
          local drop_tgt="${item_target[$cursor]}" prompt_txt pad_d
          prompt_txt="$(sm_fit_plain " Drop detached session '${drop_tgt}'? [y/N] (Esc/Ctrl+C cancel)" "$inner")"
          printf '\033[%d;1H%s%s%s%s%s%s%s%s' \
            "$((lines - 2))" "$C_BORDER" "$G_V" "$C_RST" "$C_ERR" "$prompt_txt" "$C_RST" "$C_BORDER" "$G_V$C_RST"
          sm_read_key 1 0
          if [[ "$SM_KEY" == "y" || "$SM_KEY" == "Y" ]]; then
            flash="$(sm_cmd_session_drop "$drop_tgt" 2>&1 || true)"
            flash_kind="ok"
            cached_rows=""
            cursor=-1
          else
            flash="Drop cancelled."
            flash_kind="info"
          fi
        elif [[ "${item_kind[$cursor]}" == "ACTIVE" ]]; then
          flash="Refusing to drop active session (${item_target[$cursor]})."
          flash_kind="err"
        else
          flash="Highlight a detached session first to drop it."
          flash_kind="warn"
        fi
        ;;
      t|T)
        if [[ "${item_kind[$cursor]}" == "SESSION" || "${item_kind[$cursor]}" == "ACTIVE" ]]; then
          local take_tgt="${item_target[$cursor]}"
          if [[ -n "$current_sess" && "$take_tgt" == "$current_sess" ]]; then
            flash="You are already inside ${take_tgt}."
            flash_kind="warn"
          else
            chosen_action="TAKEOVER"
            chosen_target="$take_tgt"
            sm_play_connect_flash "$chosen_target"
            break
          fi
        else
          flash="Highlight a session first (or press [i] for full IP transfer)."
          flash_kind="warn"
        fi
        ;;
      i|I)
        sm_tui_ip_screen "$current_ip"
        cached_rows=""
        cursor=-1
        ;;
    esac

    if (( activate_idx >= 0 )); then
      case "${item_kind[$activate_idx]}" in
        SESSION)
          chosen_action="ATTACH"
          chosen_target="${item_target[$activate_idx]}"
          sm_play_connect_flash "$chosen_target"
          break
          ;;
        NEW)
          chosen_action="NEW"
          chosen_target="${item_target[$activate_idx]}"
          sm_play_connect_flash "$chosen_target"
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
            flash_kind="warn"
          else
            flash="${item_target[$activate_idx]} is active elsewhere (preview hidden). Press [t] to transfer/takeover."
            flash_kind="warn"
          fi
          ;;
      esac
    fi
  done

  sm_tui_leave
  SM_ACTIVE_RESULT_FILE=""
  trap - EXIT INT TERM HUP WINCH

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
      sm_sync_tmux_config "$socket"
      tmux -L "$socket" detach-client -s "=${chosen_target}" 2>/dev/null || true
      [[ -n "$current_ip" ]] && sm_record_connect "$current_ip" "$chosen_target"
      if [[ -n "$current_sess" ]]; then
        tmux -L "$socket" switch-client -t "=${chosen_target}"
      else
        tmux -L "$socket" attach-session -t "=${chosen_target}"
      fi
      ;;
    ATTACH)
      sm_sync_tmux_config "$socket"
      [[ -n "$current_ip" ]] && sm_record_connect "$current_ip" "$chosen_target"
      if [[ -n "$current_sess" ]]; then
        tmux -L "$socket" switch-client -t "=${chosen_target}"
      else
        tmux -L "$socket" attach-session -t "=${chosen_target}"
      fi
      ;;
    NEW)
      local tmux_conf
      tmux_conf="$(sm_tmux_conf_path)"
      sm_sync_tmux_config "$socket"
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

sm_tmux_conf_path() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  printf '%s\n' "${SSH_AUTO_RESUME_TMUX_CONF:-${script_dir}/tmux-auto-resume.conf}"
}

sm_sync_tmux_config() {
  local socket="${1:-$(sm_socket_name)}"
  local conf
  conf="$(sm_tmux_conf_path)"
  [[ -r "$conf" ]] || return 0
  if tmux -L "$socket" list-sessions >/dev/null 2>&1; then
    tmux -L "$socket" source-file "$conf" >/dev/null 2>&1 || true
  fi
}

sm_cmd_reload_config() {
  command -v tmux >/dev/null 2>&1 || sm_die "tmux is not installed."
  sm_ensure_tmux_tmpdir
  local socket conf
  socket="$(sm_socket_name)"
  conf="$(sm_tmux_conf_path)"
  [[ -r "$conf" ]] || sm_die "Missing tmux config: ${conf}"
  if ! tmux -L "$socket" list-sessions >/dev/null 2>&1; then
    echo "No running managed tmux server on socket '${socket}' (config will apply automatically on next login)."
    return 0
  fi
  tmux -L "$socket" source-file "$conf"
  echo "Reloaded tmux config on socket '${socket}' from ${conf} (active sessions untouched)."
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
    reload|reload-config)
      sm_cmd_reload_config "$@"
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
