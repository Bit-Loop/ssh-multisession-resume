#!/usr/bin/env bash
# shellcheck shell=bash
# Test harness for ssh-multisession-resume. Sourced by tests/smoke.sh.

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TESTS_FAILED_NAMES=()
CURRENT_TEST=""
CURRENT_TEST_FAILED=0
VERBOSE="${SSH_MULTISESSION_TEST_VERBOSE:-0}"

_t_red()    { printf '\033[31m%s\033[0m' "$1"; }
_t_green()  { printf '\033[32m%s\033[0m' "$1"; }
_t_yellow() { printf '\033[33m%s\033[0m' "$1"; }
_t_dim()    { printf '\033[2m%s\033[0m' "$1"; }

test_case() {
  if [[ -n "$CURRENT_TEST" ]]; then
    _finish_case
  fi
  CURRENT_TEST="$1"
  CURRENT_TEST_FAILED=0
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$VERBOSE" == "1" ]]; then
    printf '  %s %s\n' "$(_t_dim '...')" "$CURRENT_TEST"
  fi
}

_finish_case() {
  if [[ "$CURRENT_TEST_FAILED" -eq 0 ]]; then
    if [[ "$VERBOSE" == "1" ]]; then
      printf '  %s %s\n' "$(_t_green 'PASS')" "$CURRENT_TEST"
    fi
  fi
}

fail() {
  if [[ "$CURRENT_TEST_FAILED" -eq 0 ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_FAILED_NAMES+=("$CURRENT_TEST")
  fi
  CURRENT_TEST_FAILED=1
  printf '  %s %s\n' "$(_t_red 'FAIL')" "$CURRENT_TEST" >&2
  printf '         %s\n' "$1" >&2
}

assert_eq() {
  local actual="$1" expected="$2" label="${3:-values differ}"
  if [[ "$actual" != "$expected" ]]; then
    fail "${label}: expected '${expected}', got '${actual}'"
    return 1
  fi
  return 0
}

assert_ne() {
  local actual="$1" not_expected="$2" label="${3:-values match}"
  if [[ "$actual" == "$not_expected" ]]; then
    fail "${label}: expected NOT '${not_expected}', got '${actual}'"
    return 1
  fi
  return 0
}

assert_file_exists() {
  if [[ ! -f "$1" ]]; then
    fail "expected file to exist: $1"
    return 1
  fi
  return 0
}

assert_file_missing() {
  if [[ -e "$1" ]]; then
    fail "expected no file at: $1"
    return 1
  fi
  return 0
}

assert_dir_empty() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  if [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    fail "expected empty dir: $dir (contents: $(ls -A "$dir"))"
    return 1
  fi
  return 0
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-substring missing}"
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) fail "${label}: did not find '${needle}' in: ${haystack}"; return 1 ;;
  esac
}

assert_grep() {
  local pattern="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    fail "assert_grep: file missing: $file"
    return 1
  fi
  if ! grep -qE -- "$pattern" "$file"; then
    fail "expected pattern '${pattern}' in ${file}"
    return 1
  fi
  return 0
}

assert_no_grep() {
  local pattern="$1" file="$2"
  if [[ -f "$file" ]] && grep -qE -- "$pattern" "$file"; then
    fail "did not expect pattern '${pattern}' in ${file}"
    return 1
  fi
  return 0
}

assert_status() {
  local expected="$1"; shift
  local actual
  set +e
  ( "$@" ) >/dev/null 2>&1
  actual=$?
  set -e
  if [[ "$actual" != "$expected" ]]; then
    fail "command exited ${actual}, expected ${expected}: $*"
    return 1
  fi
  return 0
}

expect_success() {
  local out
  out="$(mktemp)"
  if ! "$@" >"$out" 2>&1; then
    fail "command failed: $* (output: $(cat "$out"))"
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  return 0
}

expect_failure() {
  local out
  out="$(mktemp)"
  if "$@" >"$out" 2>&1; then
    fail "command unexpectedly succeeded: $* (output: $(cat "$out"))"
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  return 0
}

# Run a snippet of code in a fresh bash, capture its output.
# Usage: run_in_bash "<code>" ENV_VAR=val ENV_VAR2=val2 ...
run_in_bash() {
  local code="$1"; shift
  env "$@" bash -c "$code"
}

# Like run_in_bash but expects failure.
run_in_bash_fail() {
  local code="$1"; shift
  if env "$@" bash -c "$code" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

print_summary() {
  if [[ -n "$CURRENT_TEST" ]]; then
    _finish_case
  fi

  echo
  if [[ "$TESTS_FAILED" -eq 0 ]]; then
    printf '%s %d/%d tests passed\n' "$(_t_green 'OK')" "$TESTS_RUN" "$TESTS_RUN"
    return 0
  fi

  printf '%s %d/%d tests passed\n' "$(_t_red 'FAIL')" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
  printf 'Failed:\n'
  local name
  for name in "${TESTS_FAILED_NAMES[@]}"; do
    printf '  - %s\n' "$name"
  done
  return 1
}
