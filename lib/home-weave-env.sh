#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'home-weave-env: %s\n' "$*" >&2
  exit 1
}

check_secret_permissions() {
  local file="$1" mode owner current
  if mode="$(stat -f '%Lp' "$file" 2>/dev/null)"; then
    owner="$(stat -f '%u' "$file")"
  else
    mode="$(stat -c '%a' "$file" 2>/dev/null)" || fail "cannot inspect permissions: $file"
    owner="$(stat -c '%u' "$file")"
  fi
  current="$(id -u)"
  [[ "$mode" == 600 ]] || fail "$file must have mode 0600 (found $mode)"
  [[ "$owner" == "$current" ]] || fail "$file must be owned by the current user"
}

load_files() {
  local file line key value line_number document='{}'
  for file in "$@"; do
    [[ -e "$file" ]] || continue
    [[ -f "$file" ]] || fail "environment source must be a regular file: $file"
    if [[ "${file##*/}" == .home_weave_secrets ]]; then
      [[ ! -L "$file" ]] || fail "secret source must not be a symlink: $file"
      check_secret_permissions "$file"
    fi
    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_number=$((line_number + 1))
      line="${line%$'\r'}"
      [[ "$line" != *$'\t'* ]] || fail "$file:$line_number contains a tab"
      [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
        line="${line#*export}"
        line="${line#"${line%%[![:space:]]*}"}"
      fi
      [[ "$line" == *=* ]] || fail "$file:$line_number must use NAME=VALUE"
      key="${line%%=*}"
      value="${line#*=}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "$file:$line_number has an unsafe variable name"
      [[ "$value" != *'`'* && "$value" != *'$('* && "$value" != *$'\n'* ]] \
        || fail "$file:$line_number contains executable shell syntax"
      document="$(jq -cn --argjson current "$document" --arg key "$key" --arg value "$value" \
        '$current + {($key): $value}')"
    done <"$file"
  done
  printf '%s\n' "$document"
}

render_posix() {
  local document="$1" key value
  while IFS= read -r key; do
    value="$(jq -r --arg key "$key" '.[$key]' <<<"$document")"
    printf 'export %s=%q\n' "$key" "$value"
  done < <(jq -r 'keys[]' <<<"$document")
}

render_fish() {
  local document="$1" key value escaped
  while IFS= read -r key; do
    value="$(jq -r --arg key "$key" '.[$key]' <<<"$document")"
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\'/\\\'}"
    printf "set -gx %s '%s'\n" "$key" "$escaped"
  done < <(jq -r 'keys[]' <<<"$document")
}

usage() {
  cat <<'EOF'
Usage: home-weave-env render posix|fish|json FILE...

Files use strict NAME=VALUE syntax. An optional leading "export " is accepted
for migration. Shell expressions are rejected and values are treated literally.
Missing files are ignored. A file named .home_weave_secrets must be a non-symlink
regular file owned by the current user with mode 0600.
EOF
}

command_name="${1:-help}"
shift || true
case "$command_name" in
  render)
    (($# >= 2)) || fail "render requires a format and at least one file"
    format="$1"
    shift
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    document="$(load_files "$@")"
    case "$format" in
      posix) render_posix "$document" ;;
      fish) render_fish "$document" ;;
      json) printf '%s\n' "$document" ;;
      *) fail "format must be posix, fish, or json" ;;
    esac
    ;;
  help|--help|-h) usage ;;
  *) fail "unknown command: $command_name" ;;
esac
