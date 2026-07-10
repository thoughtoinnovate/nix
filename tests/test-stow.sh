#!/usr/bin/env bash

set -Eeuo pipefail

DOTFILES_DIR="${1:?usage: test-stow.sh PATH_TO_DOTFILES}"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
WORK_DOTFILES="$TEST_ROOT/work-dotfiles"
CONFLICT_DOTFILES="$TEST_ROOT/conflict-dotfiles"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" \
  "$WORK_DOTFILES/work/.config/shell/conf.d" \
  "$CONFLICT_DOTFILES/conflict"

stow --simulate --restow --no-folding --dir="$DOTFILES_DIR" --target="$TEST_HOME" \
  common starship zsh ghostty nvim
stow --restow --no-folding --dir="$DOTFILES_DIR" --target="$TEST_HOME" \
  common starship zsh ghostty nvim

[[ -L "$TEST_HOME/.zshrc" ]]
[[ -L "$TEST_HOME/.config/starship.toml" ]]
[[ -L "$TEST_HOME/.config/nvim/init.lua" ]]

printf 'export WORK_LAYER_LOADED=true\n' \
  >"$WORK_DOTFILES/work/.config/shell/conf.d/work.sh"
stow --simulate --restow --no-folding --dir="$WORK_DOTFILES" --target="$TEST_HOME" work
stow --restow --no-folding --dir="$WORK_DOTFILES" --target="$TEST_HOME" work
[[ -L "$TEST_HOME/.config/shell/conf.d/work.sh" ]]

printf 'conflict\n' >"$CONFLICT_DOTFILES/conflict/.zshrc"
if stow --simulate --restow --no-folding \
  --dir="$CONFLICT_DOTFILES" --target="$TEST_HOME" conflict 2>/dev/null; then
  printf 'expected Stow to reject a downstream path conflict\n' >&2
  exit 1
fi

printf 'Stow base, extension, rerun, and conflict tests passed.\n'
