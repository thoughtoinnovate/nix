#!/usr/bin/env bash
set -Eeuo pipefail

quickstart="$1"
readme="$2"
template_readme="$3"
inherited_flake="$4"
nvm_descriptor="$5"

grep -Fq "DIST='github:thoughtoinnovate/nix'" "$quickstart"
grep -Fq "run \"\${DIST}#home-weave\" --" "$quickstart"
grep -Fq 'setup --root "$HOME/.home-weave" --profile development --no-apply' "$quickstart"
grep -Fq "DIST='git+ssh://git@example.org/team/home-weave-distribution.git?ref=main'" "$quickstart"
grep -Fq 'Private SSH distributions require' "$quickstart"
grep -Fq './home-weave apply --yes' "$quickstart"
grep -Fq 'home-weave nuke-all --dry-run' "$template_readme"

grep -Fq 'packageDefinitions = ./packages.json;' "$inherited_flake"
grep -Fq 'localOverlays = [ (import ./overlay.nix) ];' "$inherited_flake"
grep -Fq '`packages.json` defines checksum-pinned local packages' "$template_readme"
grep -Fq '`overlay.nix` contains local Nix overrides' "$template_readme"
grep -Fq '`dotfiles/custom/` contains only local' "$template_readme"
grep -Fq 'Nix downloads the parent distribution automatically' "$template_readme"
grep -Fq 'Omitting `shells`' "$template_readme"
grep -Fq './home-weave profile create new-tooling --extends @PROFILE@' "$template_readme"
grep -Fq './home-weave profile diff new-tooling' "$template_readme"
grep -Fq '"nix": ["jq-homeweave"]' "$template_readme"
grep -Fq 'jq-homeweave = prev.jq.overrideAttrs' "$template_readme"
grep -Fq 'explicit exclusion makes the effective package change visible' "$template_readme"

grep -Fq 'lifecycle = { packages = "remove"; state = "retain"; };' "$nvm_descriptor"
grep -Fq 'statePaths = [ ];' "$nvm_descriptor"
grep -Fq 'retains user-installed Node versions and aliases' "$quickstart"
grep -Fq 'retains' "$readme"

if grep -Eq '(^|[^[:alnum:]-])apply-yes([^[:alnum:]-]|$)' \
  "$quickstart" "$readme" "$template_readme"; then
  printf 'documentation advertises the unsupported apply-yes alias\n' >&2
  exit 1
fi
