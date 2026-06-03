#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="${SSH_MULTISESSION_DIST_DIR:-${ROOT_DIR}/dist}"
PKG_NAME="ssh-multisession-resume"
PKG_REL="${SSH_MULTISESSION_PACKAGE_RELEASE:-1}"
PKG_VERSION="${SSH_MULTISESSION_PACKAGE_VERSION:-}"

# shellcheck source=payload.sh
. "${ROOT_DIR}/packaging/payload.sh"

repo_git() {
  git -c "safe.directory=${ROOT_DIR}" -C "$ROOT_DIR" "$@"
}

if [[ -z "$PKG_VERSION" ]]; then
  if repo_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if repo_git describe --long --tags --abbrev=7 >/dev/null 2>&1; then
      PKG_VERSION="$(repo_git describe --long --tags --abbrev=7 | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g')"
    else
      PKG_VERSION="$(printf '0.r%s.g%s' "$(repo_git rev-list --count HEAD)" "$(repo_git rev-parse --short=7 HEAD)")"
    fi
  else
    PKG_VERSION="$(awk -F= '$1 == "pkgver" { print $2; exit }' "${ROOT_DIR}/PKGBUILD")"
  fi
fi

usage() {
  cat <<USAGE
Usage:
  packaging/build-packages.sh all
  packaging/build-packages.sh arch
  packaging/build-packages.sh deb
  packaging/build-packages.sh rpm
  packaging/build-packages.sh apk

Artifacts are written to ${OUT_DIR}.
Packages are architecture-independent: Arch any, Debian all, RPM noarch, APK noarch.
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

postinstall_message() {
  cat <<'EOF'
ssh-multisession-resume installed.

Nothing to configure. Open a new SSH session from any source IP. On the
first connect, a menu will ask whether to use single / multi / skip mode;
your choice is saved per source IP and persists across reboots.

Optional commands:
  ssh-multisession-resume               status + saved policies
  ssh-multisession-resume doctor        diagnose the current session
  ssh-multisession-resume policy show   list saved per-IP choices
  ssh-multisession-resume opt-out       disable the menu for this user

Tip: the menu is shown by /etc/profile.d/ssh-multisession-resume.sh for any
interactive SSH login. To disable system-wide, remove that file.
EOF
}

stage_payload() {
  local root="$1"
  rm -rf "$root"
  payload_stage_package "$ROOT_DIR" "$root" "$PKG_NAME" "$PKG_NAME"
}

build_deb() {
  need_cmd dpkg-deb
  mkdir -p "$OUT_DIR"

  local work root out
  work="$(mktemp -d)"
  root="${work}/${PKG_NAME}_${PKG_VERSION}-${PKG_REL}_all"
  out="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}-${PKG_REL}_all.deb"
  stage_payload "$root"

  install -dm755 "${root}/DEBIAN"
  cat > "${root}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}-${PKG_REL}
Section: admin
Priority: optional
Architecture: all
Maintainer: bit-loop <isaiah.fpga@gmail.com>
Depends: bash, openssh-client, openssh-server, tmux, screen
Homepage: https://github.com/Bit-Loop/${PKG_NAME}
Description: Persistent multi-session SSH auto-resume utility backed by tmux
 Opens a menu on interactive SSH login and resumes saved tmux sessions by
 source IP. User choices are saved under ~/.config/ssh-multisession-resume.
EOF
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'set -e'
    printf '%s\n' "cat <<'EOF'"
    postinstall_message
    printf '%s\n' 'EOF'
  } > "${root}/DEBIAN/postinst"
  chmod 755 "${root}/DEBIAN/postinst"

  dpkg-deb --build "$root" "$out"
  rm -rf "$work"
  echo "$out"
}

build_rpm() {
  need_cmd rpmbuild
  mkdir -p "$OUT_DIR"

  local work spec rpm
  work="$(mktemp -d)"
  spec="${work}/${PKG_NAME}.spec"

  cat > "$spec" <<EOF
Name:           ${PKG_NAME}
Version:        ${PKG_VERSION}
Release:        ${PKG_REL}%{?dist}
Summary:        Persistent multi-session SSH auto-resume utility backed by tmux
License:        MIT
URL:            https://github.com/Bit-Loop/${PKG_NAME}
BuildArch:      noarch
Requires:       bash
Requires:       openssh-clients
Requires:       openssh-server
Requires:       tmux
Requires:       screen

%description
Opens a menu on interactive SSH login and resumes saved tmux sessions by
source IP. User choices are saved under ~/.config/ssh-multisession-resume.

%install
rm -rf %{buildroot}
bash %{_sourcedir}/packaging/payload.sh stage-package %{_sourcedir} %{buildroot} ${PKG_NAME} ${PKG_NAME}

%post
cat <<'POST'
$(postinstall_message)
POST

%files
/usr/bin/${PKG_NAME}
/usr/lib/${PKG_NAME}
/usr/share/${PKG_NAME}
/usr/share/doc/${PKG_NAME}
/usr/share/licenses/${PKG_NAME}
/etc/profile.d/${PKG_NAME}.sh
EOF

  rpmbuild -bb \
    --define "_topdir ${work}/rpmbuild" \
    --define "_sourcedir ${ROOT_DIR}" \
    "$spec"
  rpm="$(find "${work}/rpmbuild/RPMS/noarch" -name "${PKG_NAME}-${PKG_VERSION}-${PKG_REL}"'*.noarch.rpm' -print -quit)"
  [[ -n "$rpm" ]] || die "RPM artifact missing"
  cp "$rpm" "$OUT_DIR/"
  rm -rf "$work"
  echo "${OUT_DIR}/$(basename "$rpm")"
}

build_apk() {
  need_cmd abuild
  need_cmd abuild-keygen
  mkdir -p "$OUT_DIR"

  local work src_root apk_file apk_version
  apk_version="${SSH_MULTISESSION_APK_VERSION:-$PKG_VERSION}"
  if [[ "$apk_version" =~ ^(.+)\.r([0-9]+)\.g[0-9A-Za-z._+-]+$ ]]; then
    apk_version="${BASH_REMATCH[1]}_git${BASH_REMATCH[2]}"
  fi

  work="$(mktemp -d)"
  src_root="${work}/${PKG_NAME}-${apk_version}"
  mkdir -p "$src_root"
  tar -C "$ROOT_DIR" \
    --exclude='./.git' \
    --exclude='./.aur' \
    --exclude='./.agents' \
    --exclude='./.codex' \
    --exclude='./dist' \
    --exclude='./pkg' \
    --exclude='./src' \
    --exclude='./docker/output' \
    --exclude='./ssh-multisession-resume-source' \
    -cf - . | tar -C "$src_root" -xf -
  tar -C "$work" -czf "${work}/${PKG_NAME}-${apk_version}.tar.gz" "${PKG_NAME}-${apk_version}"
  rm -rf "$src_root"

  cat > "${work}/APKBUILD" <<EOF
# Maintainer: bit-loop <isaiah.fpga@gmail.com>
pkgname=${PKG_NAME}
pkgver=${apk_version}
pkgrel=${PKG_REL}
pkgdesc="Persistent multi-session SSH auto-resume utility backed by tmux"
url="https://github.com/Bit-Loop/${PKG_NAME}"
arch="noarch"
license="MIT"
depends="bash openssh-client openssh-server tmux screen"
source="${PKG_NAME}-${apk_version}.tar.gz"
builddir="\$srcdir/${PKG_NAME}-${apk_version}"
options="!check"

package() {
  bash "\$builddir/packaging/payload.sh" stage-package "\$builddir" "\$pkgdir" ${PKG_NAME} ${PKG_NAME}
}
EOF

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    mkdir -p /root/.abuild
    if [[ -z "$(find /root/.abuild -maxdepth 1 -name '*.rsa' -print -quit 2>/dev/null)" ]]; then
      abuild-keygen -a -n
      local apk_pubkey
      apk_pubkey="$(find /root/.abuild -maxdepth 1 -name '*.rsa.pub' -print -quit)"
      [[ -n "$apk_pubkey" ]] || die "APK signing public key missing"
      install -Dm644 "$apk_pubkey" "/etc/apk/keys/$(basename "$apk_pubkey")"
    fi
    (cd "$work" && abuild -F -s "$work" checksum && abuild -F -d -r -P "${work}/repo" -s "$work")
  else
    (cd "$work" && abuild -s "$work" checksum && abuild -d -r -P "${work}/repo" -s "$work")
  fi

  apk_file="$(find "${work}/repo" -type f -name "${PKG_NAME}-${apk_version}-r${PKG_REL}.apk" -print -quit)"
  [[ -n "$apk_file" ]] || die "APK artifact missing"
  cp "$apk_file" "$OUT_DIR/"
  rm -rf "$work"
  echo "${OUT_DIR}/$(basename "$apk_file")"
}

build_arch() {
  need_cmd makepkg
  mkdir -p "$OUT_DIR"

  local work src_name pkg_file runner
  work="$(mktemp -d)"
  src_name="${PKG_NAME}-source"
  mkdir -p "${work}/${src_name}"
  tar -C "$ROOT_DIR" \
    --exclude='./.git' \
    --exclude='./.aur' \
    --exclude='./.agents' \
    --exclude='./.codex' \
    --exclude='./dist' \
    --exclude='./pkg' \
    --exclude='./src' \
    --exclude='./docker/output' \
    --exclude='./ssh-multisession-resume-source' \
    -cf - . | tar -C "${work}/${src_name}" -xf -

  tar -C "$work" -czf "${work}/${src_name}.tar.gz" "$src_name"
  sed \
    -e 's|^source=.*|source=("${_srcname}.tar.gz")|' \
    -e "s|^sha256sums=.*|sha256sums=('SKIP')|" \
    "$ROOT_DIR/PKGBUILD" > "${work}/PKGBUILD"
  {
    printf '\n'
    printf 'pkgver() {\n'
    printf "  printf '%%s\\\\n' '%s'\n" "$PKG_VERSION"
    printf '}\n'
  } >> "${work}/PKGBUILD"
  runner=(makepkg --syncdeps --noconfirm --needed --force)
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    if ! id builder >/dev/null 2>&1; then
      useradd --create-home --shell /bin/bash builder
    fi
    printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
    chown -R builder:builder "$work"
    (cd "$work" && sudo -u builder "${runner[@]}")
  else
    (cd "$work" && "${runner[@]}")
  fi

  pkg_file="$(find "$work" -maxdepth 1 -name "${PKG_NAME}-git-*.pkg.tar.*" -print -quit)"
  [[ -n "$pkg_file" ]] || die "Arch package artifact missing"
  cp "$pkg_file" "$OUT_DIR/"
  rm -rf "$work"
  echo "${OUT_DIR}/$(basename "$pkg_file")"
}

build_all() {
  build_arch
  build_deb
  build_rpm
  build_apk
}

case "${1:-all}" in
  all) build_all ;;
  arch) build_arch ;;
  deb) build_deb ;;
  rpm) build_rpm ;;
  apk) build_apk ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
