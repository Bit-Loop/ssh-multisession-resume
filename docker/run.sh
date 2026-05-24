#!/usr/bin/env bash
# Host-side driver: build the Arch container image and run the in-container
# test script. Idempotent. Logs into docker/output/<timestamp>.log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

IMAGE_TAG="${SSH_MULTISESSION_TEST_IMAGE:-ssh-multisession-resume-test:arch}"
LOG_DIR="${SCRIPT_DIR}/output"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(date -u +'%Y%m%dT%H%M%SZ').log"

usage() {
  cat <<USAGE
Usage:
  $0                 build image then run tests, log to ${LOG_DIR}
  $0 build           build image only
  $0 test            run tests against an existing image
  $0 shell           drop into an interactive shell inside the container

Env:
  SSH_MULTISESSION_TEST_IMAGE   override the image tag (default: ${IMAGE_TAG})
  SSH_MULTISESSION_TEST_VERBOSE  set to 1 for per-test PASS lines
USAGE
}

build() {
  printf 'Building image %s ...\n' "$IMAGE_TAG"
  docker build \
    -f "${SCRIPT_DIR}/Dockerfile" \
    -t "$IMAGE_TAG" \
    "$REPO_DIR"
}

run_tests() {
  printf 'Running container tests, logging to %s ...\n' "$LOG_FILE"
  if docker run --rm \
       -e SSH_MULTISESSION_TEST_VERBOSE="${SSH_MULTISESSION_TEST_VERBOSE:-0}" \
       "$IMAGE_TAG" 2>&1 | tee "$LOG_FILE"; then
    printf '\nLog saved to %s\n' "$LOG_FILE"
  else
    rc=$?
    printf '\nContainer tests failed (exit %s). Log: %s\n' "$rc" "$LOG_FILE" >&2
    return "$rc"
  fi
}

shell() {
  docker run --rm -it \
    -e SSH_MULTISESSION_TEST_VERBOSE="${SSH_MULTISESSION_TEST_VERBOSE:-0}" \
    "$IMAGE_TAG" /bin/bash
}

case "${1:-all}" in
  all)   build && run_tests ;;
  build) build ;;
  test)  run_tests ;;
  shell) shell ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
