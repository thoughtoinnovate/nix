# Shared POSIX-compatible interactive shell defaults. Keep secrets out of this file.
export EDITOR="nvim"
export VISUAL="nvim"

alias vim="nvim"

# Downstream Stow repositories can add portable, non-secret extensions here.
for shell_config in "$HOME/.config/shell/conf.d/"*.sh; do
  if [ -r "$shell_config" ]; then
    # shellcheck source=/dev/null
    . "$shell_config"
  fi
done
unset shell_config
