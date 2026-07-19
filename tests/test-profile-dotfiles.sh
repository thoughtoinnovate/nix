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
printf 'child override\n' >"$COMPONENTS/custom/.config/starship.toml"
touch "$COMPONENTS/custom/.gitkeep"

run_composer() {
  HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
    bash "$COMPOSER" --system "${3:-x86_64-linux}" --shell "${1:-zsh}" --shells "${2:-${1:-zsh}}" \
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
grep -Fq 'nix/profiles/home-weave/bin' "$TEST_HOME/.config/shell/common.sh"
grep -Fq 'nix/profiles/home-weave/share/nvm' "$TEST_HOME/.config/shell/common.sh"

grep -Fq 'nix/profiles/home-weave/bin' "$TEST_HOME/.config/fish/config.fish"
[[ -L "$TEST_HOME/.zshrc" ]]
[[ -L "$TEST_HOME/.config/fish/config.fish" ]]
[[ -L "$TEST_HOME/.config/nvim/init.lua" ]]
[[ -L "$TEST_HOME/.config/starship.toml" ]]
grep -Fqx 'child override' "$TEST_HOME/.config/starship.toml"
grep -Fqx organization "$TEST_HOME/.config/example-org/settings.conf"
grep -Fqx personal "$TEST_HOME/.config/personal/config"

# Nushell sources remain canonical in every repository. Composition maps the
# complete merged directory only on Darwin and generates Starship before Stow,
# making it available to Nushell on its first launch.
write_layers
run_composer nushell nushell x86_64-linux
grep -Fq 'home_weave_profile_bin' "$TEST_HOME/.config/nushell/env.nu"
[[ -L "$TEST_HOME/.config/nushell/config.nu" ]]
[[ -s "$TEST_HOME/.local/share/nushell/vendor/autoload/starship.nu" ]]
[[ -s "$TEST_HOME/.local/share/nushell/vendor/autoload/home-weave-env.nu" ]]
[[ ! -e "$TEST_HOME/.config/nushell/vendor/autoload" ]]
[[ ! -e "$TEST_HOME/Library/Application Support/nushell" ]]
run_composer nushell nushell aarch64-darwin
[[ -L "$TEST_HOME/Library/Application Support/nushell/config.nu" ]]
[[ -s "$TEST_HOME/Library/Application Support/nushell/vendor/autoload/starship.nu" ]]
[[ ! -e "$TEST_HOME/.config/nushell/config.nu" ]]

# A layer may not supply both repository-canonical and native Darwin trees.
mkdir -p "$COMPONENTS/native/Library/Application Support/nushell"
printf 'conflict\n' >"$COMPONENTS/native/Library/Application Support/nushell/config.nu"
jq --arg components "$COMPONENTS" \
  '.layers += [{name: "native", source: {kind: "path", path: $components}, packages: ["native"]}]' \
  "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'Nushell destination conflict' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system aarch64-darwin --shell nushell --namespace home-weave --json "$JSON_FILE.invalid"

# Failed generation is transactional: the live Starship initialization stays
# byte-for-byte unchanged.
starship_before="$(<"$TEST_HOME/Library/Application Support/nushell/vendor/autoload/starship.nu")"
FAKE_BIN="$TEST_ROOT/failing-bin"
mkdir -p "$FAKE_BIN"
printf '#!%s\nexit 23\n' "$(command -v bash)" >"$FAKE_BIN/starship"
chmod +x "$FAKE_BIN/starship"
expect_failure 'Starship integration failed' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  PATH="$FAKE_BIN:$PATH" bash "$COMPOSER" --system aarch64-darwin --shell nushell \
    --namespace home-weave --json "$JSON_FILE"
[[ "$(<"$TEST_HOME/Library/Application Support/nushell/vendor/autoload/starship.nu")" == "$starship_before" ]]
[[ ! -e "$TEST_HOME/.gitkeep" ]]

# Interactive setup exclusions are machine-specific. The composer must remove
# a skipped file while allowing non-conflicting child-layer files under the
# same existing directory, then restore the skipped managed file when the
# exclusion is absent.
SKIPPED_FILE="$TEST_ROOT/skipped-dotfiles"
mkdir -p "$TEST_HOME/.config/personal"
rm "$TEST_HOME/.config/personal/config"
printf 'local retained\n' >"$TEST_HOME/.config/personal/config"
printf '.config/personal\n' >"$SKIPPED_FILE"
mkdir -p "$COMPONENTS/custom/.config/personal/extensions"
printf 'managed extension\n' >"$COMPONENTS/custom/.config/personal/extensions/child.conf"
HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  HOME_WEAVE_SKIPPED_DOTFILES_FILE="$SKIPPED_FILE" \
  bash "$COMPOSER" --shell zsh --shells zsh,fish \
    --system x86_64-linux --namespace home-weave --json "$JSON_FILE"
grep -Fqx 'local retained' "$TEST_HOME/.config/personal/config"
grep -Fqx 'managed extension' "$TEST_HOME/.config/personal/extensions/child.conf"
[[ -e "$TEST_HOME/.config/starship.toml" ]]
rm -rf "$TEST_HOME/.config/personal"
run_composer zsh zsh,fish
grep -Fqx personal "$TEST_HOME/.config/personal/config"
grep -Fqx 'managed extension' "$TEST_HOME/.config/personal/extensions/child.conf"

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
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE"
[[ -e "$STALE_HOME/.config/starship.toml" ]]

# A dangling exact link from a deleted previous HomeWeave root can be safely
# transferred to a new root. A live link owned by another root remains a hard
# conflict so two active roots cannot silently take over one another.
TRANSFER_HOME="$TEST_ROOT/transfer-home"
TRANSFER_DATA="$TEST_ROOT/transfer-data"
OLD_CURRENT="$TRANSFER_HOME/.home-weave-old/.state/dotfiles/current"
mkdir -p "$TRANSFER_HOME/.config"
ln -s "$OLD_CURRENT/.config/starship.toml" "$TRANSFER_HOME/.config/starship.toml"
HOME="$TRANSFER_HOME" XDG_DATA_HOME="$TRANSFER_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE"
[[ -e "$TRANSFER_HOME/.config/starship.toml" ]]
[[ "$(readlink "$TRANSFER_HOME/.config/starship.toml")" != *'.home-weave-old/'* ]]

LIVE_HOME="$TEST_ROOT/live-owner-home"
LIVE_DATA="$TEST_ROOT/live-owner-data"
LIVE_CURRENT="$LIVE_HOME/.home-weave-live/.state/dotfiles/current"
mkdir -p "$LIVE_HOME/.config" "$LIVE_CURRENT/.config"
printf 'live owner\n' >"$LIVE_CURRENT/.config/starship.toml"
ln -s "$LIVE_CURRENT/.config/starship.toml" "$LIVE_HOME/.config/starship.toml"
expect_failure 'destination conflict' env HOME="$LIVE_HOME" XDG_DATA_HOME="$LIVE_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE"
grep -Fqx 'live owner' "$LIVE_HOME/.config/starship.toml"

# The schema is a clean break: entries, string sources, Git sources, traversal,
# and missing components are rejected instead of being adapted.
jq '.layers[0].entries = [{from: "common", to: ".", mode: "merge"}]' \
  "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'invalid dotfile component schema' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].source = .layers[0].source.path' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'invalid dotfile component schema' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].source.kind = "git"' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'invalid dotfile component schema' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].packages = ["../escape"]' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'may not contain traversal' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
jq '.layers[0].packages = ["missing"]' "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'package is missing' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"

# Existing unmanaged destinations are rejected without replacing the current generation.
printf 'unmanaged\n' >"$TEST_HOME/.config/new-conflict"
mkdir -p "$COMPONENTS/conflict/.config"
printf 'managed\n' >"$COMPONENTS/conflict/.config/new-conflict"
jq --arg components "$COMPONENTS" '.layers += [{name: "conflict", source: {kind: "path", path: $components}, packages: ["conflict"]}]' \
  "$JSON_FILE" >"$JSON_FILE.invalid"
expect_failure 'destination conflict' env HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
  bash "$COMPOSER" --system x86_64-linux --shell zsh --namespace home-weave --json "$JSON_FILE.invalid"
grep -Fqx unmanaged "$TEST_HOME/.config/new-conflict"

printf 'Native Stow component tests passed.\n'
