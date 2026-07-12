#!/usr/bin/env bash

set -eu

row="${1:-}"
IFS=$'\t' read -r _display package version upstream maintainers distribution verification official license description publisher publisher_evidence <<<"$row"

green='\033[32m'
red='\033[31m'
yellow='\033[33m'
reset='\033[0m'

case "$verification" in
  verified) verification_label="${green}🟢 ${publisher:-Upstream} verified${reset}" ;;
  *) verification_label="${red}🔴 Unverified publisher${reset}" ;;
esac

case "$official" in
  true) official_label="${green}🏢 Official package${reset}" ;;
  false) official_label="${red}🚫 Unofficial package${reset}" ;;
  *) official_label="${yellow}❓ Official status unknown${reset}" ;;
esac

case "$distribution" in
  community) distribution_label='🧩 Nixpkgs community package' ;;
  *) distribution_label="$distribution" ;;
esac

printf 'Package:         %s\n' "${package:-unknown}"
printf 'Version:         %s\n' "${version:-unknown}"
printf 'Upstream/author: %s\n' "${upstream:-not declared}"
printf 'Nix maintainers: %s\n' "${maintainers:-not declared}"
printf 'Package type:    %s\n' "$distribution_label"
printf 'Publisher:       %b\n' "$verification_label"
if [[ -n "${publisher_evidence:-}" ]]; then
  printf 'Evidence:        %s\n' "$publisher_evidence"
fi
printf 'Official status: %b\n' "$official_label"
printf 'License:         %s\n' "${license:-unknown}"
printf '\n%s\n' "${description:-No description provided.}"
