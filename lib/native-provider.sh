#!/usr/bin/env bash

set -Eeuo pipefail

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

platform() {
  if [[ "$(uname -s)" == Darwin ]]; then printf homebrew; return; fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in debian|ubuntu) printf apt; return ;; arch) printf pacman; return ;; esac
  fi
  printf nixpkgs-only
}

validate_ids() {
  local id
  for id in "$@"; do
    [[ "$id" =~ ^[a-zA-Z0-9@+._-]+$ ]] || fail "unsafe or non-official package identifier: $id"
  done
}

validate_homebrew_official() {
  local metadata
  metadata="$(brew info --json=v2 -- "$@")" || fail "Homebrew could not resolve the requested official packages"
  jq -e '
    all(.formulae[]?; (.tap == "homebrew/core" or .tap == null)) and
    all(.casks[]?; (.tap == "homebrew/cask" or .tap == null))
  ' >/dev/null <<<"$metadata" || fail "third-party Homebrew taps are not supported"
}

validate_apt_official() {
  local sources
  sources="$(grep -RhsE '^[[:space:]]*(deb |URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)"
  if grep -Eo 'https?://[^ /]+' <<<"$sources" \
    | grep -Ev 'https?://(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|deb\.debian\.org|security\.debian\.org)(/|$)' \
    | grep -q .; then
    fail "third-party APT repositories are configured; the first native-provider release accepts official Debian/Ubuntu repositories only"
  fi
}

validate_pacman_official() {
  if sed -nE 's/^[[:space:]]*\[([^]]+)\].*/\1/p' /etc/pacman.conf 2>/dev/null \
    | grep -Ev '^(options|core|extra|multilib|(core|extra|multilib)-testing)$' | grep -q .; then
    fail "third-party Pacman repositories are configured; only official Arch repositories are supported"
  fi
}

inventory() {
  case "$(platform)" in
    homebrew)
      command -v brew >/dev/null 2>&1 || { printf '{"schemaVersion":1,"items":[]}\n'; return; }
      { brew list --formula --full-name 2>/dev/null || true; brew list --cask --full-name 2>/dev/null || true; } \
        | grep -Ev '/' \
        | sort -u | jq -Rsc '{schemaVersion: 1, items: (split("\n") | map(select(length > 0) |
          {id: ., name: ., installed: true, provider: "homebrew",
           repositoryTrust: "official Homebrew formulae/casks", publisherVerified: false}))}'
      ;;
    apt)
      validate_apt_official
      dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null \
        | jq -Rsc '{schemaVersion: 1, items: (split("\n") | map(select(length > 0) | split("\t") |
          {id: .[0], name: .[0], version: .[1], installed: true, provider: "apt",
           repositoryTrust: "configured official APT repositories", publisherVerified: false}))}'
      ;;
    pacman)
      validate_pacman_official
      pacman -Q 2>/dev/null | jq -Rsc '{schemaVersion: 1, items: (split("\n") | map(select(length > 0) | split(" ") |
        {id: .[0], name: .[0], version: .[1], installed: true, provider: "pacman",
         repositoryTrust: "official Arch repositories", publisherVerified: false}))}'
      ;;
    *) printf '{"schemaVersion":1,"items":[]}\n' ;;
  esac
}

search_packages() {
  local query="${1:-}"; [[ -n "$query" ]] || fail "search requires a query"
  case "$(platform)" in
    homebrew) brew search "$query" ;;
    apt) validate_apt_official; apt-cache search -- "$query" ;;
    pacman) validate_pacman_official; pacman -Ss -- "$query" ;;
    *) fail "this Linux distribution uses pinned Nixpkgs only" ;;
  esac
}

show_plan() {
  local action=""; [[ "${1:-}" == --action && $# -ge 3 ]] || fail "plan requires --action ACTION PACKAGE..."
  action="$2"; shift 2; validate_ids "$@"
  [[ "$(platform)" != apt ]] || validate_apt_official
  [[ "$(platform)" != pacman ]] || validate_pacman_official
  case "$(platform):$action" in
    homebrew:install) validate_homebrew_official "$@"; printf 'brew install -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    homebrew:remove) printf 'brew uninstall -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    homebrew:update) printf 'brew upgrade -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    apt:install) printf 'sudo apt-get install -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    apt:remove) printf 'sudo apt-get remove -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    apt:update) printf 'sudo apt-get install --only-upgrade -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    pacman:install|pacman:update) printf 'sudo pacman -S -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    pacman:remove) printf 'sudo pacman -R -- %q' "$1"; shift; printf ' %q' "$@"; printf '\n' ;;
    *) fail "native provider action is unsupported: $action" ;;
  esac
}

apply_plan() {
  local action=""; [[ "${1:-}" == --action && $# -ge 3 ]] || fail "apply requires --action ACTION PACKAGE..."
  action="$2"; shift 2; validate_ids "$@"
  [[ "$(platform)" != apt ]] || validate_apt_official
  [[ "$(platform)" != pacman ]] || validate_pacman_official
  case "$(platform):$action" in
    homebrew:install) validate_homebrew_official "$@"; brew install -- "$@" ;; homebrew:remove) brew uninstall -- "$@" ;; homebrew:update) brew upgrade -- "$@" ;;
    apt:install) sudo apt-get install -- "$@" ;; apt:remove) sudo apt-get remove -- "$@" ;;
    apt:update) sudo apt-get install --only-upgrade -- "$@" ;;
    pacman:install|pacman:update) sudo pacman -S -- "$@" ;; pacman:remove) sudo pacman -R -- "$@" ;;
    *) fail "native provider action is unsupported: $action" ;;
  esac
}

case "${1:-status}" in
  status) printf '%s\n' "$(platform)" ;;
  inventory) inventory ;;
  search) shift; search_packages "$@" ;;
  plan) shift; show_plan "$@" ;;
  apply) shift; apply_plan "$@" ;;
  *) fail "unsupported native-provider command: ${1:-}" ;;
esac
