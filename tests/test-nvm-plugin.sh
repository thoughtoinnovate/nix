#!/usr/bin/env bash
set -Eeuo pipefail

hook="$1"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/home" "$temporary/profile/share/nvm"
printf '%s\n' 'nvm() { printf "nvm-ready\\n"; }' >"$temporary/profile/share/nvm/nvm.sh"

for shell in bash zsh; do
  HOME="$temporary/home" HOME_WEAVE_NVM_ROOT="$temporary/profile/share/nvm" env -u NVM_DIR "$shell" -c \
    '. "$1"; command -V nvm >/dev/null; test "$(nvm)" = nvm-ready; test "$NVM_DIR" = "$HOME/.nvm"' \
    home-weave-nvm "$hook"
done
