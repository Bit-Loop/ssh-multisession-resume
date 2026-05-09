#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

SSHD_CONFIG="${SSHD_CONFIG_FILE:-/etc/ssh/sshd_config}"
SNAP="${SSHD_CONFIG}.ssh-auto-resume.bak"
LEGACY_SNAP="${SSHD_CONFIG}.screen-kill-session.bak"
BLOCK_START='# BEGIN ssh-auto-resume'
BLOCK_END='# END ssh-auto-resume'
LEGACY_BLOCK_START='# BEGIN ssh-screen-disconnect-kill'
LEGACY_BLOCK_END='# END ssh-screen-disconnect-kill'

usage() {
  local cmd="${0:-./server/install.sh}"

  cat <<USAGE
Usage:
  ${cmd}
  sudo ${cmd} apply --ip IP [--ip IP ...] [--ips IP[,IP...]] [--match-host HOST] [--keepalive-interval SECS] [--keepalive-count N]
  sudo ${cmd} apply --ips IP[,IP...] [--match-host HOST] [--keepalive-interval SECS] [--keepalive-count N]
  sudo ${cmd} add-current [--ip IP]
  ${cmd} detect-current
  sudo ${cmd} rollback
  sudo ${cmd} status

Address selection:
  apply requires --ip or --ips.
  add-current detects the current SSH client IP or accepts --ip explicitly.

Keepalive defaults:
  --keepalive-interval 15
  --keepalive-count 3

Notes:
  Any exact IPv4 address or IPv4 CIDR range is accepted.
  Repeat --ip or use --ips for multiple sources.
  Use --match-host only if reverse DNS is reliable.
  detect-current reads SSH_CONNECTION/SSH_CLIENT and does not need root.
  The managed Match block is appended to the end of sshd_config, where Match blocks are safest.
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

existing_backup() {
  if [[ -f "$SNAP" ]]; then
    printf '%s\n' "$SNAP"
  elif [[ -f "$LEGACY_SNAP" ]]; then
    printf '%s\n' "$LEGACY_SNAP"
  fi
}

usage_error() {
  echo "$*" >&2
  usage >&2
  exit 2
}

trim_space() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

validate_uint_range() {
  local key="$1"
  local value="$2"
  local min="$3"
  local max="$4"
  local normalized

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    usage_error "Invalid ${key}: ${value} (must be an integer)"
  fi

  normalized="$value"
  while [[ "${#normalized}" -gt 1 && "$normalized" == 0* ]]; do
    normalized="${normalized#0}"
  done

  if (( ${#normalized} > ${#max} )) || { (( ${#normalized} == ${#max} )) && [[ "$normalized" > "$max" ]]; }; then
    usage_error "${key} out of range: ${value} (must be ${min}-${max})"
  fi

  if (( 10#$normalized < min )); then
    usage_error "${key} out of range: ${value} (must be ${min}-${max})"
  fi
}

need_root() {
  if [[ "$SSHD_CONFIG" == /etc/* && $EUID -ne 0 ]]; then
    die "Run with sudo/root for server changes."
  fi
}

need_value() {
  local flag="$1"
  if [[ $# -lt 2 || "${2:-}" == --* ]]; then
    usage_error "Missing value for ${flag}"
  fi
}

validate_positive_uint() {
  local key="$1"
  local value="$2"

  validate_uint_range "$key" "$value" 1 2147483647
}

validate_ipv4_value() {
  local ip="$1"
  local a b c d octet

  if [[ -z "$ip" ]]; then
    usage_error "IP cannot be empty."
  fi

  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    usage_error "IP must be IPv4 in x.x.x.x form for this template: ${ip}"
  fi

  IFS=. read -r a b c d <<< "$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    validate_uint_range "IP octet in ${ip}" "$octet" 0 255
  done
}

validate_address() {
  local value="$1"
  local ip="$value"
  local prefix=""

  if [[ "$value" == */* ]]; then
    ip="${value%/*}"
    prefix="${value#*/}"
    validate_uint_range "CIDR prefix in ${value}" "$prefix" 0 32
  fi

  validate_ipv4_value "$ip"
}

add_address_list() {
  local raw_list="$1"
  local raw address
  local -a parts=()

  IFS=',' read -r -a parts <<< "$raw_list"
  for raw in "${parts[@]}"; do
    address="$(trim_space "$raw")"
    if [[ -z "$address" ]]; then
      usage_error "Empty address entry in ${raw_list}"
    fi
    validate_address "$address"
    ADDRESSES+=("$address")
  done
}

join_addresses() {
  local IFS=,
  printf '%s' "$*"
}

address_in_list() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

split_addresses() {
  local raw_list="$1"
  local raw address
  local -a parts=()

  IFS=',' read -r -a parts <<< "$raw_list"
  for raw in "${parts[@]}"; do
    address="${raw//[[:space:]]/}"
    if [[ -n "$address" ]]; then
      printf '%s\n' "$address"
    fi
  done
}

validate_match_host() {
  local host="$1"

  if [[ -z "$host" ]]; then
    usage_error "Match host cannot be empty."
  fi

  if ! [[ "$host" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    usage_error "Match host contains unsupported characters: ${host}"
  fi
}

validate_sshd() {
  if [[ "${SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE:-0}" == "1" ]]; then
    return 0
  fi

  if ! command -v sshd >/dev/null 2>&1; then
    echo "sshd binary not found" >&2
    return 1
  fi

  sshd -t -f "$SSHD_CONFIG"
}

reload_sshd() {
  validate_sshd || return 1

  if [[ "${SSH_SCREEN_KILL_NO_RELOAD:-0}" == "1" ]]; then
    echo "Skipped SSHD reload because SSH_SCREEN_KILL_NO_RELOAD=1."
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
      return 0
    fi
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
      return 0
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    if service sshd reload 2>/dev/null || service ssh reload 2>/dev/null; then
      return 0
    fi
    if service sshd restart 2>/dev/null || service ssh restart 2>/dev/null; then
      return 0
    fi
  fi

  if [[ -x /etc/init.d/sshd ]] && { /etc/init.d/sshd reload 2>/dev/null || /etc/init.d/sshd restart 2>/dev/null; }; then
    return 0
  fi

  if [[ -x /etc/init.d/ssh ]] && { /etc/init.d/ssh reload 2>/dev/null || /etc/init.d/ssh restart 2>/dev/null; }; then
    return 0
  fi

  echo "Could not reload or restart sshd/ssh service." >&2
  return 1
}

remove_managed_block() {
  local file="$1"
  local tmp

  if ! grep -qF "$BLOCK_START" "$file" && ! grep -qF "$LEGACY_BLOCK_START" "$file"; then
    return 0
  fi

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

append_managed_block() {
  local file="$1"
  local addresses="$2"
  local match_host="$3"
  local ka_interval="$4"
  local ka_count="$5"

  {
    printf '\n%s\n' "$BLOCK_START"
    printf '# Generated by %s/server/install.sh\n' "$ROOT_DIR"
    if [[ -n "$match_host" ]]; then
      printf 'Match Address %s Host %s\n' "$addresses" "$match_host"
    else
      printf 'Match Address %s\n' "$addresses"
    fi
  printf '    SetEnv SSH_AUTO_RESUME=1\n'
    printf '    ClientAliveInterval %s\n' "$ka_interval"
    printf '    ClientAliveCountMax %s\n' "$ka_count"
    printf '%s\n' "$BLOCK_END"
  } >> "$file"
}

managed_block() {
  local file="$1"

  awk \
    -v start="$BLOCK_START" \
    -v end="$BLOCK_END" \
    -v legacy_start="$LEGACY_BLOCK_START" \
    -v legacy_end="$LEGACY_BLOCK_END" '
    $0 == start || $0 == legacy_start { in_block = 1; next }
    $0 == end || $0 == legacy_end { in_block = 0; next }
    in_block { print }
  ' "$file"
}

current_managed_addresses() {
  local file="$1"

  if [[ ! -f "$file" ]] || { ! grep -qF "$BLOCK_START" "$file" && ! grep -qF "$LEGACY_BLOCK_START" "$file"; }; then
    return 0
  fi

  managed_block "$file" | awk '
    $1 == "Match" {
      for (i = 2; i <= NF; i++) {
        if ($i == "Address" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

current_managed_host() {
  local file="$1"

  if [[ ! -f "$file" ]] || { ! grep -qF "$BLOCK_START" "$file" && ! grep -qF "$LEGACY_BLOCK_START" "$file"; }; then
    return 0
  fi

  managed_block "$file" | awk '
    $1 == "Match" {
      for (i = 2; i <= NF; i++) {
        if ($i == "Host" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

current_managed_value() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]] || { ! grep -qF "$BLOCK_START" "$file" && ! grep -qF "$LEGACY_BLOCK_START" "$file"; }; then
    return 0
  fi

  managed_block "$file" | awk -v key="$key" '$1 == key { print $2; exit }'
}

detect_current_ip() {
  local candidate=""
  local who_line=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    candidate="${SSH_CONNECTION%% *}"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    candidate="${SSH_CLIENT%% *}"
  fi

  if [[ -z "$candidate" ]]; then
    who_line="$(who -m 2>/dev/null || who am i 2>/dev/null || true)"
    if [[ "$who_line" =~ \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) ]]; then
      candidate="${BASH_REMATCH[1]}"
    elif [[ "$who_line" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      candidate="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "$candidate" ]]; then
    return 1
  fi

  validate_address "$candidate"
  printf '%s\n' "$candidate"
}

restore_original() {
  local restore_tmp="$1"
  local created_backup="$2"

  cp "$restore_tmp" "$SSHD_CONFIG"
  if [[ "$created_backup" == "1" ]]; then
    rm -f "$SNAP"
  fi
}

cmd_detect_current() {
  local detected=""

  if ! detected="$(detect_current_ip)"; then
    die "Could not detect current SSH client IP. Run from an SSH session or pass --ip to add-current."
  fi

  printf '%s\n' "$detected"
}

cmd_add_current() {
  local detected=""
  local existing_addresses=""
  local match_host=""
  local ka_interval=""
  local ka_count=""
  local address
  local -a merged=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        need_value "$@"
        detected="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage_error "Unknown arg: $1"
        ;;
    esac
  done

  if [[ -z "$detected" ]]; then
    detected="$(detect_current_ip)" || die "Could not detect current SSH client IP. Use: sudo $0 add-current --ip \"\$($0 detect-current)\""
  fi

  validate_address "$detected"

  existing_addresses="$(current_managed_addresses "$SSHD_CONFIG" || true)"
  match_host="$(current_managed_host "$SSHD_CONFIG" || true)"
  ka_interval="$(current_managed_value "$SSHD_CONFIG" ClientAliveInterval || true)"
  ka_count="$(current_managed_value "$SSHD_CONFIG" ClientAliveCountMax || true)"

  if [[ -n "$existing_addresses" ]]; then
    while IFS= read -r address; do
      [[ -n "$address" ]] || continue
      validate_address "$address"
      merged+=("$address")
    done < <(split_addresses "$existing_addresses")
  fi

  if ! address_in_list "$detected" "${merged[@]}"; then
    merged+=("$detected")
  fi

  if [[ ${#merged[@]} -eq 0 ]]; then
    merged+=("$detected")
  fi

  [[ -n "$ka_interval" ]] || ka_interval=15
  [[ -n "$ka_count" ]] || ka_count=3

  if [[ -n "$match_host" ]]; then
    cmd_apply --ips "$(join_addresses "${merged[@]}")" --match-host "$match_host" --keepalive-interval "$ka_interval" --keepalive-count "$ka_count"
  else
    cmd_apply --ips "$(join_addresses "${merged[@]}")" --keepalive-interval "$ka_interval" --keepalive-count "$ka_count"
  fi
}

prompt_yes_no() {
  local answer=""
  local yellow=$'\033[1;33m'
  local white=$'\033[0;37m'
  local reset=$'\033[0m'
  local selected=0
  local key=""
  local rest=""

  if [[ -t 0 && -t 1 ]]; then
    while true; do
      if (( selected == 0 )); then
        printf '\rSelf add current SSH client IP? %s[ YES ]%s %s[ NO ]%s\033[K' "$yellow" "$reset" "$white" "$reset"
      else
        printf '\rSelf add current SSH client IP? %s[ YES ]%s %s[ NO ]%s\033[K' "$white" "$reset" "$yellow" "$reset"
      fi

      IFS= read -r -s -n 1 key || {
        printf '\n'
        return 1
      }

      case "$key" in
        ''|$'\n'|$'\r')
          printf '\n'
          (( selected == 0 ))
          return $?
          ;;
        $'\e')
          rest=""
          IFS= read -r -s -n 2 -t 0.1 rest || true
          case "$rest" in
            '[C'|'[B')
              selected=1
              ;;
            '[D'|'[A')
              selected=0
              ;;
          esac
          ;;
        ' '|$'\t')
          if (( selected == 0 )); then
            selected=1
          else
            selected=0
          fi
          ;;
        y|Y)
          printf '\n'
          return 0
          ;;
        n|N)
          printf '\n'
          return 1
          ;;
      esac
    done
  fi

  while true; do
    printf 'Self add current SSH client IP? %s[ YES ]%s %s[ NO ]%s: ' "$yellow" "$reset" "$white" "$reset"
    if ! IFS= read -r answer; then
      echo
      return 1
    fi

    case "${answer,,}" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo "Please answer YES or NO."
        ;;
    esac
  done
}

cmd_interactive() {
  local detected=""

  if ! prompt_yes_no; then
    echo "No changes made."
    return 0
  fi

  if ! detected="$(detect_current_ip)"; then
    die "Could not detect current SSH client IP. Use: sudo $0 add-current --ip <ip>"
  fi

  if [[ "$SSHD_CONFIG" == /etc/* && $EUID -ne 0 ]]; then
    echo "Detected current SSH client IP: ${detected}"
    echo "Run this to add it:"
    printf '  sudo %q add-current --ip %q\n' "$0" "$detected"
    return 0
  fi

  cmd_add_current --ip "$detected"
}

cmd_apply() {
  local addresses=""
  local match_host=""
  local ka_interval=15
  local ka_count=3
  local candidate restore_tmp created_backup existing_snap
  local -a ADDRESSES=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        need_value "$@"
        add_address_list "$2"
        shift 2
        ;;
      --ips)
        need_value "$@"
        add_address_list "$2"
        shift 2
        ;;
      --match-host|--host)
        need_value "$@"
        match_host="$2"
        shift 2
        ;;
      --keepalive-interval)
        need_value "$@"
        ka_interval="$2"
        shift 2
        ;;
      --keepalive-count)
        need_value "$@"
        ka_count="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage_error "Unknown arg: $1"
        ;;
    esac
  done

  if [[ ${#ADDRESSES[@]} -eq 0 ]]; then
    usage_error "Missing address. Use --ip IP, --ips IP[,IP...], or add-current from an SSH session."
  fi

  addresses="$(join_addresses "${ADDRESSES[@]}")"

  validate_positive_uint "keepalive-interval" "$ka_interval"
  validate_positive_uint "keepalive-count" "$ka_count"
  if [[ -n "$match_host" ]]; then
    validate_match_host "$match_host"
  fi

  if [[ ! -f "$SSHD_CONFIG" ]]; then
    die "SSHD config not found: ${SSHD_CONFIG}"
  fi

  candidate="$(mktemp)"
  restore_tmp="$(mktemp)"
  created_backup=0
  cp "$SSHD_CONFIG" "$candidate"
  cp "$SSHD_CONFIG" "$restore_tmp"

  existing_snap="$(existing_backup)"
  if [[ -z "$existing_snap" ]]; then
    cp "$SSHD_CONFIG" "$SNAP"
    created_backup=1
  else
    echo "Backup already exists: $existing_snap (not overwritten)"
  fi

  remove_managed_block "$candidate"
  append_managed_block "$candidate" "$addresses" "$match_host" "$ka_interval" "$ka_count"
  cat "$candidate" > "$SSHD_CONFIG"
  rm -f "$candidate"

  if ! validate_sshd; then
    restore_original "$restore_tmp" "$created_backup"
    rm -f "$restore_tmp"
    die "Generated config failed sshd validation; previous state was restored."
  fi

  if ! reload_sshd; then
    restore_original "$restore_tmp" "$created_backup"
    validate_sshd >/dev/null 2>&1 || true
    reload_sshd >/dev/null 2>&1 || true
    rm -f "$restore_tmp"
    die "SSHD reload failed; previous config state was restored."
  fi

  rm -f "$restore_tmp"

  echo "Installed managed block in ${SSHD_CONFIG}."
  if [[ -n "$match_host" ]]; then
    echo "Match condition is: Address=${addresses}, Host=${match_host}"
  else
    echo "Match condition is: Address=${addresses}"
  fi
}

cmd_rollback() {
  local restore_tmp
  local snap

  snap="$(existing_backup)"
  if [[ -n "$snap" ]]; then
    restore_tmp="$(mktemp)"
    cp "$SSHD_CONFIG" "$restore_tmp"
    cp "$snap" "$SSHD_CONFIG"
    if ! reload_sshd; then
      cp "$restore_tmp" "$SSHD_CONFIG"
      rm -f "$restore_tmp"
      die "Rollback reload failed; previous config state was restored."
    fi
    rm -f "$restore_tmp" "$snap"
    echo "Restored ${SSHD_CONFIG} from backup."
    return
  fi

  if [[ -f "$SSHD_CONFIG" ]] && { grep -qF "$BLOCK_START" "$SSHD_CONFIG" || grep -qF "$LEGACY_BLOCK_START" "$SSHD_CONFIG"; }; then
    restore_tmp="$(mktemp)"
    cp "$SSHD_CONFIG" "$restore_tmp"
    remove_managed_block "$SSHD_CONFIG"
    if ! reload_sshd; then
      cp "$restore_tmp" "$SSHD_CONFIG"
      rm -f "$restore_tmp"
      die "Rollback reload failed; previous config state was restored."
    fi
    rm -f "$restore_tmp"
    echo "Removed managed block from ${SSHD_CONFIG}."
    return
  fi

  echo "No scoped config found for rollback. No changes made."
}

cmd_status() {
  local existing_snap

  if [[ ! -f "$SSHD_CONFIG" ]]; then
    echo "installed: no"
    echo "config missing: ${SSHD_CONFIG}"
    return
  fi

  if grep -qF "$BLOCK_START" "$SSHD_CONFIG" || grep -qF "$LEGACY_BLOCK_START" "$SSHD_CONFIG"; then
    echo "installed: yes"
    echo "config: ${SSHD_CONFIG}"
    if [[ -r "$SSHD_CONFIG" ]]; then
      printf '%s\n' "$BLOCK_START"
      managed_block "$SSHD_CONFIG"
      printf '%s\n' "$BLOCK_END"
    else
      echo "config is not readable by this user"
    fi
  else
    echo "installed: no"
    echo "config: ${SSHD_CONFIG}"
  fi

  existing_snap="$(existing_backup)"
  if [[ -n "$existing_snap" ]]; then
    echo "backup: ${existing_snap}"
  else
    echo "backup: none"
  fi
}

if [[ $# -lt 1 ]]; then
  cmd_interactive
  exit $?
fi

ACTION="$1"
shift

case "$ACTION" in
  apply)
    need_root
    cmd_apply "$@"
    ;;
  add-current)
    need_root
    cmd_add_current "$@"
    ;;
  detect-current)
    cmd_detect_current "$@"
    ;;
  rollback)
    need_root
    cmd_rollback "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage_error "Unknown action: $ACTION"
    ;;
esac
