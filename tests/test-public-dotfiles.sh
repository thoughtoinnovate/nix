#!/usr/bin/env bash

set -Eeuo pipefail

DOTFILES="${1:?usage: test-public-dotfiles.sh PATH_TO_BUNDLED_DOTFILES}"

fail() {
  printf 'public dotfile sanitization failed: %s\n' "$*" >&2
  exit 1
}

[[ -d "$DOTFILES" ]] || fail "missing dotfile directory: $DOTFILES"

if find "$DOTFILES" -type f \( \
  -name '.env' -o -name '.env.local' -o -name '*.pem' -o -name '*.key' \
  -o -name '*.p12' -o -name '*.pfx' -o -name 'credentials' \
  -o -name 'connections.toml' \
\) -print -quit | grep -q .; then
  fail "credential-like file found"
fi

if rg -n -i '/Users/|/home/|/Volumes/|computername|machine[-_ ]?name|(^|[[:space:]])(user(name)?|hostname)[[:space:]]*=' "$DOTFILES"; then
  fail "personal identity, hostname, or machine-specific path found"
fi

if rg -n 'AKIA[0-9A-Z]{16}|BEGIN PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN EC PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|glpat-[A-Za-z0-9_-]{20,}|gh[opsu]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}' "$DOTFILES"; then
  fail "secret or private-key pattern found"
fi

printf 'Bundled public dotfiles contain no recognized secrets or personal machine paths.\n'
