#!/usr/bin/env bash

set -Eeuo pipefail

readonly NIX_VERSION="2.35.1"
readonly RELEASE_ROOT="https://releases.nixos.org/nix/nix-${NIX_VERSION}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "$(uname -m):$(uname -s)" in
  x86_64:Linux)
    system="x86_64-linux"
    expected_sha256="c3fe29778acaa93b5095ee66e36f11ec7c6a284c40970a24cc83ac4f04809db3"
    ;;
  aarch64:Linux|arm64:Linux)
    system="aarch64-linux"
    expected_sha256="79b739996f1751573b4d2b56e4ae607855184c711f2cc1274fa0952a13d4bfc9"
    ;;
  x86_64:Darwin)
    system="x86_64-darwin"
    expected_sha256="1a932047a6e563acbd86024599bb377cbceca4dc6934a49f62a41ea1d9bdcb1b"
    ;;
  arm64:Darwin|aarch64:Darwin)
    system="aarch64-darwin"
    expected_sha256="414e073c4754e0c9eed1dd25e482af45213a34aa67c930201e35df7c8333c19a"
    ;;
  *) fail "unsupported CI host: $(uname -m)-$(uname -s)" ;;
esac

if command -v nix >/dev/null 2>&1; then
  [[ "$(nix --version)" == "nix (Nix) ${NIX_VERSION}" ]] \
    || fail "CI requires Nix ${NIX_VERSION}; found $(nix --version)"
else
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  archive="$work_dir/nix.tar.xz"
  url="${RELEASE_ROOT}/nix-${NIX_VERSION}-${system}.tar.xz"

  curl --proto '=https' --tlsv1.2 --fail --location "$url" --output "$archive"
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  else
    actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
  fi
  [[ "$actual_sha256" == "$expected_sha256" ]] \
    || fail "checksum mismatch for $url"

  tar -xJf "$archive" -C "$work_dir"
  installer="$work_dir/nix-${NIX_VERSION}-${system}/install"
  [[ -x "$installer" ]] || fail "Nix installer is missing from the verified archive"

  if [[ "${HOME_WEAVE_CI_NIX_MODE:-daemon}" == "no-daemon" ]]; then
    "$installer" --no-daemon --yes --no-channel-add
  else
    "$installer" --daemon --yes --no-channel-add
  fi
fi

for environment in \
  /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
  "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
  if [[ -r "$environment" ]]; then
    # shellcheck disable=SC1090
    source "$environment"
    break
  fi
done

command -v nix >/dev/null 2>&1 || fail "Nix is unavailable after installation"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  dirname "$(command -v nix)" >>"$GITHUB_PATH"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'NIX_CONFIG=extra-experimental-features = nix-command flakes\n' >>"$GITHUB_ENV"
fi

nix --version
