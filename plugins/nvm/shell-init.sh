# HomeWeave NVM activation for upstream-supported POSIX shells.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
HOME_WEAVE_NVM_ROOT="${HOME_WEAVE_NVM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave/share/nvm}"

if [ -s "$HOME_WEAVE_NVM_ROOT/nvm.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME_WEAVE_NVM_ROOT/nvm.sh"
fi

if [ -n "${BASH_VERSION:-}" ] && [ -s "$HOME_WEAVE_NVM_ROOT/bash_completion" ]; then
  # shellcheck source=/dev/null
  . "$HOME_WEAVE_NVM_ROOT/bash_completion"
fi

unset HOME_WEAVE_NVM_ROOT
