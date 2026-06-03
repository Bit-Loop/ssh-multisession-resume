#!/usr/bin/env bash
set -euo pipefail

payload_install() {
  local mode="$1"
  local src="$2"
  local dest="$3"

  if [[ -n "${SSH_MULTISESSION_PAYLOAD_AS_ROOT:-}" ]]; then
    "$SSH_MULTISESSION_PAYLOAD_AS_ROOT" install -Dm"$mode" "$src" "$dest"
  else
    install -Dm"$mode" "$src" "$dest"
  fi
}

payload_library_files() {
  cat <<'EOF'
755 bin/ssh-multisession-resume ssh-multisession-resume
755 runtime/install.sh runtime/install.sh
644 runtime/auto-resume.sh runtime/auto-resume.sh
644 runtime/auto-screen.sh runtime/auto-screen.sh
644 runtime/profile-entry.sh runtime/profile-entry.sh
644 runtime/tmux-auto-resume.conf runtime/tmux-auto-resume.conf
644 runtime/screen-auto-resume.screenrc runtime/screen-auto-resume.screenrc
644 runtime/screen-hangup-off.screenrc runtime/screen-hangup-off.screenrc
755 sshd/match-install.sh sshd/match-install.sh
EOF
}

payload_install_library() {
  local source_root="$1"
  local lib_dir="$2"
  local mode src rel

  while read -r mode src rel; do
    payload_install "$mode" "${source_root}/${src}" "${lib_dir}/${rel}"
  done < <(payload_library_files)
}

payload_command_wrapper() {
  local command_name="$1"
  local target="$2"

  cat <<EOF
#!/usr/bin/env bash
export SSH_MULTISESSION_RESUME_COMMAND=${command_name}
exec "${target}" "\$@"
EOF
}

payload_stage_package() {
  local source_root="$1"
  local dest_root="$2"
  local pkg_name="${3:-ssh-multisession-resume}"
  local doc_name="${4:-$pkg_name}"
  local wrapper

  payload_install_library "$source_root" "${dest_root}/usr/lib/${pkg_name}"
  payload_install 755 "${source_root}/tests/smoke.sh" "${dest_root}/usr/share/${pkg_name}/tests/smoke.sh"
  payload_install 644 "${source_root}/runtime/profile-entry.sh" "${dest_root}/etc/profile.d/${pkg_name}.sh"
  payload_install 644 "${source_root}/README.md" "${dest_root}/usr/share/doc/${doc_name}/README.md"
  payload_install 644 "${source_root}/assets/capybara-terminal.png" "${dest_root}/usr/share/doc/${doc_name}/assets/capybara-terminal.png"
  payload_install 644 "${source_root}/CHANGELOG.md" "${dest_root}/usr/share/doc/${doc_name}/CHANGELOG.md"
  payload_install 644 "${source_root}/SECURITY.md" "${dest_root}/usr/share/doc/${doc_name}/SECURITY.md"
  payload_install 644 "${source_root}/LICENSE" "${dest_root}/usr/share/licenses/${doc_name}/LICENSE"

  wrapper="$(mktemp)"
  payload_command_wrapper "$pkg_name" "/usr/lib/${pkg_name}/${pkg_name}" > "$wrapper"
  payload_install 755 "$wrapper" "${dest_root}/usr/bin/${pkg_name}"
  rm -f "$wrapper"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    stage-package)
      shift
      payload_stage_package "$@"
      ;;
    library-files)
      payload_library_files
      ;;
    *)
      echo "Usage: packaging/payload.sh stage-package SOURCE_ROOT DEST_ROOT [PKG_NAME] [DOC_NAME]" >&2
      exit 2
      ;;
  esac
fi
