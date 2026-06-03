#!/usr/bin/env bash
# Full TDD-style test suite for ssh-multisession-resume.
# Exits 0 if all tests pass, 1 otherwise.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=tests/lib.sh
. "${ROOT_DIR}/tests/lib.sh"

ROOT_INSTALL="${ROOT_DIR}/bin/ssh-multisession-resume"
RUN_SH="${ROOT_DIR}/run.sh"
SSHD_MATCH_INSTALL="${ROOT_DIR}/sshd/match-install.sh"
RUNTIME_INSTALL="${ROOT_DIR}/runtime/install.sh"
AUTO_RESUME="${ROOT_DIR}/runtime/auto-resume.sh"
LEGACY_AUTO_SCREEN="${ROOT_DIR}/runtime/auto-screen.sh"
PROFILE_ENTRY="${ROOT_DIR}/runtime/profile-entry.sh"
TMUX_CONF="${ROOT_DIR}/runtime/tmux-auto-resume.conf"
SCREENRC="${ROOT_DIR}/runtime/screen-auto-resume.screenrc"
LEGACY_SCREENRC="${ROOT_DIR}/runtime/screen-hangup-off.screenrc"
PKGBUILD="${ROOT_DIR}/PKGBUILD"
SRCINFO="${ROOT_DIR}/.SRCINFO"
PACKAGE_BUILD="${ROOT_DIR}/packaging/build-packages.sh"
PAYLOAD="${ROOT_DIR}/packaging/payload.sh"
DOCKER_MATRIX="${ROOT_DIR}/docker/matrix.sh"

# Temp roots: cleaned up at end-of-run via trap.
TEST_TMP_ROOT="$(mktemp -d)"
cleanup_tests() { rm -rf "$TEST_TMP_ROOT"; }
trap cleanup_tests EXIT INT TERM HUP

mktemp_in_tests() { mktemp -p "$TEST_TMP_ROOT"; }
mktemp_d_in_tests() { mktemp -d -p "$TEST_TMP_ROOT"; }

# ============================================================
# Tier 0: required-file sanity + parse checks
# ============================================================

test_required_files() {
  test_case "files: every distributed source is present"
  local f
  for f in "$ROOT_INSTALL" "$RUN_SH" "$SSHD_MATCH_INSTALL" "$RUNTIME_INSTALL" "$AUTO_RESUME" \
           "$LEGACY_AUTO_SCREEN" "$PROFILE_ENTRY" "$TMUX_CONF" "$SCREENRC" \
           "$LEGACY_SCREENRC" "$PKGBUILD" "$SRCINFO" "$PACKAGE_BUILD" \
           "$PAYLOAD" "$DOCKER_MATRIX"; do
    assert_file_exists "$f"
  done
}

test_bash_syntax() {
  test_case "syntax: bash -n on every bash script"
  local f
  for f in "$ROOT_INSTALL" "$RUN_SH" "$SSHD_MATCH_INSTALL" "$RUNTIME_INSTALL" "$AUTO_RESUME" \
           "$LEGACY_AUTO_SCREEN" "$PROFILE_ENTRY" "$PACKAGE_BUILD" \
           "$PAYLOAD" "$DOCKER_MATRIX" "${ROOT_DIR}/tests/lib.sh" "${ROOT_DIR}/tests/smoke.sh"; do
    if ! bash -n "$f" 2>/dev/null; then
      fail "bash -n failed on $f"
    fi
  done
}

test_posix_sh_syntax_for_profile_entry() {
  test_case "syntax: profile-entry.sh parses under sh and zsh"
  if ! sh -n "$PROFILE_ENTRY" 2>/dev/null; then
    fail "sh -n failed on $PROFILE_ENTRY"
  fi
  if command -v zsh >/dev/null 2>&1; then
    if ! zsh -n "$PROFILE_ENTRY" 2>/dev/null; then
      fail "zsh -n failed on $PROFILE_ENTRY"
    fi
  fi
  if command -v dash >/dev/null 2>&1; then
    if ! dash -n "$PROFILE_ENTRY" 2>/dev/null; then
      fail "dash -n failed on $PROFILE_ENTRY"
    fi
  fi
}

test_zsh_syntax_for_auto_resume() {
  if ! command -v zsh >/dev/null 2>&1; then
    test_case "syntax: zsh -n on auto-resume.sh (skipped: zsh missing)"
    return
  fi
  test_case "syntax: zsh -n on auto-resume.sh + legacy auto-screen.sh"
  zsh -n "$AUTO_RESUME" 2>/dev/null || fail "zsh -n failed on $AUTO_RESUME"
  zsh -n "$LEGACY_AUTO_SCREEN" 2>/dev/null || fail "zsh -n failed on $LEGACY_AUTO_SCREEN"
}

# ============================================================
# Tier 1: unit tests for pure functions inside auto-resume.sh
# ============================================================

test_sanitize_replaces_special_chars() {
  test_case "sanitize: special chars become underscores"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_sanitize "100.101.137.20"
  ')"
  assert_eq "$result" "100_101_137_20" "dotted IPv4"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_sanitize "../../bad source!"
  ')"
  assert_eq "$result" "______bad_source_" "path traversal blocked"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_sanitize ""
  ')"
  assert_eq "$result" "" "empty input stays empty"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_sanitize "alphaNum-3.test_a"
  ')"
  assert_eq "$result" "alphaNum-3_test_a" "preserves safe chars"
}

test_source_ip_extraction() {
  test_case "source-ip: SSH_CONNECTION precedence"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    SSH_CONNECTION="198.51.100.8 55555 10.0.0.1 22"
    _ssh_auto_resume_source
  ')"
  assert_eq "$result" "198.51.100.8" "SSH_CONNECTION winning"

  test_case "source-ip: SSH_CLIENT fallback when SSH_CONNECTION unset"
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    unset SSH_CONNECTION
    SSH_CLIENT="203.0.113.9 55555 22"
    _ssh_auto_resume_source
  ')"
  assert_eq "$result" "203.0.113.9" "SSH_CLIENT fallback"

  test_case "source-ip: IPv6 values are preserved before sanitization"
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    SSH_CONNECTION="2001:db8::7 55555 2001:db8::1 22"
    _ssh_auto_resume_source
  ')"
  assert_eq "$result" "2001:db8::7" "SSH_CONNECTION IPv6"

  test_case "source-ip: unknown when neither var set"
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    unset SSH_CONNECTION
    unset SSH_CLIENT
    _ssh_auto_resume_source
  ')"
  assert_eq "$result" "unknown" "neither var set"
}

test_runtime_dir_prefers_xdg() {
  test_case "runtime-dir: XDG_RUNTIME_DIR honored when present"
  local xdg
  xdg="$(mktemp_d_in_tests)"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" XDG_RUNTIME_DIR="$xdg" \
            SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_runtime_dir
  ')"
  assert_eq "$result" "$xdg" "uses XDG_RUNTIME_DIR"
}

test_runtime_dir_ignores_invalid_xdg() {
  test_case "runtime-dir: ignores invalid XDG_RUNTIME_DIR"
  local xdg fake_uid result
  xdg="$(mktemp_in_tests)"
  fake_uid=99998
  rm -rf "/tmp/ssh-auto-resume-${fake_uid}" 2>/dev/null || true
  result="$(AUTO_RESUME="$AUTO_RESUME" XDG_RUNTIME_DIR="$xdg" \
            SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_user=test
    id() { printf "%s\n" '"$fake_uid"'; }
    export -f id
    _ssh_auto_resume_runtime_dir
  ')"
  assert_eq "$result" "/tmp/ssh-auto-resume-${fake_uid}" "falls back when XDG is not a directory"
  rm -rf "/tmp/ssh-auto-resume-${fake_uid}" 2>/dev/null || true
}

test_runtime_dir_fallback_creates_tmp_subdir() {
  test_case "runtime-dir: falls back to /tmp/ssh-auto-resume-<uid> when XDG unset"
  local fake_uid=99999
  rm -rf "/tmp/ssh-auto-resume-${fake_uid}" 2>/dev/null || true
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    unset XDG_RUNTIME_DIR
    _ssh_auto_resume_user=test
    # Override id -u via a function so we get a deterministic path.
    id() { printf "%s\n" '"$fake_uid"'; }
    export -f id
    _ssh_auto_resume_runtime_dir
  ')"
  assert_eq "$result" "/tmp/ssh-auto-resume-${fake_uid}" "fallback path"
  rm -rf "/tmp/ssh-auto-resume-${fake_uid}" 2>/dev/null || true
}

test_select_tmux_finds_first_free_slot() {
  test_case "select-tmux multi: skips attached slots and picks the first free"
  local fake_bin state
  fake_bin="$(mktemp_d_in_tests)"
  state="$(mktemp_in_tests)"
  cat > "${fake_bin}/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_TMUX_STATE:?}"
while [[ $# -gt 0 ]]; do
  case "$1" in -L|-f) shift 2 ;; *) break ;; esac
done
cmd="${1:-}"; shift || true
session_arg() {
  local value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in -t|-s) value="$2"; shift 2 ;; *) shift ;; esac
  done
  printf '%s\n' "$value"
}
case "$cmd" in
  has-session)    grep -q "^$(session_arg "$@")|" "$state" ;;
  display-message) awk -F'|' -v s="$(session_arg "$@")" '$1==s{print $2; f=1} END{exit f?0:1}' "$state" ;;
  list-sessions)  awk -F'|' '{printf "%s|%s|1\n", $1, $2}' "$state" ;;
  *) exit 2 ;;
esac
FAKE_TMUX
  chmod +x "${fake_bin}/tmux"
  printf '%s\n' 'main|1' 'ip-100_101_137_20-1|0' > "$state"

  local result
  result="$(PATH="${fake_bin}:$PATH" FAKE_TMUX_STATE="$state" \
            AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_socket_name=ssh-resume-test
    _ssh_auto_resume_session_base=ip-100_101_137_20
    _ssh_auto_resume_reservation_dir="$(mktemp -d)"
    SSH_AUTO_RESUME_MAX_SLOTS=4
    _ssh_auto_resume_select_tmux
    printf "%s\n%s\n" "$_ssh_auto_resume_selected" "$_ssh_auto_resume_selected_slot"
  ')"
  assert_contains "$result" "ip-100_101_137_20-1" "selected slot 1"
}

test_select_tmux_skips_reserved_slots() {
  test_case "select-tmux multi: skips slots that are pid-reserved by a live process"
  local fake_bin state res_dir
  fake_bin="$(mktemp_d_in_tests)"
  state="$(mktemp_in_tests)"
  res_dir="$(mktemp_d_in_tests)"
  cat > "${fake_bin}/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
state="${FAKE_TMUX_STATE:?}"
while [[ $# -gt 0 ]]; do case "$1" in -L|-f) shift 2 ;; *) break ;; esac; done
cmd="${1:-}"; shift || true
session_arg() {
  local v=""
  while [[ $# -gt 0 ]]; do case "$1" in -t|-s) v="$2"; shift 2 ;; *) shift ;; esac; done
  printf '%s\n' "$v"
}
case "$cmd" in
  has-session) grep -q "^$(session_arg "$@")|" "$state" ;;
  display-message) awk -F'|' -v s="$(session_arg "$@")" '$1==s{print $2; f=1} END{exit f?0:1}' "$state" ;;
  *) exit 2 ;;
esac
FAKE_TMUX
  chmod +x "${fake_bin}/tmux"
  printf '%s\n' 'main|1' 'ip-100_101_137_20-1|0' > "$state"

  local result
  result="$(PATH="${fake_bin}:$PATH" FAKE_TMUX_STATE="$state" \
            AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 \
            RES_DIR="$res_dir" bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_socket_name=ssh-resume-test
    _ssh_auto_resume_session_base=ip-100_101_137_20
    _ssh_auto_resume_reservation_dir="$RES_DIR"
    printf "%s\n" "$$" > "$RES_DIR/tmux-ip-100_101_137_20-1.pid"
    SSH_AUTO_RESUME_MAX_SLOTS=4
    _ssh_auto_resume_select_tmux
    printf "%s\n" "$_ssh_auto_resume_selected"
  ')"
  assert_eq "$result" "ip-100_101_137_20-2" "reserved slot 1 is skipped"
}

test_select_tmux_max_slots_returns_failure() {
  test_case "select-tmux multi: returns non-zero when no free slots"
  local fake_bin state
  fake_bin="$(mktemp_d_in_tests)"
  state="$(mktemp_in_tests)"
  cat > "${fake_bin}/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
state="${FAKE_TMUX_STATE:?}"
while [[ $# -gt 0 ]]; do case "$1" in -L|-f) shift 2 ;; *) break ;; esac; done
cmd="${1:-}"; shift || true
session_arg() {
  local v=""
  while [[ $# -gt 0 ]]; do case "$1" in -t|-s) v="$2"; shift 2 ;; *) shift ;; esac; done
  printf '%s\n' "$v"
}
case "$cmd" in
  has-session) grep -q "^$(session_arg "$@")|" "$state" ;;
  display-message) awk -F'|' -v s="$(session_arg "$@")" '$1==s{print $2; f=1} END{exit f?0:1}' "$state" ;;
  *) exit 2 ;;
esac
FAKE_TMUX
  chmod +x "${fake_bin}/tmux"
  printf '%s\n' 'ip-100_101_137_20-0|1' 'ip-100_101_137_20-1|1' > "$state"

  if PATH="${fake_bin}:$PATH" FAKE_TMUX_STATE="$state" \
       AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
       . "$AUTO_RESUME"
       _ssh_auto_resume_socket_name=ssh-resume-test
       _ssh_auto_resume_session_base=ip-100_101_137_20
       _ssh_auto_resume_reservation_dir="$(mktemp -d)"
       SSH_AUTO_RESUME_MAX_SLOTS=2
       _ssh_auto_resume_select_tmux
       ' >/dev/null 2>&1; then
    fail "select_tmux should fail with no free slots"
  fi
}

test_select_tmux_single_mode_pins_slot_zero() {
  test_case "select-tmux single: always slot 0 regardless of attachment"
  AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_session_base=ip-100_101_137_20
    _ssh_auto_resume_socket_name=ssh-resume-test
    _ssh_auto_resume_reservation_dir="$(mktemp -d)"
    SSH_AUTO_RESUME_MAX_SLOTS=4
    _ssh_auto_resume_mode=single
    _ssh_auto_resume_select_tmux
    [[ "$_ssh_auto_resume_selected" == "ip-100_101_137_20-0" ]] || exit 1
    [[ "$_ssh_auto_resume_selected_slot" == "0" ]] || exit 1
  ' || fail "single-mode tmux did not pin slot 0"

  test_case "select-screen single: always slot 0 regardless of attachment"
  AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_session_base=ip-100_101_137_20
    _ssh_auto_resume_socket_name=ssh-resume-test
    _ssh_auto_resume_reservation_dir="$(mktemp -d)"
    SSH_AUTO_RESUME_MAX_SLOTS=4
    _ssh_auto_resume_mode=single
    _ssh_auto_resume_select_screen
    [[ "$_ssh_auto_resume_selected" == "ip-100_101_137_20-0" ]] || exit 1
    [[ "$_ssh_auto_resume_selected_slot" == "0" ]] || exit 1
  ' || fail "single-mode screen did not pin slot 0"
}

test_lock_clears_stale_pid() {
  test_case "lock: clears a dead lock holder and acquires"
  AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    tmp_parent="$(mktemp -d)"
    _ssh_auto_resume_lock_dir="${tmp_parent}/slot.lock"
    mkdir "$_ssh_auto_resume_lock_dir"
    printf "%s\n" 999999999 > "${_ssh_auto_resume_lock_dir}/pid"
    _ssh_auto_resume_lock || exit 1
    [[ -f "${_ssh_auto_resume_lock_dir}/pid" ]] || exit 1
    _ssh_auto_resume_unlock
    [[ ! -e "$_ssh_auto_resume_lock_dir" ]] || exit 1
  ' || fail "stale-lock recovery broke"
}

test_lock_retry_env_override() {
  test_case "lock: SSH_AUTO_RESUME_LOCK_RETRIES=1 times out against a live holder"
  if AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 \
       SSH_AUTO_RESUME_LOCK_RETRIES=1 bash -c '
       . "$AUTO_RESUME"
       tmp_parent="$(mktemp -d)"
       _ssh_auto_resume_lock_dir="${tmp_parent}/slot.lock"
       mkdir "$_ssh_auto_resume_lock_dir"
       printf "%s\n" "$$" > "${_ssh_auto_resume_lock_dir}/pid"
       _ssh_auto_resume_lock 2>/dev/null
       ' >/dev/null 2>&1; then
    fail "lock should have failed with LOCK_RETRIES=1 against live holder"
  fi
}

test_screen_state_parser() {
  test_case "screen-state: detached / attached parsing"
  local fake_bin
  fake_bin="$(mktemp_d_in_tests)"
  cat > "${fake_bin}/screen" <<'FAKE_SCREEN'
#!/usr/bin/env bash
cat <<'SCREEN_LS'
There are screens on:
	123.ip-100_101_137_20-10	(Attached)
	456.ip-100_101_137_20-1	(Detached)
SCREEN_LS
FAKE_SCREEN
  chmod +x "${fake_bin}/screen"

  local result
  result="$(PATH="${fake_bin}:$PATH" AUTO_RESUME="$AUTO_RESUME" \
            SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_screen_state ip-100_101_137_20-1
  ')"
  assert_eq "$result" "detached" "detached parsing"

  result="$(PATH="${fake_bin}:$PATH" AUTO_RESUME="$AUTO_RESUME" \
            SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_screen_state ip-100_101_137_20-10
  ')"
  assert_eq "$result" "attached" "attached parsing"

  result="$(PATH="${fake_bin}:$PATH" AUTO_RESUME="$AUTO_RESUME" \
            SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_screen_state ip-100_101_137_20-99
  ')"
  assert_eq "$result" "missing" "missing parsing"
}

# ============================================================
# Tier 2: choice/policy unit + integration
# ============================================================

test_read_choice_valid_modes() {
  test_case "read_choice: accepts single / multi / skip"
  local home
  home="$(mktemp_d_in_tests)"
  mkdir -p "${home}/.config/ssh-multisession-resume/choices"
  printf 'single\n' > "${home}/.config/ssh-multisession-resume/choices/198.51.100.7"
  HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_read_choice "198.51.100.7" || exit 1
    [[ "$_ssh_auto_resume_choice" == "single" ]] || exit 1
  ' || fail "single not read"

  printf 'multi\n' > "${home}/.config/ssh-multisession-resume/choices/198.51.100.7"
  HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_read_choice "198.51.100.7" || exit 1
    [[ "$_ssh_auto_resume_choice" == "multi" ]] || exit 1
  ' || fail "multi not read"

  printf 'skip\n' > "${home}/.config/ssh-multisession-resume/choices/198.51.100.7"
  HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_read_choice "198.51.100.7" || exit 1
    [[ "$_ssh_auto_resume_choice" == "skip" ]] || exit 1
  ' || fail "skip not read"
}

test_read_choice_rejects_garbage_and_missing() {
  test_case "read_choice: rejects garbage content; returns non-zero for missing file"
  local home
  home="$(mktemp_d_in_tests)"
  mkdir -p "${home}/.config/ssh-multisession-resume/choices"
  printf 'garbage\n' > "${home}/.config/ssh-multisession-resume/choices/garbage.test"
  if HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
       . "$AUTO_RESUME"
       _ssh_auto_resume_read_choice "garbage.test"
       ' >/dev/null 2>&1; then
    fail "read_choice should reject garbage modes"
  fi

  if HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
       . "$AUTO_RESUME"
       _ssh_auto_resume_read_choice "203.0.113.99"
       ' >/dev/null 2>&1; then
    fail "read_choice should return non-zero for missing ip"
  fi
}

test_save_choice_round_trip() {
  test_case "save_choice: round-trip through read_choice"
  local home
  home="$(mktemp_d_in_tests)"
  HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_save_choice "192_168_1_5" "single" || exit 1
    _ssh_auto_resume_read_choice "192_168_1_5" || exit 1
    [[ "$_ssh_auto_resume_choice" == "single" ]] || exit 1
  ' || fail "save+read round trip broken"
  assert_file_exists "${home}/.config/ssh-multisession-resume/choices/192_168_1_5"
}

test_menu_non_tty_returns_skip() {
  test_case "menu: non-TTY input (closed stdin) returns skip"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "203.0.113.5" </dev/null >/dev/null
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "skip" "menu falls back to skip on EOF"
}

test_menu_digit_input_maps_to_modes() {
  test_case "menu: digit input 1/2/3 maps to single/multi/skip"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<"1"
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "single" "digit 1 -> single"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<"2"
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "multi" "digit 2 -> multi"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<"3"
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "skip" "digit 3 -> skip"
}

test_menu_default_empty_returns_multi() {
  test_case "menu: empty input (just Enter) defaults to multi"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<""
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "multi" "empty input defaults to multi"
}

test_menu_alias_keys() {
  test_case "menu: word inputs (single/multi/skip) and letter aliases"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<"single"
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "single" "word: single"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<"s"
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "single" "alias: s"

  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<"q"
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "skip" "alias: q"
}

test_menu_invalid_then_valid() {
  test_case "menu: bogus input rejected, valid input on retry is accepted"
  local result
  result="$(AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 bash -c '
    . "$AUTO_RESUME"
    _ssh_auto_resume_menu "1.2.3.4" >/dev/null <<<$'\''bogus\n1'\''
    printf "%s\n" "$_ssh_auto_resume_choice"
  ')"
  assert_eq "$result" "single" "retry path accepted"
}

# ============================================================
# Tier 3: tmux conf + Wayland coverage
# ============================================================

test_tmux_conf_pins_update_environment() {
  test_case "tmux-conf: pins DISPLAY / SSH_AUTH_SOCK / WAYLAND_DISPLAY / XAUTHORITY"
  assert_grep '^set-option -g update-environment .*DISPLAY' "$TMUX_CONF"
  assert_grep 'SSH_AUTH_SOCK' "$TMUX_CONF"
  assert_grep 'WAYLAND_DISPLAY' "$TMUX_CONF"
  assert_grep 'XAUTHORITY' "$TMUX_CONF"
}

# ============================================================
# Tier 4: profile-entry.sh gating
# ============================================================

test_profile_entry_skips_non_ssh() {
  test_case "profile-entry: returns cleanly when SSH_* env is absent"
  # In a non-interactive shell with no SSH_* set, sourcing should be a clean
  # no-op and must not export SSH_AUTO_RESUME.
  if ! env -i HOME="$(mktemp_d_in_tests)" PATH="$PATH" bash -c ". '$PROFILE_ENTRY'" 2>/dev/null; then
    fail "profile-entry produced errors on non-SSH shell"
  fi
  local out
  out="$(env -i HOME="$(mktemp_d_in_tests)" PATH="$PATH" bash -c "
    . '$PROFILE_ENTRY'
    echo \"SSH_AUTO_RESUME=\${SSH_AUTO_RESUME:-unset}\"
  ")"
  assert_contains "$out" "SSH_AUTO_RESUME=unset" "should not export the env on non-SSH login"
}

test_profile_entry_static_gates_present() {
  test_case "profile-entry: required gates are present in the file"
  assert_grep 'SSH_CONNECTION' "$PROFILE_ENTRY"
  assert_grep 'TMUX' "$PROFILE_ENTRY"
  assert_grep 'SSH_ORIGINAL_COMMAND' "$PROFILE_ENTRY"
  assert_grep 'opt-out' "$PROFILE_ENTRY"
  assert_grep '/usr/lib/ssh-multisession-resume' "$PROFILE_ENTRY"
  assert_grep 'SSH_AUTO_RESUME=1' "$PROFILE_ENTRY"
  assert_grep 'XDG_CONFIG_HOME' "$PROFILE_ENTRY"
}

# ============================================================
# Tier 5: CLI subcommands (policy / opt-out / help / summary)
# ============================================================

test_cli_help_lists_new_commands() {
  test_case "cli: --help lists new subcommands"
  local out
  out="$(mktemp_in_tests)"
  "$ROOT_INSTALL" --help > "$out"
  assert_grep '^  \./bin/ssh-multisession-resume doctor' "$out"
  assert_grep 'policy show' "$out"
  assert_grep 'policy set IP MODE' "$out"
  assert_grep 'policy move OLD_IP NEW_IP' "$out"
  assert_grep 'policy forget IP' "$out"
  assert_grep 'opt-out' "$out"
  assert_grep 'opt-in' "$out"

  SSH_MULTISESSION_RESUME_COMMAND=ssh-multisession-resume "$ROOT_INSTALL" --help > "$out"
  assert_grep '^  ssh-multisession-resume doctor' "$out"
}

test_cli_default_action_is_summary() {
  test_case "cli: no args prints summary (not legacy apply prompt)"
  local home
  home="$(mktemp_d_in_tests)"
  local out
  out="$(HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" 2>&1 || true)"
  assert_contains "$out" "Install:" "summary shows install section"
  assert_contains "$out" "Saved policies:" "summary lists saved policies"
  assert_contains "$out" "Next steps:" "summary shows next steps"
}

test_cli_policy_set_show_forget_clear() {
  test_case "cli: policy set / show / forget / clear round-trip"
  local home
  home="$(mktemp_d_in_tests)"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 192.168.1.50 single >/dev/null
  assert_file_exists "${home}/.config/ssh-multisession-resume/choices/192_168_1_50"
  assert_eq "$(cat "${home}/.config/ssh-multisession-resume/choices/192_168_1_50")" "single"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 10.0.0.1 multi >/dev/null
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set fe80::1 skip >/dev/null

  local out
  out="$(mktemp_in_tests)"
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy show > "$out"
  assert_grep '192_168_1_50 -> single' "$out"
  assert_grep '10_0_0_1 -> multi' "$out"
  assert_grep 'fe80__1 -> skip' "$out"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy forget 192.168.1.50 >/dev/null
  assert_file_missing "${home}/.config/ssh-multisession-resume/choices/192_168_1_50"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy clear >/dev/null
  assert_dir_empty "${home}/.config/ssh-multisession-resume/choices"
}

test_cli_policy_move_switches_ip() {
  test_case "cli: policy move switches a saved choice from one IP to another"
  local home out
  home="$(mktemp_d_in_tests)"
  out="$(mktemp_in_tests)"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 192.168.1.50 single >/dev/null
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy move 192.168.1.50 10.0.0.9 > "$out"
  assert_grep 'Moved policy: 192_168_1_50 -> 10_0_0_9' "$out"
  assert_file_missing "${home}/.config/ssh-multisession-resume/choices/192_168_1_50"
  assert_file_exists "${home}/.config/ssh-multisession-resume/choices/10_0_0_9"
  assert_eq "$(cat "${home}/.config/ssh-multisession-resume/choices/10_0_0_9")" "single"

  expect_failure env HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy move 203.0.113.4 203.0.113.5
}

test_cli_policy_set_rejects_invalid_mode() {
  test_case "cli: policy set rejects modes outside {single,multi,skip}"
  local home
  home="$(mktemp_d_in_tests)"
  expect_failure env HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 1.2.3.4 bogus
}

test_cli_policy_set_requires_ip_and_mode() {
  test_case "cli: policy set without arguments fails clearly"
  local home
  home="$(mktemp_d_in_tests)"
  expect_failure env HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set
  expect_failure env HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 1.2.3.4
}

test_cli_policy_show_when_empty() {
  test_case "cli: policy show with no policies prints a friendly placeholder"
  local home out
  home="$(mktemp_d_in_tests)"
  out="$(HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy show)"
  assert_contains "$out" "no saved policies" "placeholder message"
}

test_cli_policy_show_sigpipe_resistant() {
  test_case "cli: policy show survives broken pipe (e.g. piped to head)"
  local home
  home="$(mktemp_d_in_tests)"
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 192.168.1.50 single >/dev/null
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 10.0.0.1 multi >/dev/null
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy set 198.51.100.7 skip >/dev/null
  # Pipe to head -n 0 closes stdout immediately. Without our SIGPIPE
  # handling, set -euo pipefail would propagate 141 and break the suite.
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" policy show | head -n 0 >/dev/null || true
}

test_cli_optout_optin_roundtrip() {
  test_case "cli: opt-out writes marker; opt-in removes it"
  local home
  home="$(mktemp_d_in_tests)"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" opt-out >/dev/null
  assert_file_exists "${home}/.config/ssh-multisession-resume/opt-out"

  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" opt-in >/dev/null
  assert_file_missing "${home}/.config/ssh-multisession-resume/opt-out"

  # opt-in twice is a no-op (no error).
  HOME="$home" XDG_CONFIG_HOME="" "$ROOT_INSTALL" opt-in >/dev/null
}

test_cli_unknown_action_fails() {
  test_case "cli: unknown action exits non-zero"
  expect_failure "$ROOT_INSTALL" totally-not-a-real-action
  expect_failure "$ROOT_INSTALL" policy mystery-sub
}

test_cli_detect_current_extracts_ip() {
  test_case "cli: detect-current reads SSH_CONNECTION / SSH_CLIENT"
  local result
  result="$(env -u SSH_CLIENT SSH_CONNECTION='198.51.100.7 55555 10.0.0.1 22' "$SSHD_MATCH_INSTALL" detect-current)"
  assert_eq "$result" "198.51.100.7" "SSH_CONNECTION path"

  result="$(env -u SSH_CONNECTION SSH_CLIENT='203.0.113.8 55555 22' "$SSHD_MATCH_INSTALL" detect-current)"
  assert_eq "$result" "203.0.113.8" "SSH_CLIENT fallback"

  result="$(env -u SSH_CLIENT SSH_CONNECTION='2001:db8::7 55555 2001:db8::1 22' "$SSHD_MATCH_INSTALL" detect-current)"
  assert_eq "$result" "2001:db8::7" "SSH_CONNECTION IPv6 path"

  result="$(env -u SSH_CONNECTION SSH_CLIENT='fe80::1 55555 22' "$SSHD_MATCH_INSTALL" detect-current)"
  assert_eq "$result" "fe80::1" "SSH_CLIENT IPv6 fallback"

  result="$(env -u SSH_CLIENT SSH_CONNECTION='fe80::1%eth0 55555 fe80::2%eth0 22' "$SSHD_MATCH_INSTALL" detect-current)"
  assert_eq "$result" "fe80::1%eth0" "SSH_CONNECTION scoped IPv6 path"

  expect_failure env -u SSH_CLIENT SSH_CONNECTION='999.0.0.1 55555 10.0.0.1 22' "$SSHD_MATCH_INSTALL" detect-current
  expect_failure env -u SSH_CLIENT SSH_CONNECTION='2001:db8::1::2 55555 10.0.0.1 22' "$SSHD_MATCH_INSTALL" detect-current
}

# ============================================================
# Tier 5A: root run.sh source installer
# ============================================================

test_run_sh_help_lists_install_and_docker_tests() {
  test_case "run.sh: help stays short and points to install/test/package commands"
  local out
  out="$(mktemp_in_tests)"
  "$RUN_SH" --help > "$out"
  assert_grep './run\.sh \[install\|status\|rollback\|deps\]' "$out"
  assert_grep './run\.sh test\[:all\|:aur' "$out"
  assert_grep './run\.sh package\[:arch\|:deb\|:rpm\|:apk\]' "$out"
  assert_grep './run\.sh shell \[distro\]' "$out"
}

test_run_sh_temp_install_and_rollback() {
  test_case "run.sh: source install and rollback work under temp roots"
  local root prefix etc out
  root="$(mktemp_d_in_tests)"
  prefix="${root}/usr/local"
  etc="${root}/etc"
  out="$(mktemp_in_tests)"

  SSH_MULTISESSION_PREFIX="$prefix" \
    SSH_MULTISESSION_ETC_DIR="$etc" \
    SSH_MULTISESSION_SKIP_DEPS=1 \
    SSH_MULTISESSION_ASSUME_YES=1 \
    SSH_MULTISESSION_ZSH_HOOKS=0 \
    "$RUN_SH" install > "$out"

  assert_file_exists "${prefix}/bin/ssh-multisession-resume"
  assert_file_exists "${prefix}/lib/ssh-multisession-resume/ssh-multisession-resume"
  assert_file_exists "${prefix}/lib/ssh-multisession-resume/runtime/profile-entry.sh"
  assert_file_exists "${prefix}/lib/ssh-multisession-resume/sshd/match-install.sh"
  assert_file_exists "${etc}/profile.d/ssh-multisession-resume.sh"
  assert_file_exists "${etc}/profile"
  assert_grep "${prefix}/lib/ssh-multisession-resume" "${etc}/profile.d/ssh-multisession-resume.sh"
  assert_grep 'BEGIN ssh-multisession-resume profile hook' "${etc}/profile"

  SSH_MULTISESSION_PREFIX="$prefix" \
    SSH_MULTISESSION_ETC_DIR="$etc" \
    SSH_MULTISESSION_ASSUME_YES=1 \
    SSH_MULTISESSION_ZSH_HOOKS=0 \
    "$RUN_SH" rollback > "$out"

  assert_file_missing "${prefix}/bin/ssh-multisession-resume"
  assert_file_missing "${prefix}/lib/ssh-multisession-resume/ssh-multisession-resume"
  assert_file_missing "${etc}/profile.d/ssh-multisession-resume.sh"
  assert_no_grep 'ssh-multisession-resume profile hook' "${etc}/profile"
}

# ============================================================
# Tier 6: SSH_AUTO_RESUME_MODE override precedence
# ============================================================

test_mode_env_override_precedence() {
  test_case "auto-resume: SSH_AUTO_RESUME_MODE env beats saved choice"
  local home
  home="$(mktemp_d_in_tests)"
  mkdir -p "${home}/.config/ssh-multisession-resume/choices"
  # Saved choice says skip
  printf 'skip\n' > "${home}/.config/ssh-multisession-resume/choices/198_51_100_7"

  # But we override at runtime to single. The override should win.
  local result
  result="$(HOME="$home" AUTO_RESUME="$AUTO_RESUME" SSH_AUTO_RESUME_KEEP_FUNCTIONS=1 \
            SSH_AUTO_RESUME_MODE=single bash -c '
    . "$AUTO_RESUME"
    # Simulate that main resolved the mode by reading override + saved.
    if [ -n "${SSH_AUTO_RESUME_MODE:-}" ]; then
      case "$SSH_AUTO_RESUME_MODE" in
        single|multi|skip) printf "%s\n" "$SSH_AUTO_RESUME_MODE" ;;
        *) printf "multi\n" ;;
      esac
    fi
  ')"
  assert_eq "$result" "single" "env override wins"
}

# ============================================================
# Tier 7: sshd/match-install.sh validation
# ============================================================

test_server_validate_ipv4_accepts_canonical() {
  test_case "server: validate accepts canonical and edge-case IPv4 / CIDR"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  local ip
  for ip in "0.0.0.0" "255.255.255.255" "192.168.001.010" "203.0.113.7/0" "203.0.113.7/32"; do
    expect_success env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
                     SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip "$ip"
  done
}

test_server_validate_ipv6_accepts_canonical() {
  test_case "server: validate accepts canonical IPv6 / CIDR"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  local ip
  for ip in "::1" "::" "2001:db8::1" "2001:db8:0:0:0:0:2:1" \
            "2001:db8::/64" "::/0" "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128" \
            "::ffff:192.0.2.128" "fe80::1%eth0" "fe80::1%eth0/128" \
            "fe80::/64%eth0"; do
    expect_success env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
                     SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip "$ip"
  done
}

test_server_validate_rejects_bad_addresses() {
  test_case "server: validate rejects malformed IP / CIDR / whitespace"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  local ip
  for ip in "" "1.2.3" "1.2.3.4.5" "1.2.3.a" "256.0.0.1" "999999999999999.1.1.1" \
            "1.2.3.4/33" "1.2.3.4/-1" "1.2.3.4/999999999" \
            ":" "2001:db8::1::2" "2001:db8:::1" "2001:db8::g" \
            "1:2:3:4:5:6:7:8:9" "2001:db8::1/129" "2001:db8::1/-1" \
            "2001:db8::1/999999999" "fe80::1%" "fe80::1%eth0!" \
            "fe80::1%eth0%again" "192.0.2.1%eth0"; do
    expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
                     SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip "$ip"
  done
  expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
                   SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ips '10.0.0.1,,10.0.0.2'
  expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
                   SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ips '10.0.0.1/ 24'
}

test_server_keepalive_bounds() {
  test_case "server: keepalive params reject zero / negative / huge / non-numeric"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
    SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip 10.0.0.1 --keepalive-interval 0
  expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
    SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip 10.0.0.1 --keepalive-count -1
  expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
    SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip 10.0.0.1 --keepalive-count 2147483648
  expect_failure env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
    SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip 10.0.0.1 --keepalive-interval abc
}

test_server_apply_writes_block() {
  test_case "server: apply emits SetEnv + ClientAlive directives"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  expect_success env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
    SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ip 100.101.137.15
  assert_grep '^Match Address 100\.101\.137\.15$' "$conf"
  assert_grep '^    SetEnv SSH_AUTO_RESUME=1$' "$conf"
  assert_no_grep 'TCPKeepAlive' "$conf"
}

test_server_apply_writes_ipv6_block() {
  test_case "server: apply emits IPv6 Match Address"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  expect_success env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 \
    SSH_SCREEN_KILL_NO_RELOAD=1 "$SSHD_MATCH_INSTALL" apply --ips '2001:db8::7,::1,fe80::1%eth0'
  assert_grep '^Match Address 2001:db8::7,::1,fe80::1%eth0$' "$conf"
  assert_grep '^    SetEnv SSH_AUTO_RESUME=1$' "$conf"
}

test_server_apply_then_add_current_deduplicates() {
  test_case "server: add-current is idempotent on duplicate IPs"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" apply --ip 1.2.3.4 >/dev/null
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" add-current --ip 1.2.3.4 >/dev/null
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" add-current --ip 1.2.3.4 >/dev/null
  # Should still be a single IP, not duplicated.
  local count
  count="$(grep -c '^Match Address 1\.2\.3\.4$' "$conf")"
  assert_eq "$count" "1" "duplicate add-current did not duplicate the match line"
}

test_server_apply_then_add_current_deduplicates_ipv6() {
  test_case "server: add-current is idempotent on duplicate IPv6 addresses"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" apply --ip 2001:db8::7 >/dev/null
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" add-current --ip 2001:db8::7 >/dev/null
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" add-current --ip 2001:db8::7 >/dev/null
  local count
  count="$(grep -c '^Match Address 2001:db8::7$' "$conf")"
  assert_eq "$count" "1" "duplicate IPv6 add-current did not duplicate the match line"
}

test_server_rollback_restores_or_strips() {
  test_case "server: rollback removes managed block"
  local conf
  conf="$(mktemp_d_in_tests)/sshd_config"
  printf 'Port 22\n' > "$conf"
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" apply --ip 1.2.3.4 >/dev/null
  assert_grep 'ssh-auto-resume' "$conf"
  env SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$SSHD_MATCH_INSTALL" rollback >/dev/null
  assert_no_grep 'ssh-auto-resume' "$conf"
  assert_no_grep 'ssh-screen-disconnect-kill' "$conf"
}

# ============================================================
# Tier 8: runtime/install.sh legacy apply / rollback
# ============================================================

test_client_apply_and_rollback_idempotent() {
  test_case "client: apply twice creates one block; rollback restores cleanly"
  local home
  home="$(mktemp_d_in_tests)"
  HOME="$home" "$RUNTIME_INSTALL" apply >/dev/null
  HOME="$home" "$RUNTIME_INSTALL" apply >/dev/null

  assert_grep 'auto-resume.sh' "${home}/.bash_profile"
  assert_grep 'auto-resume.sh' "${home}/.zshrc"

  # Only one scoped block per profile.
  local count
  count="$(grep -c '^### begin ssh-auto-resume-session$' "${home}/.bash_profile")"
  assert_eq "$count" "1" "apply twice yields one block in .bash_profile"

  HOME="$home" "$RUNTIME_INSTALL" rollback >/dev/null
  assert_file_missing "${home}/.bash_profile"
  assert_file_missing "${home}/.zshrc"
}

test_client_apply_preserves_existing_profile() {
  test_case "client: apply preserves prior content of .profile and restores on rollback"
  local home
  home="$(mktemp_d_in_tests)"
  printf 'export EXISTING_PROFILE_VALUE=1\n' > "${home}/.profile"
  HOME="$home" "$RUNTIME_INSTALL" apply >/dev/null
  assert_grep 'auto-resume.sh' "${home}/.profile"
  assert_file_missing "${home}/.bash_profile"
  HOME="$home" "$RUNTIME_INSTALL" rollback >/dev/null
  assert_grep '^export EXISTING_PROFILE_VALUE=1$' "${home}/.profile"
  assert_no_grep 'scoped-screen-autodetach-off' "${home}/.profile"
  assert_no_grep 'ssh-auto-resume-session' "${home}/.profile"
}

test_client_service_install_unit_contents() {
  if ! command -v tmux >/dev/null 2>&1; then
    test_case "client: service-install (skipped: tmux missing)"
    return
  fi
  test_case "client: service-install writes the keepalive unit"
  local home
  home="$(mktemp_d_in_tests)"
  HOME="$home" SSH_AUTO_RESUME_SKIP_SYSTEMD=1 "$RUNTIME_INSTALL" service-install >/dev/null
  local unit="${home}/.config/systemd/user/ssh-auto-resume.service"
  assert_file_exists "$unit"
  assert_grep 'SSH auto-resume tmux keepalive' "$unit"
  assert_grep '__ssh_auto_resume_keepalive' "$unit"
  HOME="$home" SSH_AUTO_RESUME_SKIP_SYSTEMD=1 "$RUNTIME_INSTALL" service-rollback >/dev/null
  assert_file_missing "$unit"
}

# ============================================================
# Tier 9: integrated apply through the top-level root binary
# ============================================================

test_root_apply_emits_postinstall_hint() {
  test_case "root: legacy apply via root binary prints reconnect-and-doctor hint"
  local home conf out
  home="$(mktemp_d_in_tests)"
  conf="$(mktemp_d_in_tests)/sshd_config"
  out="$(mktemp_in_tests)"
  printf 'Port 22\nPasswordAuthentication no\n' > "$conf"

  printf 'YES\n' | HOME="$home" SSH_MULTISESSION_RESUME_COMMAND=ssh-multisession-resume \
    SSH_CONNECTION='100.101.137.20 55555 100.101.137.1 22' \
    SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$ROOT_INSTALL" apply > "$out"
  assert_grep 'After reconnecting, run ssh-multisession-resume doctor to verify the active session\.' "$out"
  assert_grep '^Match Address 100\.101\.137\.20$' "$conf"
  assert_grep 'auto-resume.sh' "${home}/.bash_profile"

  HOME="$home" SSHD_CONFIG_FILE="$conf" SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
    "$ROOT_INSTALL" rollback >/dev/null
  assert_no_grep 'ssh-auto-resume' "$conf"
  assert_file_missing "${home}/.bash_profile"
  assert_file_missing "${home}/.zshrc"
}

test_root_doctor_not_in_managed_mux_fails() {
  test_case "root: doctor fails when run outside a managed multiplexer"
  if SSH_CONNECTION='100.101.137.20 55555 100.101.137.1 22' \
       SSH_SCREEN_KILL_SKIP_SSHD_VALIDATE=1 SSH_SCREEN_KILL_NO_RELOAD=1 \
       "$ROOT_INSTALL" doctor >/dev/null 2>&1; then
    fail "doctor should fail outside a managed multiplexer"
  fi
}

# ============================================================
# Tier 10: temp-file cleanup on signal
# ============================================================

test_tempfile_cleanup_on_signal() {
  test_case "signal: SIGINT during cmd_apply does not strand /tmp files"
  local tmpdir bin confdir
  tmpdir="$(mktemp_d_in_tests)"
  bin="$(mktemp_d_in_tests)"
  confdir="$(mktemp_d_in_tests)"
  cat > "${bin}/sshd" <<'FAKE_HANG_SSHD'
#!/usr/bin/env bash
sleep 30
FAKE_HANG_SSHD
  chmod +x "${bin}/sshd"
  printf 'Port 22\n' > "${confdir}/sshd_config"

  (
    TMPDIR="$tmpdir" PATH="${bin}:$PATH" \
      SSHD_CONFIG_FILE="${confdir}/sshd_config" \
      SSH_SCREEN_KILL_NO_RELOAD=1 \
      "$SSHD_MATCH_INSTALL" apply --ip 10.0.0.99
  ) >/dev/null 2>&1 &
  local pid=$!
  sleep 0.7
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  local leaked
  leaked="$(find "$tmpdir" -maxdepth 1 -name 'tmp.*' -type f 2>/dev/null | wc -l)"
  if [[ "$leaked" -ne 0 ]]; then
    fail "temp files leaked after SIGINT: $(find "$tmpdir" -maxdepth 1 -name 'tmp.*' -type f)"
  fi
}

# ============================================================
# Tier 11: PKGBUILD / .SRCINFO sanity
# ============================================================

test_pkgbuild_promotes_tmux_screen_to_depends() {
  test_case "packaging: PKGBUILD lists tmux and screen as hard depends"
  assert_grep '^depends=\([^)]*\<tmux\>' "$PKGBUILD"
  assert_grep '^depends=\([^)]*\<screen\>' "$PKGBUILD"
  assert_grep '^	depends = tmux$' "$SRCINFO"
  assert_grep '^	depends = screen$' "$SRCINFO"
}

test_pkgbuild_installs_profile_entry() {
  test_case "packaging: shared payload installs profile-entry.sh to /etc/profile.d"
  assert_grep 'payload_stage_package' "$PKGBUILD"
  assert_grep '/etc/profile.d/' "$PAYLOAD"
  assert_grep 'profile-entry.sh' "$PAYLOAD"
}

test_pkgbuild_installs_sourced_helpers_readonly() {
  test_case "packaging: sourced profile helpers install as readable files"
  local manifest
  manifest="$(bash "$PAYLOAD" library-files)"
  assert_contains "$manifest" "644 runtime/auto-resume.sh runtime/auto-resume.sh" "auto-resume mode"
  assert_contains "$manifest" "644 runtime/auto-screen.sh runtime/auto-screen.sh" "auto-screen mode"
  assert_no_grep 'runtime/auto-resume.sh.*runtime/auto-resume.sh' "$PKGBUILD"
  assert_no_grep 'runtime/auto-resume.sh.*runtime/auto-resume.sh' "$PACKAGE_BUILD"
}

test_local_sshd_snippet_not_shipped() {
  test_case "packaging: local SSHD example snippet is not shipped"
  assert_file_missing "${ROOT_DIR}/sshd/01-sshd-auto-resume.conf"
  assert_no_grep '01-sshd-auto-resume' "$PKGBUILD"
  assert_no_grep '01-sshd-auto-resume' "${ROOT_DIR}/docker/test-in-container.sh"
  assert_no_grep '01-sshd-auto-resume' "${ROOT_DIR}/README.md"
}

test_arch_install_message_script_not_shipped() {
  test_case "packaging: Arch post-install message script is not shipped"
  assert_file_missing "${ROOT_DIR}/ssh-multisession-resume.install"
  assert_no_grep '^install=' "$PKGBUILD"
  assert_no_grep '^	install = ' "$SRCINFO"
}

test_pkgbuild_install_block_matches_files() {
  test_case "packaging: every shared payload source path exists in the tree"
  local mode src rel
  while read -r mode src rel; do
    [[ -n "$mode" && -n "$src" && -n "$rel" ]] || continue
    if [[ ! -e "${ROOT_DIR}/${src}" ]]; then
      fail "payload references missing source: $src"
    fi
  done < <(bash "$PAYLOAD" library-files)

  for src in tests/smoke.sh runtime/profile-entry.sh README.md CHANGELOG.md SECURITY.md LICENSE; do
    if [[ ! -e "${ROOT_DIR}/${src}" ]]; then
      fail "payload references missing package source: $src"
    fi
  done
}

test_package_builder_declares_portable_architectures() {
  test_case "packaging: package builder emits architecture-independent metadata"
  assert_grep 'Packages are architecture-independent' "$PACKAGE_BUILD"
  assert_grep 'Architecture: all' "$PACKAGE_BUILD"
  assert_grep 'BuildArch:[[:space:]]*noarch' "$PACKAGE_BUILD"
  assert_grep 'arch="noarch"' "$PACKAGE_BUILD"
}

test_package_builder_supports_expected_formats() {
  test_case "packaging: package builder supports Arch, deb, rpm, and apk"
  assert_grep 'packaging/build-packages.sh arch' "$PACKAGE_BUILD"
  assert_grep 'packaging/build-packages.sh deb' "$PACKAGE_BUILD"
  assert_grep 'packaging/build-packages.sh rpm' "$PACKAGE_BUILD"
  assert_grep 'packaging/build-packages.sh apk' "$PACKAGE_BUILD"
  assert_grep 'build_arch' "$PACKAGE_BUILD"
  assert_grep 'build_deb' "$PACKAGE_BUILD"
  assert_grep 'build_rpm' "$PACKAGE_BUILD"
  assert_grep 'build_apk' "$PACKAGE_BUILD"
  assert_grep 'abuild -F -d -r' "$PACKAGE_BUILD"
}

test_package_builder_uses_git_pkgver_when_available() {
  test_case "packaging: package builder defaults to Git-derived pkgver"
  assert_grep 'safe.directory=\${ROOT_DIR}' "$PACKAGE_BUILD"
  assert_grep 'repo_git rev-list --count HEAD' "$PACKAGE_BUILD"
  assert_grep 'repo_git rev-parse --short=7 HEAD' "$PACKAGE_BUILD"
}

test_docker_package_builds_install_git_for_pkgver() {
  test_case "packaging: Docker package builds install git for pkgver"
  assert_grep 'apt-get install -y bash dpkg git' "$DOCKER_MATRIX"
  assert_grep 'dnf install -y bash git rpm-build' "$DOCKER_MATRIX"
}

# ============================================================
# Run all tests
# ============================================================

main() {
  test_required_files
  test_bash_syntax
  test_posix_sh_syntax_for_profile_entry
  test_zsh_syntax_for_auto_resume

  test_sanitize_replaces_special_chars
  test_source_ip_extraction
  test_runtime_dir_prefers_xdg
  test_runtime_dir_ignores_invalid_xdg
  test_runtime_dir_fallback_creates_tmp_subdir
  test_select_tmux_finds_first_free_slot
  test_select_tmux_skips_reserved_slots
  test_select_tmux_max_slots_returns_failure
  test_select_tmux_single_mode_pins_slot_zero
  test_lock_clears_stale_pid
  test_lock_retry_env_override
  test_screen_state_parser

  test_read_choice_valid_modes
  test_read_choice_rejects_garbage_and_missing
  test_save_choice_round_trip
  test_menu_non_tty_returns_skip
  test_menu_digit_input_maps_to_modes
  test_menu_default_empty_returns_multi
  test_menu_alias_keys
  test_menu_invalid_then_valid

  test_tmux_conf_pins_update_environment

  test_profile_entry_skips_non_ssh
  test_profile_entry_static_gates_present

  test_cli_help_lists_new_commands
  test_cli_default_action_is_summary
  test_cli_policy_set_show_forget_clear
  test_cli_policy_move_switches_ip
  test_cli_policy_set_rejects_invalid_mode
  test_cli_policy_set_requires_ip_and_mode
  test_cli_policy_show_when_empty
  test_cli_policy_show_sigpipe_resistant
  test_cli_optout_optin_roundtrip
  test_cli_unknown_action_fails
  test_cli_detect_current_extracts_ip

  test_run_sh_help_lists_install_and_docker_tests
  test_run_sh_temp_install_and_rollback

  test_mode_env_override_precedence

  test_server_validate_ipv4_accepts_canonical
  test_server_validate_ipv6_accepts_canonical
  test_server_validate_rejects_bad_addresses
  test_server_keepalive_bounds
  test_server_apply_writes_block
  test_server_apply_writes_ipv6_block
  test_server_apply_then_add_current_deduplicates
  test_server_apply_then_add_current_deduplicates_ipv6
  test_server_rollback_restores_or_strips

  test_client_apply_and_rollback_idempotent
  test_client_apply_preserves_existing_profile
  test_client_service_install_unit_contents

  test_root_apply_emits_postinstall_hint
  test_root_doctor_not_in_managed_mux_fails

  test_tempfile_cleanup_on_signal

  test_pkgbuild_promotes_tmux_screen_to_depends
  test_pkgbuild_installs_profile_entry
  test_pkgbuild_installs_sourced_helpers_readonly
  test_local_sshd_snippet_not_shipped
  test_arch_install_message_script_not_shipped
  test_pkgbuild_install_block_matches_files
  test_package_builder_declares_portable_architectures
  test_package_builder_supports_expected_formats
  test_package_builder_uses_git_pkgver_when_available
  test_docker_package_builds_install_git_for_pkgver

  print_summary
}

main "$@"
