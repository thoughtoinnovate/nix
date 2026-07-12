#!/usr/bin/env bash

set -Eeuo pipefail

installer="$1"
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
