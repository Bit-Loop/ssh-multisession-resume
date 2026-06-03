# shellcheck shell=sh
# Installed to /etc/profile.d/ssh-multisession-resume.sh by the AUR package.
# POSIX sh: this file is sourced by bash, zsh, dash, and sh login shells.
# Keep it cheap — it runs for every login shell on the system.

# Fast bail-out: only act on interactive SSH sessions that aren't already in a
# multiplexer.
[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ] || return 0
[ -z "${TMUX:-}${STY:-}" ] || return 0
[ -z "${SSH_ORIGINAL_COMMAND:-}" ] || return 0
case "${-:-}" in
  *i*) ;;
  *) return 0 ;;
esac
[ -t 0 ] && [ -t 1 ] || return 0

# Per-user opt-out: touch ~/.config/ssh-multisession-resume/opt-out to disable.
_ssh_multisession_resume_xdg="${XDG_CONFIG_HOME:-${HOME:-/}/.config}"
if [ -f "${_ssh_multisession_resume_xdg}/ssh-multisession-resume/opt-out" ]; then
  unset _ssh_multisession_resume_xdg
  return 0
fi
unset _ssh_multisession_resume_xdg

_ssh_multisession_resume_lib="${SSH_MULTISESSION_RESUME_LIB:-}"
if [ -z "${_ssh_multisession_resume_lib}" ]; then
  if [ -r "/usr/local/lib/ssh-multisession-resume/client/auto-resume.sh" ]; then
    _ssh_multisession_resume_lib="/usr/local/lib/ssh-multisession-resume"
  else
    _ssh_multisession_resume_lib="/usr/lib/ssh-multisession-resume"
  fi
fi
if [ ! -r "${_ssh_multisession_resume_lib}/client/auto-resume.sh" ]; then
  unset _ssh_multisession_resume_lib
  return 0
fi

SSH_AUTO_RESUME=1
SSH_AUTO_RESUME_TMUX_CONF="${_ssh_multisession_resume_lib}/client/tmux-auto-resume.conf"
SSH_AUTO_RESUME_SCREENRC="${_ssh_multisession_resume_lib}/client/screen-auto-resume.screenrc"
SSH_AUTO_RESUME_SESSION_PREFIX="ssh-resume"
export SSH_AUTO_RESUME SSH_AUTO_RESUME_TMUX_CONF SSH_AUTO_RESUME_SCREENRC SSH_AUTO_RESUME_SESSION_PREFIX

# shellcheck source=/dev/null
. "${_ssh_multisession_resume_lib}/client/auto-resume.sh"
unset _ssh_multisession_resume_lib
