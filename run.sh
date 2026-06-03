#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLER="${ROOT_DIR}/installer/source.sh"
DOCKER_MATRIX="${ROOT_DIR}/docker/matrix.sh"
SMOKE="${ROOT_DIR}/tests/smoke.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./run.sh [install|status|rollback|deps]
  ./run.sh test[:all|:aur|:arch|:debian|:ubuntu|:fedora|:yum|:opensuse|:alpine]
  ./run.sh package[:arch|:deb|:rpm|:apk]
  ./run.sh shell [distro]
USAGE
}

ACTION="${1:-install}"

case "$ACTION" in
  install|status|rollback|deps)
    exec "$INSTALLER" "$@"
    ;;
  test)
    exec env -u TMUX -u STY "$SMOKE"
    ;;
  test:all)
    exec "$DOCKER_MATRIX" all
    ;;
  test:aur)
    exec "$DOCKER_MATRIX" aur
    ;;
  test:*)
    exec "$DOCKER_MATRIX" "${ACTION#test:}" "${@:2}"
    ;;
  package|package:all)
    exec "$DOCKER_MATRIX" build-package all
    ;;
  package:*)
    exec "$DOCKER_MATRIX" build-package "${ACTION#package:}" "${@:2}"
    ;;
  shell)
    shift
    exec "$DOCKER_MATRIX" shell "${1:-arch}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown action: ${ACTION}" >&2
    usage >&2
    exit 2
    ;;
esac
