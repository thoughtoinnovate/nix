# Shared POSIX-compatible interactive shell defaults. Keep secrets out of this file.
export EDITOR="nvim"
export VISUAL="nvim"

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
