#!/usr/bin/env bash

set -Eeuo pipefail

installer="$1"
flake="${2:-}"

if [[ -n "$flake" ]]; then
  grep -Fq 'export HOME_WEAVE_PREFLIGHT_REPORTER=' "$flake" || {
    printf 'packaged setup app does not provide its pinned preflight reporter\n' >&2
    exit 1
  }
fi

grep -Fq 'CONFIG_FLAKE="path:$CONFIG_DIR"' "$installer" || {
  printf 'generated flake is not forced to an explicit path reference\n' >&2
  exit 1
}
grep -Fq 'flake update --flake "$CONFIG_FLAKE"' "$installer" || {
  printf 'generated flake lock is not recreated from the current explicit path reference\n' >&2
  exit 1
}
if grep -Eq '\$CONFIG_DIR#|flake lock "\$CONFIG_DIR"|switch --flake "\$CONFIG_DIR' "$installer"; then
  printf 'a generated flake invocation still uses the Git-filtered directory reference\n' >&2
  exit 1
fi
grep -Fq "'.localBuilds | length'" "$installer" || {
  printf 'cached preflight local-build count is not derived safely from JSON\n' >&2
  exit 1
}
grep -Fq "'.substitutions | length'" "$installer" || {
  printf 'cached preflight substitution count is not derived safely from JSON\n' >&2
  exit 1
}
grep -Fq 'declaredPackageNames = builtins.fromJSON' "$installer" || {
  printf 'inventory does not use the resolved package declaration\n' >&2
  exit 1
}
grep -Fq 'packageOrigins = builtins.fromJSON' "$installer" || {
  printf 'inventory does not preserve resolved package origins\n' >&2
  exit 1
}
grep -Fq 'nix-base.lib.homeWeave.sourcesBySystem.\${system}' "$installer" || {
  printf 'generated activation does not use the stable distribution source API\n' >&2
  exit 1
}
if grep -Eq 'nix-base\.inputs\.(home-manager|home-manager-x86-darwin)' "$installer"; then
  printf 'generated activation assumes Home Manager is a direct parent input\n' >&2
  exit 1
fi
grep -Fq 'inherit (details) group inheritedFrom sourceProfile origins' "$installer" || {
  printf 'inventory omits resolved inheritance metadata\n' >&2
  exit 1
}
grep -Fq 'last-inventory.json' "$installer" || {
  printf 'preflight does not persist receipt inventory before activation\n' >&2
  exit 1
}

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
