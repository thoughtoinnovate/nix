if [ -r "$HOME/.config/shell/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.config/shell/common.sh"
fi

if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi

for bash_config in "$HOME/.config/bash/conf.d/"*.sh; do
  if [ -r "$bash_config" ]; then
    # shellcheck source=/dev/null
    . "$bash_config"
  fi
done
unset bash_config
