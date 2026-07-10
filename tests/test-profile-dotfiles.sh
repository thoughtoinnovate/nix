#!/usr/bin/env bash

set -Eeuo pipefail

BASE_DOTFILES="${1:?usage: test-profile-dotfiles.sh BASE_DOTFILES}"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
STOW_ROOT="$TEST_ROOT/generated"
CURRENT="$STOW_ROOT/current"
CUSTOM="$TEST_ROOT/custom"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$CURRENT" "$CUSTOM/custom/.config/shell/conf.d"

for package in common starship zsh ghostty nvim; do
  cp -a "$BASE_DOTFILES/$package/." "$CURRENT/"
done

printf '# profile override\n' >"$CUSTOM/custom/.zshrc"
printf 'export PROFILE_LAYER=true\n' \
  >"$CUSTOM/custom/.config/shell/conf.d/profile.sh"
cp -a "$CUSTOM/custom/." "$CURRENT/"

grep -Fq 'profile override' "$CURRENT/.zshrc"
[[ -f "$CURRENT/.config/starship.toml" ]]
[[ -f "$CURRENT/.config/shell/conf.d/profile.sh" ]]

stow --simulate --restow --no-folding --dir="$STOW_ROOT" --target="$TEST_HOME" current
stow --restow --no-folding --dir="$STOW_ROOT" --target="$TEST_HOME" current
grep -Fq 'profile override' "$TEST_HOME/.zshrc"

stow --delete --no-folding --dir="$STOW_ROOT" --target="$TEST_HOME" current
rm "$CURRENT/.config/shell/conf.d/profile.sh"
stow --restow --no-folding --dir="$STOW_ROOT" --target="$TEST_HOME" current
[[ ! -e "$TEST_HOME/.config/shell/conf.d/profile.sh" ]]

printf 'Profile merge, override, and stale-link tests passed.\n'
