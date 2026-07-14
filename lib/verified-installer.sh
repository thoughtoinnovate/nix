#!/usr/bin/env bash

set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: home-weave-verified-installer validate CATALOG
       home-weave-verified-installer plan CATALOG ID
       home-weave-verified-installer inspect CATALOG ID
       HOME_WEAVE_VERIFIED_INSTALLER_APPROVED=1 \
         home-weave-verified-installer apply CATALOG ID

Catalogs are immutable, reviewed JSON files. Each script installer requires an
HTTPS URL, an exact SHA-256, a reviewed official host, and immutableSource=true.
Remote content is downloaded to a file and verified; it is never piped to a shell.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

validate_catalog() {
  local catalog="$1"
  [[ -f "$catalog" ]] || die "installer catalog does not exist: $catalog"
  jq -e '
    .schemaVersion == 1 and
    (.installers | type == "array") and
    all(.installers[];
      (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
      (.name | type == "string" and length > 0) and
      (.version | type == "string" and length > 0) and
      (.kind == "script") and
      (.url | type == "string" and length > 0) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.interpreter == "bash" or .interpreter == "sh") and
      ((.arguments // []) | type == "array" and all(.[]; type == "string")) and
      (.publisher | type == "string" and length > 0) and
      (.publisherVerified == true) and
      (.repositoryTrust == "official upstream distribution") and
      (.immutableSource == true) and
      (.reviewedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
      (.officialHosts | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    ) and
    (([.installers[].id] | unique | length) == (.installers | length))
  ' "$catalog" >/dev/null || die "installer catalog failed schema or security-policy validation"

  local url host official_hosts
  while IFS=$'\t' read -r url official_hosts; do
    if [[ "$url" == https://* ]]; then
      host="${url#https://}"
      host="${host%%/*}"
      host="${host%%:*}"
      jq -e --arg host "$host" 'index($host) != null' <<<"$official_hosts" >/dev/null \
        || die "installer URL host is not in officialHosts: $host"
    elif [[ "${HOME_WEAVE_VERIFIED_INSTALLER_TESTING:-0}" == 1 && "$url" == file://* ]]; then
      :
    else
      die "installer URL must use HTTPS"
    fi
  done < <(jq -r '.installers[] | [.url, (.officialHosts | tojson)] | @tsv' "$catalog")
}

installer_json() {
  local catalog="$1" id="$2" count
  count="$(jq --arg id "$id" '[.installers[] | select(.id == $id)] | length' "$catalog")"
  [[ "$count" == 1 ]] || die "catalog must contain exactly one installer with id: $id"
  jq -c --arg id "$id" '.installers[] | select(.id == $id)' "$catalog"
}

show_plan() {
  local item="$1"
  jq -r '
    "Verified site installer plan:",
    "  Application:  \(.name) \(.version)",
    "  Publisher:    \(.publisher) (reviewed and verified)",
    "  Repository:   \(.repositoryTrust)",
    "  URL:          \(.url)",
    "  SHA-256:      \(.sha256)",
    "  Interpreter:  \(.interpreter)",
    "  Reviewed:     \(.reviewedAt)",
    "  Execution:    download -> verify checksum -> sanitized environment -> interpreter",
    "  Shell pipe:   never"
  ' <<<"$item"
}

fetch_verified() {
  local item="$1" destination="$2" url expected actual
  url="$(jq -r '.url' <<<"$item")"
  expected="$(jq -r '.sha256' <<<"$item")"
  if [[ "$url" == file://* ]]; then
    cp "${url#file://}" "$destination"
  else
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
      --output "$destination" "$url"
  fi
  actual="$(sha256sum "$destination" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] \
    || die "installer checksum mismatch: expected $expected, received $actual"
  chmod 0500 "$destination"
}

main() {
  require_command jq
  require_command sha256sum
  local action="${1:-}" catalog="${2:-}" id="${3:-}" item temp interpreter argument
  local -a arguments=()
  case "$action" in
    validate)
      [[ -n "$catalog" && $# == 2 ]] || { usage >&2; exit 2; }
      validate_catalog "$catalog"
      printf 'Verified installer catalog is valid: %s\n' "$catalog"
      ;;
    plan|inspect|apply)
      [[ -n "$catalog" && -n "$id" && $# == 3 ]] || { usage >&2; exit 2; }
      validate_catalog "$catalog"
      item="$(installer_json "$catalog" "$id")"
      show_plan "$item"
      [[ "$action" == plan ]] && return 0
      temp="$(mktemp "${TMPDIR:-/tmp}/home-weave-installer.XXXXXX")"
      trap "rm -f $(printf '%q' "$temp")" EXIT
      fetch_verified "$item" "$temp"
      if [[ "$action" == inspect ]]; then
        printf '\nVerified installer content (first 120 lines):\n'
        sed -n '1,120p' "$temp"
        return 0
      fi
      [[ "${HOME_WEAVE_VERIFIED_INSTALLER_APPROVED:-0}" == 1 ]] \
        || die "apply requires explicit provider approval"
      [[ "${EUID:-$(id -u)}" != 0 ]] || die "verified installers may not run as root"
      interpreter="$(jq -r '.interpreter' <<<"$item")"
      while IFS= read -r argument; do
        arguments+=("$argument")
      done < <(jq -r '.arguments[]?' <<<"$item")
      if ((${#arguments[@]} > 0)); then
        env -i \
          HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" \
          PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" SHELL="${SHELL:-/bin/sh}" \
          "$interpreter" "$temp" "${arguments[@]}"
      else
        env -i \
          HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" \
          PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" SHELL="${SHELL:-/bin/sh}" \
          "$interpreter" "$temp"
      fi
      ;;
    -h|--help|help|'') usage ;;
    *) die "unknown verified-installer action: $action" ;;
  esac
}

main "$@"
