#!/usr/bin/env bash

set -Eeuo pipefail

BASE_DOTFILES="${1:?usage: test-profile-dotfiles.sh BASE_DOTFILES [COMPOSER]}"
COMPOSER="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/compose-dotfiles.sh}"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
TEST_DATA="$TEST_ROOT/data"
COMPONENTS="$TEST_ROOT/components"
JSON_FILE="$TEST_ROOT/layers.json"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_HOME" "$COMPONENTS/organization/.config/example-org" "$COMPONENTS/custom/.config/personal"
printf 'organization\n' >"$COMPONENTS/organization/.config/example-org/settings.conf"
printf 'personal\n' >"$COMPONENTS/custom/.config/personal/config"
touch "$COMPONENTS/custom/.gitkeep"

run_composer() {
  HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
    bash "$COMPOSER" --shell "${1:-zsh}" --shells "${2:-${1:-zsh}}" \
      --namespace home-weave --json "$JSON_FILE"
}

expect_failure() {
  local expected="$1"
  shift
  if output="$("$@" 2>&1)"; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  grep -Eq "$expected" <<<"$output" || {
    printf 'failure did not contain %q:\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

write_layers() {
  jq -n --arg base "$BASE_DOTFILES" --arg extensions "$COMPONENTS" '{layers: [
    {name: "core", source: {kind: "path", path: $base},
      packages: ["common", "starship", "ghostty", "nvim", "@shells"]},
    {name: "organization", source: {kind: "path", path: $extensions}, packages: ["organization"]},
    {name: "personal", source: {kind: "path", path: $extensions}, packages: ["custom"]}
  ]}' >"$JSON_FILE"
}

write_layers
run_composer zsh zsh,fish
[[ -L "$TEST_HOME/.zshrc" ]]
[[ -L "$TEST_HOME/.config/fish/config.fish" ]]
[[ -L "$TEST_HOME/.config/nvim/init.lua" ]]
[[ -L "$TEST_HOME/.config/starship.toml" ]]
grep -Fqx organization "$TEST_HOME/.config/example-org/settings.conf"
grep -Fqx personal "$TEST_HOME/.config/personal/config"
[[ ! -e "$TEST_HOME/.gitkeep" ]]

# Removing a selected component removes only its stale managed links.
jq 'del(.layers[2])' "$JSON_FILE" >"$JSON_FILE.next"
mv "$JSON_FILE.next" "$JSON_FILE"
run_composer zsh zsh,fish
[[ ! -e "$TEST_HOME/.config/personal/config" ]]
[[ -e "$TEST_HOME/.config/example-org/settings.conf" ]]

# Exact links into a deleted HomeWeave generation are safely reclaimed.
STALE_HOME="$TEST_ROOT/stale-home"
STALE_DATA="$TEST_ROOT/stale-data"
STALE_CURRENT="$STALE_DATA/home-weave/dotfiles/current"
mkdir -p "$STALE_HOME/.config"
ln -s "$STALE_CURRENT/.config/starship.toml" "$STALE_HOME/.config/starship.toml"
HOME="$STALE_HOME" XDG_DATA_HOME="$STALE_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE"
[[ -e "$STALE_HOME/.config/starship.toml" ]]

# The schema is a clean break: entries, string sources, Git sources, traversal,
# and missing components are rejected instead of being adapted.
jq '.layers[0].entries = [{from: "common", to: ".", mode: "merge"}]' \
  "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'invalid dotfile component schema' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].source = .layers[0].source.path' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'invalid dotfile component schema' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].source.kind = "git"' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'invalid dotfile component schema' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].packages = ["../escape"]' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'may not contain traversal' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].packages = ["missing"]' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'package is missing' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"

# Existing unmanaged destinations are rejected without replacing the current generation.
printf 'unmanaged\n' >"$TEST_HOME/.config/new-conflict"
mkdir -p "$COMPONENTS/conflict/.config"
printf 'managed\n' >"$COMPONENTS/conflict/.config/new-conflict"
jq --arg components "$COMPONENTS" '.layers += [{name: "conflict", source: {kind: "path", path: $components}, packages: ["conflict"]}]' \
  "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'destination conflict' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
grep -Fqx unmanaged "$TEST_HOME/.config/new-conflict"

printf 'Native Stow component tests passed.\n'
