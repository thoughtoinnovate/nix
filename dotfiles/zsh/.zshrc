if [[ -r "$HOME/.config/shell/common.sh" ]]; then
  source "$HOME/.config/shell/common.sh"
fi

if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

for zsh_config in "$HOME/.config/zsh/conf.d/"*.zsh(N); do
  source "$zsh_config"
done
unset zsh_config
