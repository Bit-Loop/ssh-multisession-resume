#!/usr/bin/env bash
# Host-side driver: build the Arch container image and run the in-container
# test script. Idempotent. Logs into docker/output/<timestamp>.log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

IMAGE_TAG="${SSH_MULTISESSION_TEST_IMAGE:-ssh-multisession-resume-test:arch}"
VOLUME_NAME="${SSH_MULTISESSION_TEST_VOLUME:-ssh-multisession-resume-test-home}"
LOG_DIR="${SCRIPT_DIR}/output"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(date -u +'%Y%m%dT%H%M%SZ').log"

usage() {
  cat <<USAGE
Usage:
  $0                 build image then run tests, log to ${LOG_DIR}
  $0 build           build image only
  $0 test            run single-container test against an existing image
  $0 persistence     run the two-container reboot-persistence test
  $0 shell           drop into an interactive shell inside the container

Env:
  SSH_MULTISESSION_TEST_IMAGE    override the image tag (default: ${IMAGE_TAG})
  SSH_MULTISESSION_TEST_VOLUME   override the persistence volume name
  SSH_MULTISESSION_TEST_VERBOSE  set to 1 for per-test PASS lines
USAGE
}

log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }

build() {
  log "Building image $IMAGE_TAG ..."
  docker build \
    -f "${SCRIPT_DIR}/Dockerfile" \
    -t "$IMAGE_TAG" \
    "$REPO_DIR" 2>&1 | tee -a "$LOG_FILE"
}

run_tests() {
  log "Running container tests, logging to $LOG_FILE ..."
  if docker run --rm \
       -e SSH_MULTISESSION_TEST_VERBOSE="${SSH_MULTISESSION_TEST_VERBOSE:-0}" \
       "$IMAGE_TAG" 2>&1 | tee -a "$LOG_FILE"; then
    log "Log saved to $LOG_FILE"
  else
    rc=$?
    log "Container tests failed (exit $rc). Log: $LOG_FILE"
    return "$rc"
  fi
}

persistence() {
  # Reboot-persistence flow:
  #   1. Recreate a named docker volume to back /home/tester.
  #   2. Container A mounts it, runs the full suite, and saves policy state.
  #   3. Container A exits.
  #   4. Container B mounts the same volume and runs the verify phase
  #      against the persisted state — proving that nothing the user did
  #      first time is needed again across a "reboot".
  log "Persistence test starting (volume: $VOLUME_NAME)"

  if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    log "Removing pre-existing $VOLUME_NAME ..."
    docker volume rm "$VOLUME_NAME" >/dev/null
  fi
  docker volume create "$VOLUME_NAME" >/dev/null

  log
  log "[Phase 1/2] container A: save state into $VOLUME_NAME"
  if ! docker run --rm \
       -v "${VOLUME_NAME}:/home/tester" \
       "$IMAGE_TAG" /work/docker/test-in-container.sh --phase save 2>&1 | tee -a "$LOG_FILE"; then
    log "Phase 1 failed"
    docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
    return 1
  fi

  log
  log "[Phase 2/2] container B: verify state against $VOLUME_NAME"
  if ! docker run --rm \
       -v "${VOLUME_NAME}:/home/tester" \
       "$IMAGE_TAG" /work/docker/test-in-container.sh --phase verify 2>&1 | tee -a "$LOG_FILE"; then
    log "Phase 2 failed"
    docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
    return 1
  fi

  docker volume rm "$VOLUME_NAME" >/dev/null
  log "Persistence test OK."
}

shell() {
  docker run --rm -it \
    -e SSH_MULTISESSION_TEST_VERBOSE="${SSH_MULTISESSION_TEST_VERBOSE:-0}" \
    "$IMAGE_TAG" /bin/bash
}

case "${1:-all}" in
  all)         build && run_tests ;;
  build)       build ;;
  test)        run_tests ;;
  persistence) persistence ;;
  shell)       shell ;;
  -h|--help)   usage ;;
  *)           usage >&2; exit 2 ;;
esac
