#!/usr/bin/env bash

set -Eeuo pipefail

provider="${1:?native provider script is required}"

function_body="$(sed -n '/^print_quoted_arguments() {$/,/^}$/p' "$provider")"
[[ -n "$function_body" ]] || {
  printf 'native provider argument renderer is missing\n' >&2
  exit 1
}
eval "$function_body"

single="$(
  printf 'sudo apt-get install -- jq'
  print_quoted_arguments
)"
[[ "$single" == 'sudo apt-get install -- jq' ]] || {
  printf 'zero trailing arguments rendered an empty package: %s\n' "$single" >&2
  exit 1
}

multiple="$(
  printf 'sudo pacman -S -- jq'
  print_quoted_arguments curl git
)"
[[ "$multiple" == 'sudo pacman -S -- jq curl git' ]] || {
  printf 'multiple trailing arguments rendered incorrectly: %s\n' "$multiple" >&2
  exit 1
}

printf 'Native provider command argument rendering passed.\n'
