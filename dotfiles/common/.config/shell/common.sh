# Shared POSIX-compatible interactive shell defaults. Keep secrets out of this file.
# Homebrew formulae are native packages, not Nix profile entries. Import
# Homebrew's official shell environment when it is present so their binaries
# are available consistently in Terminal, IDE, and Nix-launched shells.
HOME_WEAVE_BREW=""
if [ -x /opt/homebrew/bin/brew ]; then
  HOME_WEAVE_BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
  HOME_WEAVE_BREW=/usr/local/bin/brew
elif command -v brew >/dev/null 2>&1; then
  HOME_WEAVE_BREW="$(command -v brew)"
fi
if [ -n "$HOME_WEAVE_BREW" ]; then
  eval "$("$HOME_WEAVE_BREW" shellenv sh)"
fi
unset HOME_WEAVE_BREW

HOME_WEAVE_PROFILE_BIN="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave/bin"
case ":$PATH:" in
  *":$HOME_WEAVE_PROFILE_BIN:"*) ;;
  *) export PATH="$HOME_WEAVE_PROFILE_BIN:$PATH" ;;
esac
unset HOME_WEAVE_PROFILE_BIN
export EDITOR="nvim"
export VISUAL="nvim"

# Load NVM from the immutable HomeWeave profile when the optional NVM plugin
# is present. NVM_DIR remains writable so user-installed Node versions and
# aliases continue to live outside the Nix store.
HOME_WEAVE_NVM_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave/share/nvm"
if [ -s "$HOME_WEAVE_NVM_ROOT/nvm.sh" ]; then
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck source=/dev/null
  . "$HOME_WEAVE_NVM_ROOT/nvm.sh"
  if [ -n "${BASH_VERSION:-}" ] && [ -s "$HOME_WEAVE_NVM_ROOT/bash_completion" ]; then
    # shellcheck source=/dev/null
    . "$HOME_WEAVE_NVM_ROOT/bash_completion"
  fi
fi
unset HOME_WEAVE_NVM_ROOT

alias vim="nvim"

if command -v home-weave-env >/dev/null 2>&1; then
  if home_weave_environment="$(home-weave-env render posix \
    "$HOME/.home_weave_profile" "$HOME/.home_weave_secrets")"; then
    eval "$home_weave_environment"
  else
    printf 'HomeWeave environment was not loaded; review the error above.\n' >&2
  fi
  unset home_weave_environment
fi

# Downstream Stow repositories can add portable, non-secret extensions here.
for shell_config in "$HOME/.config/shell/conf.d/"*.sh; do
  if [ -r "$shell_config" ]; then
    # shellcheck source=/dev/null
    . "$shell_config"
  fi
done
unset shell_config
