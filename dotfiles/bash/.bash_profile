# Login Bash sessions also load the interactive Bash configuration.
if [ -r "$HOME/.bashrc" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.bashrc"
fi

