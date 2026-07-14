#!/usr/bin/env bash

set -Eeuo pipefail

DOTFILES="${1:?usage: test-public-dotfiles.sh PATH_TO_BUNDLED_DOTFILES [PUBLIC_SOURCE_ROOT]}"
PUBLIC_ROOT="${2:-}"

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

if [[ -n "$PUBLIC_ROOT" ]]; then
  [[ -d "$PUBLIC_ROOT" ]] || fail "missing public source root: $PUBLIC_ROOT"

  if rg -n -i --hidden --glob '!.git/**' --glob '!tests/**' --glob '!**/tests/**' \
    'demandbase|vault\.demandbase|iru|kandji|strongdm|hvashisht|dq0hq7rh7l|documents/work|db-home|work-db|home-weave-personal|aws_functions' \
    "$PUBLIC_ROOT"; then
    fail "private distribution, work profile, or personal identifier found"
  fi

  if rg -n -i --hidden --glob '!.git/**' --glob '!tests/**' --glob '!**/tests/**' \
    '"(account|sso_account_id)"[[:space:]]*:[[:space:]]*"[0-9]{12}"|^[[:space:]]*sso_account_id[[:space:]]*=[[:space:]]*[0-9]{12}|arn:aws:[^[:space:]]*:[0-9]{12}:|https://d-[a-z0-9]+\.awsapps\.com/start' \
    "$PUBLIC_ROOT"; then
    fail "AWS account, ARN, or SSO organization metadata found"
  fi

  if rg -n --hidden --glob '!.git/**' --glob '!tests/**' --glob '!**/tests/**' \
    '^[[:space:]]*(aws_access_key_id|aws_secret_access_key|aws_session_token)[[:space:]]*=[[:space:]]*[^[:space:]#]+|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}' \
    "$PUBLIC_ROOT"; then
    fail "AWS credential material found"
  fi
fi

printf 'Public source contains no recognized secrets, work metadata, or personal machine paths.\n'
