#!/usr/bin/env bash

set -Eeuo pipefail

installer="$1"

grep -Fq 'CONFIG_FLAKE="path:$CONFIG_DIR"' "$installer" || {
  printf 'generated flake is not forced to an explicit path reference\n' >&2
  exit 1
}
grep -Fq 'flake lock "$CONFIG_FLAKE"' "$installer" || {
  printf 'generated flake lock does not use the explicit path reference\n' >&2
  exit 1
}
if grep -Eq '\$CONFIG_DIR#|flake lock "\$CONFIG_DIR"|switch --flake "\$CONFIG_DIR' "$installer"; then
  printf 'a generated flake invocation still uses the Git-filtered directory reference\n' >&2
  exit 1
fi

function_body="$(sed -n '/^install_macos_apps() {/,/^}/p' "$installer")"
[[ -n "$function_body" ]] || {
  printf 'install_macos_apps function was not found\n' >&2
  exit 1
}
eval "$function_body"

OS=darwin
PROFILE_CASKS=""
install_macos_apps

OS=linux
PROFILE_CASKS="codex"
install_macos_apps

printf 'No-cask activation tests passed.\n'
