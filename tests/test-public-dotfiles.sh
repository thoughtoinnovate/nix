#!/usr/bin/env bash

set -Eeuo pipefail

DOTFILES="${1:?usage: test-public-dotfiles.sh PATH_TO_BUNDLED_DOTFILES [PUBLIC_SOURCE_ROOT]}"
PUBLIC_ROOT="${2:-}"

fail() {
  printf 'public dotfile sanitization failed: %s\n' "$*" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "required scanner is unavailable: rg"

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

  # Keep organization deny-list signatures effective without publishing the
  # corresponding identifiers as literal source text.
  private_identifier_pattern='company-internal|corp-vault|managed-device-provider|private-user|private-host|documents/private|organization-profile|personal-profile|cloud-functions'
  private_identifier_pattern+='|demand''base'
  private_identifier_pattern+='|kan''dji'
  private_identifier_pattern+='|(^|[^a-z])i''ru([^a-z]|$)'
  private_identifier_pattern+='|(^|[^a-z])c''tp([^a-z]|$)'
  private_identifier_pattern+='|gitlab\.com([/:]|$)|gitlab\.[a-z0-9.-]+\.(com|net|org)'

  if find "$PUBLIC_ROOT" -type d -name '.git' -prune -o \( \
    -name '.DS_Store' -o -name '.state' -o -name 'result' -o -name 'result-*' \
    -o -name '.env' -o -name '.env.local' -o -name '*.pem' -o -name '*.key' \
    -o -name '*.p12' -o -name '*.pfx' -o -name 'credentials' \
    -o -name 'connections.toml' \
    -o -name '*.backup' -o -name '*.bak' -o -name '*.orig' -o -name '*.rej' \
  \) -print -quit | grep -q .; then
    fail "local state, backup, result, reject, original, or metadata file found"
  fi

  while IFS= read -r link; do
    target="$(readlink "$link")"
    [[ "$target" != /* ]] || fail "absolute symlink target found: $link"
    resolved="$(realpath "$link" 2>/dev/null || true)"
    [[ -n "$resolved" && "$resolved" == "$(realpath "$PUBLIC_ROOT")"/* ]] \
      || fail "escaping or dangling symlink target found: $link"
  done < <(find "$PUBLIC_ROOT" -type d -name '.git' -prune -o -type l -print)

  # ripgrep evaluates exclusion globs relative to each search root. Keep both
  # forms so repository-root and nested Git metadata are never treated as
  # publishable source, while all other hidden files remain in scope.
  public_rg_args=(
    -n
    --hidden
    --glob '!.git'
    --glob '!.git/**'
    --glob '!**/.git'
    --glob '!**/.git/**'
    --glob '!test-public-dotfiles.sh'
    --glob '!**/test-public-dotfiles.sh'
  )

  if rg "${public_rg_args[@]}" -i \
    "$private_identifier_pattern" \
    "$PUBLIC_ROOT"; then
    fail "private distribution, work profile, or personal identifier found"
  fi

  if rg "${public_rg_args[@]}" -i \
    '"(account|sso_account_id)"[[:space:]]*:[[:space:]]*"[0-9]{12}"|^[[:space:]]*sso_account_id[[:space:]]*=[[:space:]]*[0-9]{12}|arn:aws:[^[:space:]]*:[0-9]{12}:|https://d-[a-z0-9]+\.awsapps\.com/start|^[[:space:]]*(sso_start_url|sso_region|sso_account_id|role_arn|source_profile|credential_process)[[:space:]]*=' \
    "$PUBLIC_ROOT"; then
    fail "AWS account, ARN, or SSO organization metadata found"
  fi

  if rg "${public_rg_args[@]}" \
    '^[[:space:]]*(aws_access_key_id|aws_secret_access_key|aws_session_token)[[:space:]]*=[[:space:]]*[^[:space:]#]+|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}' \
    "$PUBLIC_ROOT"; then
    fail "AWS credential material found"
  fi

  if rg "${public_rg_args[@]}" -i \
    'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|BEGIN PGP PRIVATE KEY BLOCK|glpat-[A-Za-z0-9_-]{20,}|gh[opsu]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|/Users/[A-Za-z0-9._-]+|(^|["'"'"'=[:space:]])/home/[A-Za-z0-9._-]+' \
    "$PUBLIC_ROOT"; then
    fail "secret, account, username, hostname, or absolute home-path data found"
  fi
  if rg "${public_rg_args[@]}" -i \
    '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' "$PUBLIC_ROOT" \
      | rg -vi '@example\.(org|com|net|invalid)([^a-z]|$)'; then
    fail "non-example email address found"
  fi
fi

printf 'Public source contains no recognized secrets, work metadata, or personal machine paths.\n'
