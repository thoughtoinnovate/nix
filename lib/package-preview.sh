#!/usr/bin/env bash

set -eu

row="${1:-}"
IFS=$'\t' read -r package version upstream maintainers official license description <<<"$row"

printf 'Package:         %s\n' "${package:-unknown}"
printf 'Version:         %s\n' "${version:-unknown}"
printf 'Upstream/author: %s\n' "${upstream:-not declared}"
printf 'Nix maintainers: %s\n' "${maintainers:-not declared}"
printf 'Official status: %s\n' "${official:-not verified}"
printf 'License:         %s\n' "${license:-unknown}"
printf '\n%s\n' "${description:-No description provided.}"
