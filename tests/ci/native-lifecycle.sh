#!/usr/bin/env bash

set -Eeuo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(cd "$(mktemp -d)" && pwd -P)"
test_home="$test_root/home"
root="$test_home/.home-weave-native-ci"
cli="$test_root/home-weave-cli"
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$test_home"
export HOME="$test_home"
export USER="$(id -un)"
export LOGNAME="$USER"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
case "$(uname -s)" in
  Linux) export XDG_CONFIG_HOME="$HOME/.config" ;;
  Darwin) unset XDG_CONFIG_HOME ;;
  *) fail "unsupported native CI operating system: $(uname -s)" ;;
esac
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}accept-flake-config = true"

nix --accept-flake-config build "path:$repository#home-weave" \
  --out-link "$cli" --no-write-lock-file
HOME_WEAVE_BASE_URL="path:$repository" "$cli/bin/home-weave" \
  setup --root "$root" --profile base --shell bash,zsh,fish,nushell \
  --no-git --no-apply --yes

"$root/home-weave" config validate
"$root/home-weave" plan --profile base
"$root/home-weave" apply --profile base --yes

profile_bin="$XDG_STATE_HOME/nix/profiles/home-weave/bin"
[[ -x "$profile_bin/home-weave" ]] \
  || fail "activated package profile does not expose home-weave"
for executable in bash zsh fish nu; do
  [[ -x "$profile_bin/$executable" ]] \
    || fail "activated package profile does not expose $executable"
done
"$profile_bin/bash" --noprofile --norc -c 'exit 0'
"$profile_bin/zsh" -f -c 'exit 0'
"$profile_bin/fish" --no-config -c 'exit 0'
status="$("$profile_bin/home-weave" status --root "$root" --json)"
jq -e --arg profile "$XDG_STATE_HOME/nix/profiles/home-weave" '
  .schemaVersion == 2
  and .activeProfile == "base"
  and .packageProfile.backend == "nix-profile"
  and .packageProfile.profilePath == $profile
' >/dev/null <<<"$status" || fail "status did not report the dedicated package profile"

case "$(uname -s)" in
  Linux)
    nushell_root="$XDG_CONFIG_HOME/nushell"
    nushell_autoload_root="$XDG_DATA_HOME/nushell/vendor/autoload"
    [[ ! -e "$HOME/Library/Application Support/nushell" ]] \
      || fail "Linux activation created the native macOS Nushell destination"
    ;;
  Darwin)
    nushell_root="$HOME/Library/Application Support/nushell"
    nushell_autoload_root="$nushell_root/vendor/autoload"
    [[ ! -e "$HOME/.config/nushell/config.nu" ]] \
      || fail "Darwin activation retained the Linux Nushell destination"
    ;;
  *) fail "unsupported native CI operating system: $(uname -s)" ;;
esac

[[ -L "$nushell_root/config.nu" ]] || fail "Nushell config is not a managed link"
link_target="$(readlink "$nushell_root/config.nu")"
if [[ "$link_target" == /* ]]; then
  resolved_config="$link_target"
else
  resolved_config="$(cd "$nushell_root/$(dirname "$link_target")" && pwd -P)/$(basename "$link_target")"
fi
case "$resolved_config" in
  "$root/.state/dotfiles/current/"*) ;;
  *) fail "Nushell config has an unexpected owner" ;;
esac
[[ -s "$nushell_autoload_root/starship.nu" ]] \
  || fail "Nushell Starship autoload was not generated"
unset STARSHIP_SHELL PROMPT_COMMAND || true
"$profile_bin/nu" -c "
  \$env.CMD_DURATION_MS = '0823'
  \$env.LAST_EXIT_CODE = 0
  source '$nushell_autoload_root/starship.nu'
  if (\$env.STARSHIP_SHELL? | default '') != 'nu' { exit 23 }
  do \$env.PROMPT_COMMAND | ignore
"

"$root/home-weave" uninstall --all --yes
[[ ! -e "$XDG_STATE_HOME/nix/profiles/home-weave" ]] \
  || fail "receipt-owned package profile remains after uninstall"
[[ ! -e "$nushell_root/config.nu" && ! -L "$nushell_root/config.nu" ]] \
  || fail "managed Nushell config remains after uninstall"
[[ -d "$root" ]] || fail "normal uninstall removed the reusable profile repository"

printf 'HomeWeave native lifecycle passed: %s\n' \
  "$(nix eval --no-write-lock-file --impure --raw --expr builtins.currentSystem)"
