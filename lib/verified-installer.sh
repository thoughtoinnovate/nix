#!/usr/bin/env bash

set -Eeuo pipefail

CURL_BIN="${HOME_WEAVE_VERIFIED_CURL_BIN:-$(command -v curl || true)}"
CODESIGN_BIN="${HOME_WEAVE_VERIFIED_CODESIGN_BIN:-/usr/bin/codesign}"
HDIUTIL_BIN="${HOME_WEAVE_VERIFIED_HDIUTIL_BIN:-/usr/bin/hdiutil}"
DITTO_BIN="${HOME_WEAVE_VERIFIED_DITTO_BIN:-/usr/bin/ditto}"

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
       home-weave-verified-installer provider CATALOG \
         inventory|search|status|plan|apply [...]

Catalogs are immutable, reviewed JSON files. Supported installer kinds are:
  script          fixed HTTPS URL and exact SHA-256; never piped to a shell
  macos-dmg-app   vendor manifest checksum plus verified Apple Team ID
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

url_host() {
  local value="${1#https://}"
  value="${value%%/*}"
  printf '%s\n' "${value%%:*}"
}

validate_url() {
  local url="$1" official_hosts="$2" host
  if [[ "$url" == https://* ]]; then
    host="$(url_host "$url")"
    jq -e --arg host "$host" 'index($host) != null' <<<"$official_hosts" >/dev/null \
      || die "installer URL host is not in officialHosts: $host"
  elif [[ "${HOME_WEAVE_VERIFIED_INSTALLER_TESTING:-0}" == 1 && "$url" == file://* ]]; then
    :
  else
    die "installer URL must use HTTPS"
  fi
}

validate_catalog() {
  local catalog="$1" url official_hosts
  [[ -f "$catalog" ]] || die "installer catalog does not exist: $catalog"
  jq -e '
    .schemaVersion == 1 and
    (.installers | type == "array") and
    all(.installers[];
      (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
      (.name | type == "string" and length > 0) and
      (.kind == "script" or .kind == "macos-dmg-app") and
      (.publisher | type == "string" and length > 0) and
      (.publisherVerified == true) and
      (.repositoryTrust | type == "string" and length > 0) and
      (.publisherEvidence | type == "string" and length > 0) and
      (.reviewedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
      (.officialHosts | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9.-]+$"))) and
      if .kind == "script" then
        (.version | type == "string" and length > 0) and
        (.url | type == "string" and length > 0) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.interpreter == "bash" or .interpreter == "sh") and
        ((.arguments // []) | type == "array" and all(.[]; type == "string")) and
        (.repositoryTrust == "official upstream distribution") and
        (.immutableSource == true)
      else
        (.release | type == "object") and
        (.release.manifestUrl | type == "string" and length > 0) and
        (.release.downloadBaseUrl | type == "string" and length > 0) and
        all([.release.versionField, .release.itemsField, .release.downloadField,
             .release.sha256Field, .release.sizeField][];
          type == "string" and test("^[A-Za-z][A-Za-z0-9_]*$")) and
        (.release.match | type == "object" and length > 0 and all(keys[]; test("^[A-Za-z][A-Za-z0-9_]*$"))) and
        (.install | type == "object") and
        (.install.bundle | type == "string" and test("^[^/]+[.]app$")) and
        (.install.destination | type == "string" and test("^(Applications|[.]local/share)/[^/]+[.]app$") and (contains("..") | not)) and
        (.install.executable | type == "string" and startswith("Contents/") and (contains("..") | not)) and
        (.install.link | type == "string" and startswith(".local/bin/") and (contains("..") | not)) and
        (.install.appleTeamId | type == "string" and test("^[A-Z0-9]{10}$")) and
        ((.install.versionArguments // ["--version"]) | type == "array" and all(.[]; type == "string" and (contains("\\n") | not)))
      end
    ) and
    (([.installers[].id] | unique | length) == (.installers | length))
  ' "$catalog" >/dev/null || die "installer catalog failed schema or security-policy validation"

  while IFS=$'\t' read -r url official_hosts; do
    validate_url "$url" "$official_hosts"
  done < <(jq -r '.installers[] | select(.kind == "script") | [.url, (.officialHosts | tojson)] | @tsv' "$catalog")
  while IFS=$'\t' read -r url official_hosts; do
    validate_url "$url" "$official_hosts"
  done < <(jq -r '.installers[] | select(.kind == "macos-dmg-app") | [.release.manifestUrl, (.officialHosts | tojson)], [.release.downloadBaseUrl, (.officialHosts | tojson)] | @tsv' "$catalog")
}

installer_json() {
  local catalog="$1" id="$2" count
  count="$(jq --arg id "$id" '[.installers[] | select(.id == $id)] | length' "$catalog")"
  [[ "$count" == 1 ]] || die "catalog must contain exactly one installer with id: $id"
  jq -c --arg id "$id" '.installers[] | select(.id == $id)' "$catalog"
}

show_script_plan() {
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
  '
}

fetch_verified_script() {
  local item="$1" destination="$2" url expected actual
  url="$(jq -r '.url' <<<"$item")"
  expected="$(jq -r '.sha256' <<<"$item")"
  if [[ "$url" == file://* ]]; then
    cp "${url#file://}" "$destination"
  else
    "$CURL_BIN" --proto '=https' --tlsv1.2 --fail --location --silent --show-error --output "$destination" "$url"
  fi
  actual="$(sha256sum "$destination" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "installer checksum mismatch: expected $expected, received $actual"
  chmod 0500 "$destination"
}

run_script_action() {
  local action="$1" item="$2" temp interpreter argument
  local -a arguments=()
  show_script_plan <<<"$item"
  [[ "$action" == plan ]] && return 0
  temp="$(mktemp "${TMPDIR:-/tmp}/home-weave-installer.XXXXXX")"
  trap 'rm -f "${temp:-}"' EXIT
  fetch_verified_script "$item" "$temp"
  if [[ "$action" == inspect ]]; then
    printf '\nVerified installer content (first 120 lines):\n'
    sed -n '1,120p' "$temp"
    rm -f "$temp"
    trap - EXIT
    return 0
  fi
  [[ "${HOME_WEAVE_VERIFIED_INSTALLER_APPROVED:-0}" == 1 ]] || die "apply requires explicit provider approval"
  [[ "${EUID:-$(id -u)}" != 0 ]] || die "verified installers may not run as root"
  interpreter="$(jq -r '.interpreter' <<<"$item")"
  while IFS= read -r argument; do arguments+=("$argument"); done < <(jq -r '.arguments[]?' <<<"$item")
  if ((${#arguments[@]})); then
    env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" PATH="$PATH" \
      TMPDIR="${TMPDIR:-/tmp}" SHELL="${SHELL:-/bin/sh}" "$interpreter" "$temp" "${arguments[@]}"
  else
    env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" PATH="$PATH" \
      TMPDIR="${TMPDIR:-/tmp}" SHELL="${SHELL:-/bin/sh}" "$interpreter" "$temp"
  fi
  rm -f "$temp"
  trap - EXIT
}

require_macos_tools() {
  [[ "$(uname -s)" == Darwin || "${HOME_WEAVE_VERIFIED_INSTALLER_ALLOW_NON_DARWIN:-0}" == 1 ]] \
    || die "macos-dmg-app installers support macOS only"
  [[ -n "$CURL_BIN" && -x "$CURL_BIN" ]] || die "curl is required"
  [[ -x "$CODESIGN_BIN" ]] || die "codesign is required"
  [[ -x "$HDIUTIL_BIN" ]] || die "hdiutil is required"
  [[ -x "$DITTO_BIN" ]] || die "ditto is required"
}

home_path() {
  printf '%s/%s\n' "$HOME" "$1"
}

encode_download_path() {
  local path="$1" result="" segment separator=""
  local -a segments=()
  IFS='/' read -r -a segments <<<"$path"
  for segment in "${segments[@]}"; do
    result+="$separator$(jq -nr --arg value "$segment" '$value | @uri')"
    separator=/
  done
  printf '%s\n' "$result"
}

resolve_dmg_release() {
  local item="$1" manifest manifest_url items_field version_field download_field checksum_field size_field match
  manifest_url="$(jq -r '.release.manifestUrl' <<<"$item")"
  manifest="$($CURL_BIN --proto '=https' --tlsv1.2 -fsSL "$manifest_url")" || die "could not download the reviewed vendor release manifest"
  items_field="$(jq -r '.release.itemsField' <<<"$item")"
  version_field="$(jq -r '.release.versionField' <<<"$item")"
  download_field="$(jq -r '.release.downloadField' <<<"$item")"
  checksum_field="$(jq -r '.release.sha256Field' <<<"$item")"
  size_field="$(jq -r '.release.sizeField' <<<"$item")"
  match="$(jq -c '.release.match' <<<"$item")"
  jq -ce --arg items "$items_field" --arg version "$version_field" --arg download "$download_field" \
    --arg checksum "$checksum_field" --arg size "$size_field" --argjson match "$match" '
      . as $manifest
      | [($manifest[$items] // [])[]
          | select(. as $candidate
              | reduce ($match | to_entries[]) as $wanted
                  (true; . and ($candidate[$wanted.key] == $wanted.value)))]
      | if length == 1 then .[0] else error("expected exactly one matching artifact") end
      | {version: $manifest[$version], download: .[$download], sha256: .[$checksum], size: .[$size]}
      | select((.version | type == "string" and length > 0) and
               (.download | type == "string" and length > 0 and startswith("/") | not) and
               (.download | contains("..") | not) and
               (.download | contains("?") | not) and
               (.download | contains("#") | not) and
               (.download | contains("\\") | not) and
               (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
               (.size | type == "number" and . > 0))
    ' <<<"$manifest" || die "vendor release manifest did not contain one valid reviewed artifact"
}

artifact_paths() {
  local item="$1"
  APP_PATH="$(home_path "$(jq -r '.install.destination' <<<"$item")")"
  APP_EXECUTABLE="$APP_PATH/$(jq -r '.install.executable' <<<"$item")"
  LINK_PATH="$(home_path "$(jq -r '.install.link' <<<"$item")")"
}

verified_team_id() {
  local app="$1" expected="$2" actual
  actual="$($CODESIGN_BIN -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1 || true)"
  [[ "$actual" == "$expected" ]] || return 1
  "$CODESIGN_BIN" --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  printf '%s\n' "$actual"
}

artifact_inventory_item() {
  local item="$1" installed=false version="" evidence="not detected" verified=false team expected
  local -a version_args=()
  artifact_paths "$item"
  expected="$(jq -r '.install.appleTeamId' <<<"$item")"
  if [[ -x "$APP_EXECUTABLE" ]]; then
    installed=true
    while IFS= read -r argument; do version_args+=("$argument"); done < <(jq -r '.install.versionArguments[]? // "--version"' <<<"$item")
    version="$("$APP_EXECUTABLE" "${version_args[@]}" 2>/dev/null | head -n 1 || true)"
    evidence="executable:$APP_EXECUTABLE"
    team="$(verified_team_id "$APP_PATH" "$expected" || true)"
    if [[ "$team" == "$expected" ]]; then
      verified=true
      evidence+=";apple-team-id:$team;signature-valid"
    else
      evidence+=";apple-team-id:${team:-missing};signature-unverified"
    fi
  fi
  jq -cn --argjson installed "$installed" --argjson verified "$verified" --arg version "$version" --arg evidence "$evidence" \
    --argjson item "$item" '{id:$item.id,name:$item.name,kind:"cli",installed:$installed,
      version:(if $version == "" then null else $version end),inventoryOnly:false,
      repositoryTrust:$item.repositoryTrust,publisher:$item.publisher,publisherVerified:$verified,
      publisherEvidence:$item.publisherEvidence,evidence:$evidence}'
}

show_dmg_plan() {
  local item="$1" release="$2" encoded url mib
  artifact_paths "$item"
  encoded="$(encode_download_path "$(jq -r '.download' <<<"$release")")"
  url="$(jq -r '.release.downloadBaseUrl' <<<"$item")/$encoded"
  mib="$(awk -v bytes="$(jq -r '.size' <<<"$release")" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
  printf 'Verified application install plan:\n' >&2
  printf '  Application: %s %s\n' "$(jq -r '.name' <<<"$item")" "$(jq -r '.version' <<<"$release")" >&2
  printf '  Download:    %s (%s MiB)\n' "$url" "$mib" >&2
  printf '  SHA-256:     %s\n' "$(jq -r '.sha256' <<<"$release")" >&2
  printf '  Publisher:   %s (Apple Team ID %s)\n' "$(jq -r '.publisher' <<<"$item")" "$(jq -r '.install.appleTeamId' <<<"$item")" >&2
  printf '  Destination: %s\n' "$APP_PATH" >&2
  printf '  Command link:%s\n' " $LINK_PATH" >&2
  printf '  Execution:   download DMG -> verify manifest checksum -> verify Apple signature -> copy per-user app\n' >&2
  printf '  Shell pipe:  never\n' >&2
}

install_dmg() {
  local item="$1" release="$2" download_url temp dmg mount bundle expected actual team copied=0 mounted=0 completed=0
  artifact_paths "$item"
  [[ "${EUID:-$(id -u)}" != 0 ]] || die "verified artifact installers may not run as root"
  [[ ! -e "$APP_PATH" && ! -L "$APP_PATH" ]] || die "application destination already exists: $APP_PATH"
  [[ ! -e "$LINK_PATH" && ! -L "$LINK_PATH" ]] || die "command destination already exists: $LINK_PATH"
  expected="$(jq -r '.install.appleTeamId' <<<"$item")"
  download_url="$(jq -r '.release.downloadBaseUrl' <<<"$item")/$(encode_download_path "$(jq -r '.download' <<<"$release")")"
  temp="$(mktemp -d "${TMPDIR:-/tmp}/home-weave-artifact.XXXXXX")"; dmg="$temp/artifact.dmg"; mount="$temp/mount"; mkdir -p "$mount"
  cleanup_artifact() {
    local status=$?
    trap - EXIT
    [[ "$mounted" == 1 ]] && "$HDIUTIL_BIN" detach "$mount" -quiet >/dev/null 2>&1 || true
    if [[ "$completed" != 1 && "$copied" == 1 ]]; then [[ -L "$LINK_PATH" ]] && rm -f "$LINK_PATH"; rm -rf "$APP_PATH"; fi
    rm -rf "$temp"
    exit "$status"
  }
  trap cleanup_artifact EXIT
  "$CURL_BIN" --proto '=https' --tlsv1.2 -fsSL -o "$dmg" "$download_url" || die "could not download the reviewed artifact"
  actual="$(sha256sum "$dmg" | awk '{print $1}')"
  [[ "$actual" == "$(jq -r '.sha256' <<<"$release")" ]] || die "artifact checksum mismatch"
  "$HDIUTIL_BIN" attach "$dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null || die "could not mount verified DMG"
  mounted=1; bundle="$mount/$(jq -r '.install.bundle' <<<"$item")"; [[ -d "$bundle" ]] || die "verified DMG does not contain configured application bundle"
  team="$(verified_team_id "$bundle" "$expected" || true)"; [[ "$team" == "$expected" ]] || die "application signature does not match configured Apple Team ID"
  mkdir -p "$(dirname "$APP_PATH")" "$(dirname "$LINK_PATH")"
  "$DITTO_BIN" "$bundle" "$APP_PATH" || die "could not copy verified application"; copied=1
  team="$(verified_team_id "$APP_PATH" "$expected" || true)"; [[ "$team" == "$expected" ]] || die "copied application failed Apple signature verification"
  [[ -x "$APP_EXECUTABLE" ]] || die "application does not contain configured executable"
  ln -s "$APP_EXECUTABLE" "$LINK_PATH"
  completed=1; "$HDIUTIL_BIN" detach "$mount" -quiet >/dev/null 2>&1 || true; mounted=0; rm -rf "$temp"; trap - EXIT
}

run_dmg_action() {
  local action="$1" item="$2" release inventory
  require_macos_tools
  artifact_paths "$item"
  case "$action" in
    plan-install) release="$(resolve_dmg_release "$item")"; show_dmg_plan "$item" "$release" ;;
    apply-install)
      inventory="$(artifact_inventory_item "$item")"
      [[ "$(jq -r '.installed' <<<"$inventory")" == true ]] && { printf '%s is already installed.\n' "$(jq -r '.name' <<<"$item")" >&2; return; }
      release="$(resolve_dmg_release "$item")"; show_dmg_plan "$item" "$release"; install_dmg "$item" "$release" ;;
    plan-remove) [[ -x "$APP_EXECUTABLE" ]] || die "application is not installed"; printf 'Verified application removal plan: remove %s and owned link %s\n' "$APP_PATH" "$LINK_PATH" >&2 ;;
    apply-remove)
      [[ -x "$APP_EXECUTABLE" ]] || return 0
      if [[ -L "$LINK_PATH" && "$(readlink "$LINK_PATH")" == "$APP_EXECUTABLE" ]]; then rm "$LINK_PATH"; fi
      rm -rf "$APP_PATH" ;;
    *) die "unsupported artifact action: $action" ;;
  esac
}

provider_main() {
  local catalog="$1" command="${2:-inventory}" action="" id="" item query
  shift 2 || true
  validate_catalog "$catalog"
  case "$command" in
    inventory|status)
      printf '{"schemaVersion":1,"items":['
      local first=1
      while IFS= read -r item; do
        [[ "$(jq -r '.kind' <<<"$item")" == macos-dmg-app ]] || continue
        ((first)) || printf ','; artifact_inventory_item "$item"; first=0
      done < <(jq -c '.installers[]' "$catalog")
      printf ']'
      [[ "$command" == status ]] && printf ',"ready":true'
      printf '}\n' ;;
    search)
      query="${1:-}"
      provider_main "$catalog" inventory | jq -c --arg query "$query" '{schemaVersion:1,items:[.items[]|select((.name+" "+.id)|ascii_downcase|contains($query|ascii_downcase))]}' ;;
    plan|apply)
      [[ "${1:-}" == --action && -n "${2:-}" && -n "${3:-}" ]] || die "usage: provider CATALOG $command --action install|remove ID"
      action="$2"; id="$3"; item="$(installer_json "$catalog" "$id")"
      [[ "$(jq -r '.kind' <<<"$item")" == macos-dmg-app ]] || die "provider mode supports managed artifact installers only"
      run_dmg_action "$command-$action" "$item" ;;
    *) die "unsupported verified installer provider command: $command" ;;
  esac
}

main() {
  require_command jq; require_command sha256sum
  local action="${1:-}" catalog="${2:-}" id="${3:-}" item
  case "$action" in
    validate) [[ -n "$catalog" && $# == 2 ]] || { usage >&2; exit 2; }; validate_catalog "$catalog"; printf 'Verified installer catalog is valid: %s\n' "$catalog" ;;
    plan|inspect|apply)
      [[ -n "$catalog" && -n "$id" && $# == 3 ]] || { usage >&2; exit 2; }; validate_catalog "$catalog"; item="$(installer_json "$catalog" "$id")"
      if [[ "$(jq -r '.kind' <<<"$item")" == script ]]; then run_script_action "$action" "$item"
      else [[ "$action" != inspect ]] || die "inspect is available only for script installers"; [[ "$action" != apply || "${HOME_WEAVE_VERIFIED_INSTALLER_APPROVED:-0}" == 1 ]] || die "apply requires explicit provider approval"; run_dmg_action "$action-install" "$item"; fi ;;
    provider) [[ -n "$catalog" && $# -ge 3 ]] || { usage >&2; exit 2; }; provider_main "$catalog" "${@:3}" ;;
    -h|--help|help|'') usage ;;
    *) die "unknown verified-installer action: $action" ;;
  esac
}

main "$@"
