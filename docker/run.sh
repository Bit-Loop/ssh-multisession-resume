#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
LOG_DIR="${SCRIPT_DIR}/output"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(date -u +'%Y%m%dT%H%M%SZ').log"

usage() {
  cat <<USAGE
Usage:
  ./docker/run.sh package          local PKGBUILD/package test on Arch
  ./docker/run.sh arch             source install + SSH login on Arch
  ./docker/run.sh debian           source install + SSH login on Debian
  ./docker/run.sh ubuntu           source install + SSH login on Ubuntu
  ./docker/run.sh fedora           source install + SSH login on Fedora
  ./docker/run.sh yum              source install + SSH login on yum
  ./docker/run.sh opensuse         source install + SSH login on openSUSE
  ./docker/run.sh alpine           source install + SSH login on Alpine
  ./docker/run.sh all              package + all source distro tests
  ./docker/run.sh aur              pull AUR package in vanilla Arch and SSH-test it
  ./docker/run.sh build-package FORMAT
                                  build package artifact: all, arch, deb, rpm, apk
  ./docker/run.sh shell DISTRO     interactive shell in a distro test image

Logs are written to ${LOG_DIR}.
USAGE
}

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

image_name() {
  printf 'ssh-multisession-resume-test:%s\n' "$1"
}

distro_base() {
  case "$1" in
    package|arch) printf '%s\n' 'archlinux:base-devel' ;;
    debian)       printf '%s\n' 'debian:stable-slim' ;;
    ubuntu)       printf '%s\n' 'ubuntu:24.04' ;;
    fedora)       printf '%s\n' 'fedora:latest' ;;
    yum)          printf '%s\n' 'amazonlinux:2' ;;
    opensuse)     printf '%s\n' 'opensuse/leap:latest' ;;
    alpine)       printf '%s\n' 'alpine:latest' ;;
    *) return 1 ;;
  esac
}

distro_bootstrap() {
  case "$1" in
    package)
      printf '%s\n' 'pacman -Syu --noconfirm --needed bash sudo git zsh dash coreutils findutils gawk grep sed procps-ng util-linux lsof ca-certificates shadow'
      ;;
    arch)
      printf '%s\n' 'pacman -Syu --noconfirm --needed bash sudo git coreutils findutils gawk grep sed procps-ng util-linux ca-certificates shadow'
      ;;
    debian|ubuntu)
      printf '%s\n' 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash sudo git ca-certificates passwd procps coreutils findutils gawk grep sed util-linux'
      ;;
    fedora)
      printf '%s\n' 'dnf install -y bash sudo git ca-certificates shadow-utils procps-ng coreutils findutils gawk grep sed util-linux'
      ;;
    yum)
      printf '%s\n' 'yum install -y bash sudo git ca-certificates shadow-utils procps-ng coreutils findutils gawk grep sed util-linux'
      ;;
    opensuse)
      printf '%s\n' 'zypper --non-interactive refresh && zypper --non-interactive install -y bash sudo git ca-certificates shadow procps coreutils findutils gawk grep sed util-linux'
      ;;
    alpine)
      printf '%s\n' 'apk add --no-cache bash sudo git ca-certificates shadow procps coreutils findutils gawk grep sed util-linux'
      ;;
    *)
      return 1
      ;;
  esac
}

package_build_base() {
  case "$1" in
    arch) printf '%s\n' 'archlinux:base-devel' ;;
    deb)  printf '%s\n' 'debian:stable-slim' ;;
    rpm)  printf '%s\n' 'fedora:latest' ;;
    apk)  printf '%s\n' 'alpine:latest' ;;
    *) return 1 ;;
  esac
}

package_build_bootstrap() {
  case "$1" in
    arch)
      printf '%s\n' 'pacman -Syu --noconfirm --needed bash sudo git coreutils findutils gawk grep sed tar gzip zstd shadow'
      ;;
    deb)
      printf '%s\n' 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash dpkg git coreutils findutils gawk grep sed tar gzip'
      ;;
    rpm)
      printf '%s\n' 'dnf install -y bash git rpm-build coreutils findutils gawk grep sed tar gzip'
      ;;
    apk)
      printf '%s\n' 'apk add --no-cache alpine-sdk bash coreutils findutils gawk grep sed tar gzip'
      ;;
    *)
      return 1
      ;;
  esac
}

build_image() {
  local distro="$1"
  local image base bootstrap
  image="$(image_name "$distro")"
  base="$(distro_base "$distro")"
  bootstrap="$(distro_bootstrap "$distro")"

  log "Building ${image} from ${base} ..."
  docker build \
    -f "${SCRIPT_DIR}/Dockerfile" \
    --build-arg "BASE_IMAGE=${base}" \
    --build-arg "BOOTSTRAP=${bootstrap}" \
    -t "$image" \
    "$REPO_DIR" 2>&1 | tee -a "$LOG_FILE"
}

run_image() {
  local distro="$1"
  local mode="$2"
  local image
  image="$(image_name "$distro")"

  log "Running ${distro} (${mode}) ..."
  docker run --rm \
    -e SSH_MULTISESSION_TEST_VERBOSE="${SSH_MULTISESSION_TEST_VERBOSE:-0}" \
    "$image" /work/docker/test-in-container.sh --mode "$mode" 2>&1 | tee -a "$LOG_FILE"
}

run_package() {
  build_image package
  run_image package arch-package
}

run_source_distro() {
  local distro="$1"
  build_image "$distro"
  run_image "$distro" source-login
}

run_all() {
  local distro
  run_package
  for distro in arch debian ubuntu fedora yum opensuse alpine; do
    run_source_distro "$distro"
  done
}

run_package_build_one() {
  local format="$1"
  local base bootstrap uid gid

  base="$(package_build_base "$format")" || {
    usage >&2
    exit 2
  }
  bootstrap="$(package_build_bootstrap "$format")"
  uid="$(id -u)"
  gid="$(id -g)"

  log "Building ${format} package artifact in ${base} ..."
  docker run --rm \
    -v "${REPO_DIR}:/work" \
    -w /work \
    -e SSH_MULTISESSION_DIST_DIR=/work/dist \
    "$base" /bin/sh -lc \
      "${bootstrap} && /bin/bash /work/packaging/build-packages.sh ${format} && chown -R ${uid}:${gid} /work/dist" \
    2>&1 | tee -a "$LOG_FILE"
}

run_package_build() {
  local format="${1:-all}"
  local item
  case "$format" in
    all)
      for item in arch deb rpm apk; do
        run_package_build_one "$item"
      done
      ;;
    arch|deb|rpm|apk)
      run_package_build_one "$format"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

run_aur() {
  log "Running vanilla Arch AUR test ..."
  docker run --rm \
    -v "${SCRIPT_DIR}/aur-test.sh:/aur-test.sh:ro" \
    archlinux:base-devel /bin/bash /aur-test.sh 2>&1 | tee -a "$LOG_FILE"
}

run_shell() {
  local distro="${1:-arch}"
  local image
  build_image "$distro"
  image="$(image_name "$distro")"
  docker run --rm -it "$image" /bin/bash
}

case "${1:-all}" in
  package)  run_package ;;
  arch|debian|ubuntu|fedora|yum|opensuse|alpine)
    run_source_distro "$1"
    ;;
  all)      run_all ;;
  aur)      run_aur ;;
  build-package|build-packages)
    shift
    run_package_build "${1:-all}"
    ;;
  package:all|packages)
    run_package_build all
    ;;
  package:arch)
    run_package_build arch
    ;;
  package:deb)
    run_package_build deb
    ;;
  package:rpm)
    run_package_build rpm
    ;;
  package:apk)
    run_package_build apk
    ;;
  shell)    shift; run_shell "${1:-arch}" ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

log "Log saved to $LOG_FILE"
