#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  plan|apply|restore|sync|update|profile|status|logs|uninstall|provider|extension|help)
    [[ -f "$ROOT/home-weave" ]] || {
      printf 'error: repository launcher is missing: %s/home-weave\n' "$ROOT" >&2
      exit 1
    }
    exec bash "$ROOT/home-weave" "$@"
    ;;
esac

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
UPDATE_INPUTS=false
SETUP_ARGS=()

for argument in "$@"; do
  if [[ "$argument" == "--update" ]]; then
    UPDATE_INPUTS=true
  else
    SETUP_ARGS+=("$argument")
  fi
done

load_nix_environment() {
  local candidate
  for candidate in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    if [[ -r "$candidate" ]]; then
      # shellcheck disable=SC1090
      source "$candidate"
      break
    fi
  done
}

if ! command -v nix >/dev/null 2>&1; then
  load_nix_environment
fi

if ! command -v nix >/dev/null 2>&1; then
  command -v curl >/dev/null 2>&1 || {
    printf 'error: curl is required to install Nix\n' >&2
    exit 1
  }
  printf 'Nix is missing. Run the official installer from nixos.org? [y/N] '
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || exit 1
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  curl --proto '=https' --tlsv1.2 --fail --location \
    https://nixos.org/nix/install --output "$installer"
  sh "$installer"
  load_nix_environment
fi

command -v nix >/dev/null 2>&1 || {
  printf 'error: open a new terminal and rerun setup.sh\n' >&2
  exit 1
}

if "$UPDATE_INPUTS"; then
  nix "${NIX_FLAGS[@]}" flake update --flake "path:$ROOT"
  printf 'Updated profile inputs. Review and commit %s/flake.lock.\n' "$ROOT"
fi

exec nix "${NIX_FLAGS[@]}" run "path:$ROOT#setup" -- \
  --config-url "path:$ROOT" "${SETUP_ARGS[@]}"
