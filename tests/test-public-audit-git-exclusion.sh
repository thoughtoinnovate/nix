#!/usr/bin/env bash

set -Eeuo pipefail

SANITIZER="${1:?usage: test-public-audit-git-exclusion.sh SANITIZER}"

fail() {
  printf 'public audit Git-exclusion test failed: %s\n' "$*" >&2
  exit 1
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

dotfiles="$fixture/dotfiles"
public_root="$fixture/public-root"
mkdir -p "$dotfiles" "$public_root/.git/logs" "$public_root/nested/.git/logs"

# Assemble the address so this regression test remains safe to scan itself.
synthetic_email="$(printf '%s%s%s' 'developer' '@internal' '.invalid')"
printf 'author %s\n' "$synthetic_email" >"$public_root/.git/logs/HEAD"
printf 'author %s\n' "$synthetic_email" >"$public_root/nested/.git/logs/HEAD"

bash "$SANITIZER" "$dotfiles" "$public_root" >/dev/null \
  || fail "repository-root or nested Git metadata was scanned"

printf 'contact %s\n' "$synthetic_email" >"$public_root/published.txt"
if bash "$SANITIZER" "$dotfiles" "$public_root" >"$fixture/rejected.log" 2>&1; then
  fail "non-example email outside Git metadata was accepted"
fi
grep -q 'non-example email address found' "$fixture/rejected.log" \
  || fail "published email was rejected for an unexpected reason"

printf 'Public audit excludes Git metadata and still scans published files.\n'
