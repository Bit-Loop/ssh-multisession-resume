# Legacy compatibility shim.
# Older installed profile blocks source this file. Keep it redirecting to the
# persistent auto-resume helper so users do not stay on kill-on-disconnect
# behavior before reinstalling the hook.

_ssh_auto_screen_compat_main() {
  _ssh_auto_screen_dir=""

  if [ -n "${SCREEN_KILL_SCREENRC:-}" ]; then
    _ssh_auto_screen_dir="$(dirname "$SCREEN_KILL_SCREENRC")"
  elif [ -n "${BASH_SOURCE:-}" ]; then
    _ssh_auto_screen_dir="$(CDPATH= cd -- "$(dirname -- "$BASH_SOURCE")" && pwd -P)"
  fi

  [ -n "$_ssh_auto_screen_dir" ] || return 0

  SSH_AUTO_RESUME_TMUX_CONF="${SSH_AUTO_RESUME_TMUX_CONF:-${_ssh_auto_screen_dir}/tmux-auto-resume.conf}"
  SSH_AUTO_RESUME_SCREENRC="${SSH_AUTO_RESUME_SCREENRC:-${_ssh_auto_screen_dir}/screen-auto-resume.screenrc}"
  SSH_AUTO_RESUME_SESSION_PREFIX="${SSH_AUTO_RESUME_SESSION_PREFIX:-ssh-resume}"

  if [ -r "${_ssh_auto_screen_dir}/auto-resume.sh" ]; then
    . "${_ssh_auto_screen_dir}/auto-resume.sh"
  fi
}

_ssh_auto_screen_compat_main
unset -f _ssh_auto_screen_compat_main 2>/dev/null || true
