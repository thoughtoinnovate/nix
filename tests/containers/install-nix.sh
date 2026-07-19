#!/usr/bin/env bash

set -Eeuo pipefail

NIX_VERSION=2.35.1
case "$(uname -m)" in
  x86_64)
    NIX_ARCH=x86_64
    NIX_SHA256=c3fe29778acaa93b5095ee66e36f11ec7c6a284c40970a24cc83ac4f04809db3
    ;;
  aarch64|arm64)
    NIX_ARCH=aarch64
    NIX_SHA256=79b739996f1751573b4d2b56e4ae607855184c711f2cc1274fa0952a13d4bfc9
    ;;
  *)
    printf 'error: unsupported Nix fixture architecture: %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

[[ "$(id -u)" -eq 0 ]] || {
  printf 'error: the container Nix installer must run as root\n' >&2
  exit 1
}

archive="nix-$NIX_VERSION-$NIX_ARCH-linux.tar.xz"
url="https://releases.nixos.org/nix/nix-$NIX_VERSION/$archive"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

curl --fail --show-error --silent --location "$url" --output "$temporary/$archive"
printf '%s  %s\n' "$NIX_SHA256" "$temporary/$archive" | sha256sum --check --status
tar --extract --xz --file "$temporary/$archive" --directory "$temporary"
cat >"$temporary/nix.conf" <<'EOF_CONFIG'
experimental-features = nix-command flakes
substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
require-sigs = true
sandbox = true
trusted-users = root homeweave
EOF_CONFIG

"$temporary/nix-$NIX_VERSION-$NIX_ARCH-linux/install" \
  --daemon \
  --yes \
  --no-channel-add \
  --no-modify-profile \
  --nix-extra-conf-file "$temporary/nix.conf"

/nix/var/nix/profiles/default/bin/nix --version \
  | grep -F "nix (Nix) $NIX_VERSION" >/dev/null
