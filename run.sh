#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NAME="ssh-multisession-resume"

PREFIX="${SSH_MULTISESSION_PREFIX:-/usr/local}"
LIB_DIR="${SSH_MULTISESSION_LIB_DIR:-${PREFIX}/lib/${NAME}}"
BIN_DIR="${SSH_MULTISESSION_BIN_DIR:-${PREFIX}/bin}"
ETC_DIR="${SSH_MULTISESSION_ETC_DIR:-/etc}"
PROFILE_HOOK="${ETC_DIR}/profile.d/${NAME}.sh"
BIN_PATH="${BIN_DIR}/${NAME}"

PROFILE_BLOCK_START="# BEGIN ${NAME} profile hook"
PROFILE_BLOCK_END="# END ${NAME} profile hook"
ZSH_BLOCK_START="# BEGIN ${NAME} zsh hook"
ZSH_BLOCK_END="# END ${NAME} zsh hook"

ASSUME_YES="${SSH_MULTISESSION_ASSUME_YES:-0}"
SKIP_DEPS="${SSH_MULTISESSION_SKIP_DEPS:-0}"

usage() {
  cat <<USAGE
Usage:
  ./run.sh                         guided source install
  ./run.sh install [--yes]         install from this checkout
  ./run.sh rollback [--yes]        remove source-installed files and hooks
  ./run.sh status                  show source install status
  ./run.sh deps [--yes]            install runtime dependencies
  ./run.sh test                    run local smoke tests
  ./run.sh test:all                run all Docker distro tests
  ./run.sh test:aur                test the AUR package in vanilla Arch
  ./run.sh test:arch               test source install on Arch
  ./run.sh test:debian             test source install on Debian
  ./run.sh test:ubuntu             test source install on Ubuntu
  ./run.sh test:fedora             test source install on Fedora
  ./run.sh test:yum                test source install on a yum image
  ./run.sh test:opensuse           test source install on openSUSE
  ./run.sh test:alpine             test source install on Alpine
  ./run.sh package                 build all distro packages into dist/
  ./run.sh package:arch            build Arch package into dist/
  ./run.sh package:deb             build Debian/Ubuntu .deb into dist/
  ./run.sh package:rpm             build Fedora/openSUSE/RHEL .rpm into dist/
  ./run.sh package:apk             build Alpine .apk into dist/
  ./run.sh shell DISTRO            open a test shell for a distro

Env:
  SSH_MULTISESSION_PREFIX          install prefix (default: /usr/local)
  SSH_MULTISESSION_ETC_DIR         etc root (default: /etc)
  SSH_MULTISESSION_SKIP_DEPS=1     skip package-manager dependency install
  SSH_MULTISESSION_ASSUME_YES=1    do not prompt
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

need_file() {
  [[ -r "$1" ]] || die "Missing required file: $1"
}

needs_root() {
  case "$LIB_DIR:$BIN_DIR:$ETC_DIR" in
    /usr/*|/usr/*:*|*:/usr/*|*:/usr/*:*|/etc*|*:/etc*|/bin*|*:/bin*|/sbin*|*:/sbin*|/lib*|*:/lib*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

as_root() {
  if [[ $EUID -eq 0 ]] || ! needs_root; then
    "$@"
    return
  fi

  command -v sudo >/dev/null 2>&1 || die "sudo is required for system install paths."
  sudo "$@"
}

prompt_yes_no() {
  local prompt="$1"
  local answer=""

  [[ "$ASSUME_YES" == "1" ]] && return 0

  if [[ ! -t 0 || ! -t 1 ]]; then
    die "${prompt} Re-run with --yes or SSH_MULTISESSION_ASSUME_YES=1."
  fi

  while true; do
    printf '%s [y/N]: ' "$prompt"
    IFS= read -r answer || return 1
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

package_manager() {
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
  elif command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt-get
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
  elif command -v yum >/dev/null 2>&1; then
    printf '%s\n' yum
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s\n' zypper
  elif command -v apk >/dev/null 2>&1; then
    printf '%s\n' apk
  else
    return 1
  fi
}

dependency_packages() {
  case "$1" in
    pacman)
      printf '%s\n' bash openssh tmux screen
      ;;
    apt-get)
      printf '%s\n' bash openssh-client openssh-server tmux screen
      ;;
    dnf|yum)
      printf '%s\n' bash openssh-clients openssh-server tmux screen
      ;;
    zypper)
      printf '%s\n' bash openssh tmux screen
      ;;
    apk)
      printf '%s\n' bash openssh-client openssh-server tmux screen
      ;;
    *)
      return 1
      ;;
  esac
}

install_packages() {
  local manager="$1"
  shift
  [[ $# -gt 0 ]] || return 0

  case "$manager" in
    pacman)
      as_root pacman -S --needed --noconfirm "$@"
      ;;
    apt-get)
      as_root apt-get update
      as_root apt-get install -y "$@"
      ;;
    dnf)
      as_root dnf install -y "$@"
      ;;
    yum)
      as_root yum install -y "$@"
      ;;
    zypper)
      as_root zypper --non-interactive install -y "$@"
      ;;
    apk)
      as_root apk add --no-cache "$@"
      ;;
    *)
      die "Unsupported package manager: ${manager}"
      ;;
  esac
}

cmd_deps() {
  local manager
  local -a packages=()

  if [[ "$SKIP_DEPS" == "1" ]]; then
    echo "Skipped dependency install because SSH_MULTISESSION_SKIP_DEPS=1."
    return 0
  fi

  manager="$(package_manager)" || die "No supported package manager found."
  while IFS= read -r package; do
    [[ -n "$package" ]] && packages+=("$package")
  done < <(dependency_packages "$manager")

  echo "package manager: ${manager}"
  echo "installing/checking packages: ${packages[*]}"
  install_packages "$manager" "${packages[@]}"
}

make_temp_file() {
  mktemp "${TMPDIR:-/tmp}/${NAME}.XXXXXX"
}

install_text_file() {
  local mode="$1"
  local dest="$2"
  local content="$3"
  local tmp

  tmp="$(make_temp_file)"
  printf '%s\n' "$content" > "$tmp"
  as_root install -Dm"$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

install_wrapper() {
  local wrapper
  wrapper="#!/usr/bin/env bash
export SSH_MULTISESSION_RESUME_COMMAND=${NAME}
exec ${LIB_DIR}/${NAME} \"\$@\""
  install_text_file 755 "$BIN_PATH" "$wrapper"
}

install_profile_hook() {
  local hook
  hook="# shellcheck shell=sh
_ssh_multisession_resume_lib='${LIB_DIR}'
if [ -r \"\${_ssh_multisession_resume_lib}/client/profile-entry.sh\" ]; then
  SSH_MULTISESSION_RESUME_LIB=\"\${_ssh_multisession_resume_lib}\"
  export SSH_MULTISESSION_RESUME_LIB
  . \"\${_ssh_multisession_resume_lib}/client/profile-entry.sh\"
fi
unset _ssh_multisession_resume_lib"
  install_text_file 644 "$PROFILE_HOOK" "$hook"
}

remove_block() {
  local file="$1"
  local start="$2"
  local end="$3"
  local tmp

  [[ -f "$file" ]] || return 0
  tmp="$(make_temp_file)"
  awk -v start="$start" -v end="$end" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  as_root install -Dm644 "$tmp" "$file"
  rm -f "$tmp"
}

append_block() {
  local file="$1"
  local start="$2"
  local end="$3"
  local body="$4"
  local tmp

  tmp="$(make_temp_file)"
  if [[ -f "$file" ]]; then
    awk -v start="$start" -v end="$end" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$file" > "$tmp"
  fi
  {
    printf '\n%s\n' "$start"
    printf '%s\n' "$body"
    printf '%s\n' "$end"
  } >> "$tmp"
  as_root install -Dm644 "$tmp" "$file"
  rm -f "$tmp"
}

install_profile_bridge() {
  local profile="${ETC_DIR}/profile"
  local body

  body="if [ -r '${PROFILE_HOOK}' ]; then
  . '${PROFILE_HOOK}'
fi"
  append_block "$profile" "$PROFILE_BLOCK_START" "$PROFILE_BLOCK_END" "$body"
}

zsh_hook_candidates() {
  printf '%s\n' \
    "${ETC_DIR}/zsh/zprofile" \
    "${ETC_DIR}/zsh/zshrc" \
    "${ETC_DIR}/zprofile" \
    "${ETC_DIR}/zshrc"
}

install_zsh_hooks() {
  local file parent body have_zsh=0
  [[ "${SSH_MULTISESSION_ZSH_HOOKS:-1}" == "1" ]] || return 0
  command -v zsh >/dev/null 2>&1 && have_zsh=1

  body="if [ -r '${PROFILE_HOOK}' ]; then
  . '${PROFILE_HOOK}'
fi"

  while IFS= read -r file; do
    parent="$(dirname "$file")"
    if [[ -f "$file" || ( "$have_zsh" == "1" && -d "$parent" ) ]]; then
      append_block "$file" "$ZSH_BLOCK_START" "$ZSH_BLOCK_END" "$body"
    fi
  done < <(zsh_hook_candidates)
}

remove_zsh_hooks() {
  local file
  while IFS= read -r file; do
    remove_block "$file" "$ZSH_BLOCK_START" "$ZSH_BLOCK_END"
  done < <(zsh_hook_candidates)
}

install_files() {
  need_file "${ROOT_DIR}/${NAME}"
  need_file "${ROOT_DIR}/client/profile-entry.sh"
  need_file "${ROOT_DIR}/client/auto-resume.sh"
  need_file "${ROOT_DIR}/client/tmux-auto-resume.conf"
  need_file "${ROOT_DIR}/client/screen-auto-resume.screenrc"
  need_file "${ROOT_DIR}/server/install.sh"

  as_root install -Dm755 "${ROOT_DIR}/${NAME}" "${LIB_DIR}/${NAME}"
  as_root install -Dm755 "${ROOT_DIR}/client/install.sh" "${LIB_DIR}/client/install.sh"
  as_root install -Dm644 "${ROOT_DIR}/client/auto-resume.sh" "${LIB_DIR}/client/auto-resume.sh"
  as_root install -Dm644 "${ROOT_DIR}/client/auto-screen.sh" "${LIB_DIR}/client/auto-screen.sh"
  as_root install -Dm644 "${ROOT_DIR}/client/profile-entry.sh" "${LIB_DIR}/client/profile-entry.sh"
  as_root install -Dm644 "${ROOT_DIR}/client/tmux-auto-resume.conf" "${LIB_DIR}/client/tmux-auto-resume.conf"
  as_root install -Dm644 "${ROOT_DIR}/client/screen-auto-resume.screenrc" "${LIB_DIR}/client/screen-auto-resume.screenrc"
  as_root install -Dm644 "${ROOT_DIR}/client/screen-hangup-off.screenrc" "${LIB_DIR}/client/screen-hangup-off.screenrc"
  as_root install -Dm755 "${ROOT_DIR}/server/install.sh" "${LIB_DIR}/server/install.sh"
  install_wrapper
  install_profile_hook
  install_profile_bridge
  install_zsh_hooks
}

cmd_install() {
  prompt_yes_no "Install ${NAME} from this checkout?" || {
    echo "No changes made."
    return 0
  }
  cmd_deps
  install_files
  echo
  echo "Install complete."
  echo "Open a new SSH session, pick single / multi / skip, then run: ${NAME} doctor"
}

safe_remove_lib_dir() {
  case "$LIB_DIR" in
    */ssh-multisession-resume)
      as_root rm -rf "$LIB_DIR"
      ;;
    *)
      die "Refusing to remove unexpected lib dir: $LIB_DIR"
      ;;
  esac
}

cmd_rollback() {
  prompt_yes_no "Remove source-installed ${NAME} files and hooks?" || {
    echo "No changes made."
    return 0
  }

  remove_block "${ETC_DIR}/profile" "$PROFILE_BLOCK_START" "$PROFILE_BLOCK_END"
  remove_zsh_hooks
  as_root rm -f "$PROFILE_HOOK" "$BIN_PATH"
  safe_remove_lib_dir
  echo "Rollback complete."
}

cmd_status() {
  printf 'command: %s\n' "$BIN_PATH"
  [[ -x "$BIN_PATH" ]] && echo "  installed" || echo "  missing"
  printf 'library: %s\n' "$LIB_DIR"
  [[ -x "${LIB_DIR}/${NAME}" ]] && echo "  installed" || echo "  missing"
  printf 'profile hook: %s\n' "$PROFILE_HOOK"
  [[ -r "$PROFILE_HOOK" ]] && echo "  installed" || echo "  missing"
}

cmd_test() {
  env -u TMUX -u STY "${ROOT_DIR}/tests/smoke.sh"
}

cmd_docker() {
  local action="$1"
  shift || true
  "${ROOT_DIR}/docker/run.sh" "$action" "$@"
}

cmd_package() {
  local format="$1"
  cmd_docker build-package "$format"
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        ASSUME_YES=1
        ;;
      --skip-deps)
        SKIP_DEPS=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

ACTION="${1:-install}"
if [[ "$ACTION" == --* ]]; then
  ACTION="install"
else
  shift || true
fi

case "$ACTION" in
  install)
    parse_flags "$@"
    cmd_install
    ;;
  rollback)
    parse_flags "$@"
    cmd_rollback
    ;;
  status)
    cmd_status
    ;;
  deps)
    parse_flags "$@"
    cmd_deps
    ;;
  test)
    cmd_test
    ;;
  test:all)
    cmd_docker all
    ;;
  test:aur)
    cmd_docker aur
    ;;
  test:arch)
    cmd_docker arch
    ;;
  test:debian)
    cmd_docker debian
    ;;
  test:ubuntu)
    cmd_docker ubuntu
    ;;
  test:fedora)
    cmd_docker fedora
    ;;
  test:yum)
    cmd_docker yum
    ;;
  test:opensuse)
    cmd_docker opensuse
    ;;
  test:alpine)
    cmd_docker alpine
    ;;
  package|package:all)
    cmd_package all
    ;;
  package:arch)
    cmd_package arch
    ;;
  package:deb)
    cmd_package deb
    ;;
  package:rpm)
    cmd_package rpm
    ;;
  package:apk)
    cmd_package apk
    ;;
  shell)
    cmd_docker shell "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    die "Unknown action: ${ACTION}"
    ;;
esac
