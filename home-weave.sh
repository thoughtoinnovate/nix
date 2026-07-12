#!/usr/bin/env bash

set -Eeuo pipefail

COMMAND="${1:-help}"
[[ $# -eq 0 ]] || shift

ROOT="${HOME_WEAVE_ROOT:-$HOME/.home-weave}"
BASE_URL="${HOME_WEAVE_BASE_URL:-github:thoughtoinnovate/nix}"
TEMPLATE="${HOME_WEAVE_PROFILE_TEMPLATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates/profile}"
PROFILE_OVERLAY="${HOME_WEAVE_PROFILE_OVERLAY:-}"
BUNDLED_DOTFILES="${HOME_WEAVE_BUNDLED_DOTFILES:-}"
PACKAGE_PREVIEW="${HOME_WEAVE_PACKAGE_PREVIEW:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/package-preview.sh}"
EXTENSIONS_JSON="${HOME_WEAVE_EXTENSIONS_JSON:-[] }"
ASSUME_YES=false
APPLY_NOW=""
PROFILE=""
EXTENDS="base"
PRIMARY_SHELL=""
SELECTED_SHELLS=""
REQUESTED_PACKAGES=()
MANAGED_PROVIDER_IDS=""
REMOTE_URL=""
RESTORE_MODE=""
NO_GIT=false
TIMESTAMP=""
OLD_ROOT=""
ADOPTION_BACKUP_ROOT=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
HomeWeave manages reproducible packages with Nix and user configuration with Stow.

Usage:
  home-weave setup [options]
  home-weave plan [--root PATH] [--profile NAME]
  home-weave apply [--root PATH] [--profile NAME]
  home-weave update [--root PATH]
  home-weave restore [GIT_URL] [--merge|--override] [--root PATH]
  home-weave sync [--root PATH]
  home-weave provider list|inventory|search|install|update|remove ...
  home-weave extension list|NAME [arguments...]

Setup options:
  --root PATH             User repository (default: ~/.home-weave)
  --profile NAME          base, development, or a custom profile
  --extends NAME          Parent for a new custom profile (default: base)
  --shell NAME[,NAME...]  Shells to install; the first is primary
  --package NAME          Add a Nix package; may be repeated
  --remote URL            Existing private Git remote
  --apply                 Activate after generating the repository
  --no-apply              Generate only
  --no-git                Do not initialize Git
  --yes                   Confirm safe non-interactive defaults

The first invocation can be:
  nix run github:thoughtoinnovate/nix#home-weave -- setup
EOF
}

confirm() {
  local prompt="$1" answer
  if "$ASSUME_YES"; then
    return 0
  fi
  [[ -t 0 ]] || return 1
  printf '%s [y/N] ' "$prompt"
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

normalize_root() {
  local parent
  case "$ROOT" in
    \~/*) ROOT="$HOME/${ROOT#\~/}" ;;
    /*) ;;
    *) ROOT="$PWD/$ROOT" ;;
  esac
  if [[ -e "$ROOT" ]]; then
    ROOT="$(realpath "$ROOT")"
  else
    parent="$(dirname "$ROOT")"
    [[ -d "$parent" ]] || fail "parent directory does not exist: $parent"
    ROOT="$(realpath "$parent")/$(basename "$ROOT")"
  fi
  case "$ROOT" in
    "$HOME"|"/") fail "refusing unsafe HomeWeave root: $ROOT" ;;
    "$HOME"/*) ;;
    *) fail "HomeWeave root must be inside the current user's home: $ROOT" ;;
  esac
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$1" != "." && "$1" != ".." ]] \
    || fail "unsafe name: $1"
}

parse_common_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) [[ $# -ge 2 ]] || fail "--root requires a path"; ROOT="$2"; shift 2 ;;
      --namespace)
        [[ $# -ge 2 ]] || fail "--namespace requires a name"
        validate_name "$2"
        warn "--namespace is deprecated; use --root"
        ROOT="$HOME/.$2"
        shift 2
        ;;
      --profile) [[ $# -ge 2 ]] || fail "--profile requires a name"; PROFILE="$2"; shift 2 ;;
      --extends) [[ $# -ge 2 ]] || fail "--extends requires a name"; EXTENDS="$2"; shift 2 ;;
      --shell)
        [[ $# -ge 2 ]] || fail "--shell requires a name"
        SELECTED_SHELLS="$(tr ',' '\n' <<<"$2")"
        PRIMARY_SHELL="$(head -n 1 <<<"$SELECTED_SHELLS")"
        shift 2
        ;;
      --package) [[ $# -ge 2 ]] || fail "--package requires a name"; REQUESTED_PACKAGES+=("$2"); shift 2 ;;
      --remote) [[ $# -ge 2 ]] || fail "--remote requires a URL"; REMOTE_URL="$2"; shift 2 ;;
      --apply) APPLY_NOW=true; shift ;;
      --no-apply) APPLY_NOW=false; shift ;;
      --no-git) NO_GIT=true; shift ;;
      --yes|-y) ASSUME_YES=true; shift ;;
      --merge) RESTORE_MODE=merge; shift ;;
      --override) RESTORE_MODE=override; shift ;;
      --help|-h) usage; exit 0 ;;
      --) shift; break ;;
      *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
  done
}

require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
  done
}

run_with_spinner() {
  local label="$1" output_file="$2" pid frame=0 status frames="|/-\\"
  shift 2
  if [[ ! -t 2 ]]; then
    "$@" >"$output_file"
    return
  fi
  "$@" >"$output_file" 2>"$output_file.stderr" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s' "${frames:frame++%4:1}" "$label" >&2
    sleep 0.12
  done
  if wait "$pid"; then status=0; else status=$?; fi
  if ((status == 0)); then
    printf '\r✓ %s\n' "$label" >&2
  else
    printf '\r✗ %s\n' "$label" >&2
    [[ ! -s "$output_file.stderr" ]] || sed -n '1,8p' "$output_file.stderr" >&2
  fi
  rm -f "$output_file.stderr"
  return "$status"
}

prune_backups() {
  local backups=( ) index
  [[ -d "$ROOT/backup" ]] || return 0
  while IFS= read -r item; do backups+=("$item"); done < <(
    find "$ROOT/backup" -mindepth 1 -maxdepth 1 -type d -print | sort -r
  )
  for ((index = 5; index < ${#backups[@]}; index++)); do
    rm -rf "${backups[$index]}"
  done
}

snapshot_configuration() {
  local label="$1" snapshot
  snapshot="$ROOT/backup/$(date -u +%Y%m%dT%H%M%SZ)-$label"
  mkdir -p "$snapshot"
  rsync -a --exclude='.git/' --exclude='.state/' --exclude='backup/' "$ROOT/" "$snapshot/"
  prune_backups
}

begin_root_replacement() {
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  OLD_ROOT=""
  if [[ -e "$ROOT" ]]; then
    [[ -d "$ROOT" ]] || fail "$ROOT exists but is not a directory"
    if find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      printf 'Existing HomeWeave root: %s\n' "$ROOT"
      du -sh "$ROOT" 2>/dev/null || true
      confirm "Back up and replace the entire existing HomeWeave setup?" \
        || fail "existing setup was left unchanged"
      OLD_ROOT="${ROOT}.replacing.${TIMESTAMP}.$$"
      mv "$ROOT" "$OLD_ROOT"
    else
      rmdir "$ROOT"
    fi
  fi
  mkdir -p "$ROOT"
}

rollback_root_replacement() {
  [[ -n "$OLD_ROOT" && -d "$OLD_ROOT" ]] || return 0
  rm -rf "$ROOT"
  mv "$OLD_ROOT" "$ROOT"
  OLD_ROOT=""
}

commit_root_replacement() {
  local previous_backup
  [[ -n "$OLD_ROOT" && -d "$OLD_ROOT" ]] || return 0
  mkdir -p "$ROOT/backup"
  if [[ -d "$OLD_ROOT/backup" ]]; then
    while IFS= read -r previous_backup; do
      mv "$previous_backup" "$ROOT/backup/"
    done < <(find "$OLD_ROOT/backup" -mindepth 1 -maxdepth 1 -print)
    rmdir "$OLD_ROOT/backup" 2>/dev/null || true
  fi
  mv "$OLD_ROOT" "$ROOT/backup/$TIMESTAMP"
  OLD_ROOT=""
  prune_backups
}

write_state() {
  mkdir -p "$ROOT/.state"
  printf '%s\n' "$PROFILE" >"$ROOT/.state/active-profile"
  printf '%s\n' "$PRIMARY_SHELL" >"$ROOT/.state/primary-shell"
}

read_state() {
  [[ -n "$PROFILE" || ! -r "$ROOT/.state/active-profile" ]] \
    || PROFILE="$(<"$ROOT/.state/active-profile")"
  [[ -n "$PRIMARY_SHELL" || ! -r "$ROOT/.state/primary-shell" ]] \
    || PRIMARY_SHELL="$(<"$ROOT/.state/primary-shell")"
  PROFILE="${PROFILE:-base}"
  PRIMARY_SHELL="${PRIMARY_SHELL:-zsh}"
  validate_name "$PROFILE"
  case "$PRIMARY_SHELL" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $PRIMARY_SHELL" ;; esac
}

choose_profile() {
  local choice custom parent profiles
  if [[ -n "$PROFILE" ]]; then
    validate_name "$PROFILE"
    return
  fi
  if [[ ! -t 0 ]]; then PROFILE=base; return; fi
  profiles="$(find "$ROOT/nix" -mindepth 2 -maxdepth 2 -name profile.nix -print \
    | sed -E 's|.*/nix/([^/]+)/profile.nix|\1|' | sort)"
  if command -v fzf >/dev/null 2>&1; then
    choice="$(printf '%s\n%s\n' "$profiles" '+ create custom profile' | fzf --prompt='Profile> ' || true)"
  else
    printf 'Available profiles:\n%s\nProfile [base]: ' "$profiles"
    read -r choice
  fi
  case "$choice" in
    '+ create custom profile'|custom)
      printf 'Custom profile name: '; read -r custom; validate_name "$custom"
      printf 'Extend profile [base]: '; read -r parent; parent="${parent:-base}"; validate_name "$parent"
      PROFILE="$custom"
      mkdir -p "$ROOT/nix/$PROFILE"
      cat >"$ROOT/nix/$PROFILE/profile.nix" <<EOF
{
  extends = "$parent";
  shells = [ "zsh" ];
  primaryShell = "zsh";
  nixPackages = [ ];
  homebrewCasks = [ ];
  allowUnfree = [ ];
}
EOF
      ;;
    "") PROFILE=base ;;
    *) validate_name "$choice"; [[ -f "$ROOT/nix/$choice/profile.nix" ]] || fail "profile does not exist: $choice"; PROFILE="$choice" ;;
  esac
}

scan_secrets() {
  local scope="$1" secret
  while IFS= read -r secret; do
    fail "refusing to include likely credential material: $secret"
  done < <(find "$scope" \
    \( -path "$scope/backup" -o -path "$scope/.state" -o -path "$scope/.git" \) -prune -o \
    -type f \( -name credentials -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \
      -o -name '*.pfx' -o -name '.env' -o -name '.env.local' \) -print -quit)
  if command -v rg >/dev/null 2>&1 && rg -l --hidden \
    'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|aws_secret_access_key[[:space:]]*=|(^|[^A-Z])API_TOKEN[[:space:]]*=' \
    "$scope" --glob '!backup/**' --glob '!.state/**' --glob '!.git/**' | grep -q .; then
    fail "likely secret content was detected; keep credentials in a local secret store"
  fi
}

ensure_profile() {
  local file="$ROOT/nix/$PROFILE/profile.nix"
  [[ -f "$file" ]] && return 0
  validate_name "$PROFILE"
  validate_name "$EXTENDS"
  [[ -f "$ROOT/nix/$EXTENDS/profile.nix" ]] || fail "parent profile does not exist: $EXTENDS"
  mkdir -p "$ROOT/nix/$PROFILE"
  cat >"$file" <<EOF
{
  extends = "$EXTENDS";
  shells = [ "zsh" ];
  primaryShell = "zsh";
  nixPackages = [ ];
  homebrewCasks = [ ];
  allowUnfree = [ ];
}
EOF
}

choose_shell() {
  local selected primary
  if [[ -n "$PRIMARY_SHELL" ]]; then
    case "$PRIMARY_SHELL" in
      bash|zsh|fish|nushell)
        SELECTED_SHELLS="${SELECTED_SHELLS:-$PRIMARY_SHELL}"
        while IFS= read -r selected; do
          case "$selected" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $selected" ;; esac
        done <<<"$SELECTED_SHELLS"
        return
        ;;
      *) fail "unsupported shell: $PRIMARY_SHELL" ;;
    esac
  fi
  if [[ ! -t 0 ]]; then PRIMARY_SHELL=zsh; SELECTED_SHELLS=zsh; return; fi
  if command -v fzf >/dev/null 2>&1; then
    selected="$(printf '%s\n' bash zsh fish nushell | fzf --multi --prompt='Shells (tab selects)> ' || true)"
  else
    printf 'Shells, comma separated [zsh]: '
    read -r selected
    selected="$(tr ',' '\n' <<<"${selected:-zsh}")"
  fi
  [[ -n "$selected" ]] || selected=zsh
  SELECTED_SHELLS="$selected"
  printf 'Primary shell [first selection]: '
  read -r primary
  PRIMARY_SHELL="${primary:-$(head -n 1 <<<"$selected")}"
  case "$PRIMARY_SHELL" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $PRIMARY_SHELL" ;; esac
  grep -Fxq "$PRIMARY_SHELL" <<<"$SELECTED_SHELLS" || fail "primary shell must be selected"
}

update_profile_shell() {
  local file="$ROOT/nix/$PROFILE/profile.nix" temporary shell shell_values=""
  [[ -f "$file" ]] || fail "profile is missing: $PROFILE"
  while IFS= read -r shell; do
    case "$shell" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $shell" ;; esac
    shell_values+=" \"$shell\""
  done <<<"${SELECTED_SHELLS:-$PRIMARY_SHELL}"
  temporary="$file.tmp.$$"
  sed -E \
    -e "s/shells = \[[^]]*\];/shells = [$shell_values ];/" \
    -e "s/primaryShell = \"[^\"]*\";/primaryShell = \"$PRIMARY_SHELL\";/" \
    "$file" >"$temporary"
  mv "$temporary" "$file"
}

add_profile_packages() {
  local file="$ROOT/nix/$PROFILE/profile.nix" temporary package package_values=""
  shift 0
  for package in "$@"; do
    [[ "$package" =~ ^[a-zA-Z0-9+_-]+([.][a-zA-Z0-9+_-]+)*$ ]] || fail "unsafe Nix package name: $package"
    package_values+=" \"$package\""
  done
  [[ -n "$package_values" ]] || return 0
  temporary="$file.tmp.$$"
  sed -E "s/nixPackages = \[[^]]*\];/nixPackages = [$package_values ];/" "$file" >"$temporary"
  mv "$temporary" "$file"
}

add_profile_unfree() {
  local file="$ROOT/nix/$PROFILE/profile.nix" temporary package_values="" package
  for package in "$@"; do package_values+=" \"$package\""; done
  [[ -n "$package_values" ]] || return 0
  temporary="$file.tmp.$$"
  sed -E "s/allowUnfree = \[[^]]*\];/allowUnfree = [$package_values ];/" "$file" >"$temporary"
  mv "$temporary" "$file"
}

pinned_nixpkgs_ref() {
  local metadata metadata_file locked_type owner repo rev
  metadata_file="$(mktemp)"
  if ! run_with_spinner "Resolving the pinned Nixpkgs revision..." "$metadata_file" \
    nix --extra-experimental-features 'nix-command flakes' flake metadata --json "$BASE_URL"; then
    rm -f "$metadata_file"
    return 1
  fi
  metadata="$(<"$metadata_file")"
  rm -f "$metadata_file"
  locked_type="$(jq -r '.locks.nodes.nixpkgs.locked.type // empty' <<<"$metadata")"
  [[ "$locked_type" == github ]] || return 1
  owner="$(jq -r '.locks.nodes.nixpkgs.locked.owner' <<<"$metadata")"
  repo="$(jq -r '.locks.nodes.nixpkgs.locked.repo' <<<"$metadata")"
  rev="$(jq -r '.locks.nodes.nixpkgs.locked.rev' <<<"$metadata")"
  printf 'github:%s/%s/%s' "$owner" "$repo" "$rev"
}

enrich_nixpkgs_results() {
  local pinned="$1" results="$2" paths_file metadata_file system expression enriched
  paths_file="$(mktemp)"
  metadata_file="$(mktemp)"
  jq '[keys[] | split(".") | .[2:]]' <<<"$results" >"$paths_file"
  system="$(jq -r 'keys[0] | split(".")[1]' <<<"$results")"
  [[ "$system" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    rm -f "$paths_file" "$metadata_file"
    printf '%s' "$results"
    return
  }
  expression="
    let
      flake = builtins.getFlake \"$pinned\";
      pkgs = flake.legacyPackages.$system;
      paths = builtins.fromJSON (builtins.readFile \"$paths_file\");
      get = path: builtins.foldl' (set: name: builtins.getAttr name set) pkgs path;
      licenseName = license:
        if license == null then \"unknown\"
        else license.spdxId or license.shortName or license.fullName or \"unknown\";
      info = path:
        let
          package = get path;
          meta = package.meta or {};
          homepageValue = meta.homepage or null;
          homepage =
            if builtins.isList homepageValue
            then if homepageValue == [] then null else builtins.head homepageValue
            else homepageValue;
          licenseValue = meta.license or null;
          licenses =
            if builtins.isList licenseValue
            then map licenseName licenseValue
            else [ (licenseName licenseValue) ];
          maintainers = map
            (maintainer: maintainer.github or maintainer.name or \"unknown\")
            (meta.maintainers or []);
          provenance = map
            (item: item.shortName or item.fullName or \"unknown\")
            (meta.sourceProvenance or []);
        in {
          package = builtins.concatStringsSep \".\" path;
          inherit homepage licenses maintainers provenance;
        };
    in map info paths
  "
  if run_with_spinner "Loading upstream and maintainer details..." "$metadata_file" \
    nix --extra-experimental-features 'nix-command flakes' eval --impure --json --expr "$expression"; then
    enriched="$(jq -cn --argjson results "$results" --slurpfile metadata "$metadata_file" '
      ($metadata[0] | map({key: .package, value: .}) | from_entries) as $details
      | $results
      | to_entries
      | map(
          (.key | split(".") | .[2:] | join(".")) as $package
          | .value += ($details[$package] // {})
        )
      | from_entries
    ')"
  else
    warn "author metadata could not be loaded; basic search results will still be shown"
    enriched="$results"
  fi
  rm -f "$paths_file" "$metadata_file"
  printf '%s' "$enriched"
}

select_optional_packages() {
  local selected="" query="" pinned results searched="" package results_file result_count author display
  local selection token index=0 valid available_packages=() package_list=() tokens=()
  [[ -t 0 ]] || return 0
  printf '\nOptional Nix packages:\n'
  for package in bat eza jq tmux htop awscli2 terraform kubectl vscode; do
    if ! grep -Fxq "$package" <<<"$MANAGED_PROVIDER_IDS"; then
      available_packages+=("$package")
    fi
  done
  if command -v gum >/dev/null 2>&1; then
    selected="$(printf '%s\n' "${available_packages[@]}" \
      | gum choose --no-limit --ordered --height=12 --show-help \
          --header='↑/↓ move • SPACE select/unselect • ENTER confirm' \
          --cursor-prefix='› ' --selected-prefix='✓ ' --unselected-prefix='○ ' \
      || true)"
    mapfile -t package_list < <(printf '%s\n' "$selected" | sed '/^$/d')
  else
    for package in "${available_packages[@]}"; do
      printf '  %d) %s\n' "$((++index))" "$package"
    done
    while :; do
      printf 'Select multiple numbers or names separated by commas (example: 1,3,terraform), or Enter to skip: '
      read -r selection
      [[ -n "$selection" ]] || break
      package_list=()
      tokens=()
      read -r -a tokens <<<"${selection//,/ }"
      valid=true
      for token in "${tokens[@]}"; do
        [[ -n "$token" ]] || continue
        if [[ "$token" =~ ^[0-9]+$ ]]; then
          index=$((10#$token - 1))
          if ((index < 0 || index >= ${#available_packages[@]})); then
            warn "optional package number is out of range: $token"
            valid=false
            break
          fi
          package="${available_packages[$index]}"
        elif printf '%s\n' "${available_packages[@]}" | grep -Fxq "$token"; then
          package="$token"
        else
          warn "unknown optional package: $token"
          valid=false
          break
        fi
        printf '%s\n' "${package_list[@]}" | grep -Fxq "$package" || package_list+=("$package")
      done
      "$valid" && break
    done
  fi
  if ((${#package_list[@]} > 0)); then
    selected="$(printf '%s\n' "${package_list[@]}")"
    printf 'Selected optional packages: %s\n' "$(IFS=', '; printf '%s' "${package_list[*]}")"
  fi
  printf 'Search the pinned official Nixpkgs repository? Enter a term or leave blank: '
  read -r query
  if [[ -n "$query" ]]; then
    if pinned="$(pinned_nixpkgs_ref)"; then
      results_file="$(mktemp)"
      if run_with_spinner "Searching pinned Nixpkgs for '$query'..." "$results_file" \
        nix --extra-experimental-features 'nix-command flakes' search "$pinned" "$query" --json; then
        results="$(<"$results_file")"
      else
        results=""
        warn "Nixpkgs search failed; verify network access and try again"
      fi
      rm -f "$results_file"
      if [[ -n "$results" ]] && jq -e 'type == "object"' >/dev/null <<<"$results"; then
        results="$(jq --arg query "${query,,}" '
          to_entries
          | sort_by(
              ((.value.pname // (.key | split(".") | .[-1])) | ascii_downcase) as $name
              | [
                  (if $name == $query then 0 elif ($name | startswith($query)) then 1 else 2 end),
                  ($name | length),
                  $name
                ]
            )
          | from_entries
        ' <<<"$results")"
        result_count="$(jq 'length' <<<"$results")"
        if ((result_count == 0)); then
          printf 'No installable Nixpkgs packages matched %q.\n' "$query"
        else
          printf 'Fetched %s matching package(s) from pinned Nixpkgs.\n' "$result_count"
          if ((result_count > 50)); then
            printf 'Showing the first 50 results; refine the search term for a shorter list.\n'
            results="$(jq 'to_entries | .[:50] | from_entries' <<<"$results")"
          fi
          results="$(enrich_nixpkgs_results "$pinned" "$results")"
          printf 'Official status is not inferred; inspect the upstream URL and Nix maintainers.\n'
          searched="$(jq -r '
              to_entries[]
              | [
                  (.key | split(".") | .[2:] | join(".")),
                  (.value.version // "unknown"),
                  (.value.homepage // "not declared"),
                  (if ((.value.maintainers // []) | length) == 0
                    then "not declared"
                    else (.value.maintainers | if length > 3 then .[:3] + ["+more"] else . end | join(","))
                    end),
                  ((.value.licenses // ["unknown"]) | join(",")),
                  (.value.description // "")
                ]
              | @tsv
            ' <<<"$results" \
            | while IFS=$'\t' read -r package version upstream maintainers license description; do
                if ! grep -Fxq "$package" <<<"$MANAGED_PROVIDER_IDS"; then
                  author="$upstream"
                  if [[ "$author" == http://* || "$author" == https://* ]]; then
                    author="${author#*://}"
                    author="${author%%/*}"
                    if [[ "$author" == github.com && "$upstream" == *github.com/* ]]; then
                      author="${upstream#*github.com/}"
                      author="github:${author%%/*}"
                    fi
                  fi
                  display="$(printf '%-38.38s %-11.11s %-22.22s %-19.19s ' \
                    "$package" "$version" "$author" '🧩 Community')"
                  display+=$'\033[31m🔴 Unverified\033[0m'
                  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$display" "$package" "$version" "$upstream" "$maintainers" \
                    "community" "unverified" "unknown" "$license" "$description"
                fi
              done \
            | fzf --multi --ansi --delimiter=$'\t' --with-nth=1 \
                --bind='space:toggle,tab:toggle+down,shift-tab:toggle+up' \
                --marker='✓ ' --pointer='›' --info=inline-right \
                --header='PACKAGE                                VERSION     UPSTREAM/AUTHOR        PACKAGE TYPE        PUBLISHER' \
                --header-first \
                --preview="bash '$PACKAGE_PREVIEW' {}" --preview-window='down,45%,wrap' \
                --prompt='SPACE/TAB select • ENTER confirm > ' \
            | cut -f2 || true)"
        fi
      fi
    else
      warn "could not resolve the pinned Nixpkgs input; package search was skipped"
    fi
  fi
  mapfile -t package_list < <(printf '%s\n%s\n' "$selected" "$searched" | sed '/^$/d' | sort -u)
  if ((${#package_list[@]} > 0)); then
    add_profile_packages "${package_list[@]}"
    for package in "${package_list[@]}"; do
      if [[ "$package" == vscode ]]; then
        if confirm "Accept the unfree license metadata for vscode?"; then
          add_profile_unfree vscode
        else
          fail "vscode selection requires unfree-package acceptance"
        fi
      fi
    done
  fi
}

show_provider_inventory() {
  local provider command output
  jq -e 'type == "array"' >/dev/null <<<"$EXTENSIONS_JSON" || fail "invalid extension manifest"
  while IFS= read -r provider; do
    jq -e '.schemaVersion == 1 and (.name | type == "string") and (.executable | type == "string")' \
      >/dev/null <<<"$provider" || { warn "ignored an invalid software provider"; continue; }
    jq -e '.capabilities | index("inventory")' >/dev/null <<<"$provider" || continue
    command="$(jq -r '.executable' <<<"$provider")"
    [[ -x "$command" ]] || { warn "provider executable is unavailable: $command"; continue; }
    output="$($command inventory 2>/dev/null || true)"
    if jq -e '.schemaVersion == 1 and (.items | type == "array")' >/dev/null <<<"$output"; then
      MANAGED_PROVIDER_IDS+="$(jq -r '.items[] | select(.installed == true) | .id' <<<"$output")"$'\n'
      jq -r --arg provider "$(jq -r '.name' <<<"$provider")" \
        '.items[]
          | select(.installed == true)
          | "  [\($provider)] \(.name) \(.version // "") — Publisher: \(.publisher // "not declared") \(if .publisherVerified == true then "🟢 Verified" else "🔴 Unverified" end) • \(if .official == true then "🏢 Official" else "🧩 Provider-managed" end)"' \
        <<<"$output"
    else
      warn "provider inventory failed: $(jq -r '.name' <<<"$provider")"
    fi
  done < <(jq -c '.[]' <<<"$EXTENSIONS_JSON")
}

show_profile_packages() {
  local file="$ROOT/nix/$PROFILE/profile.nix"
  printf '\nProfile configuration: %s\n' "$file"
  printf 'Inherited defaults come from %s and are pinned by flake.lock.\n' "$BASE_URL"
  sed -n '/nixPackages/,/];/p' "$file"
  printf 'Add future package attribute names to nixPackages in that file.\n'
}

scan_dotfiles() {
  local candidate relative answer target bundled
  [[ -t 0 ]] || return 0
  printf '\nHomeWeave can adopt selected existing configurations.\n'
  mkdir -p "$ROOT/.state" "$ROOT/dotfiles/custom"
  : >"$ROOT/.state/adoptions"
  for candidate in \
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.gitconfig" \
    "$HOME/.config"/* "$HOME/.configs"/*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    [[ "$candidate" != "$ROOT"* ]] || continue
    if [[ -L "$candidate" ]]; then
      case "$(realpath "$candidate" 2>/dev/null || true)" in
        "$HOME"/*) ;;
        *) warn "skipping symlink outside the home directory: $candidate"; continue ;;
      esac
    fi
    case "$candidate" in
      */.aws|*/.gnupg|*/.ssh|*/credentials|*/secrets|*/Caches|*/cache) continue ;;
    esac
    relative="${candidate#"$HOME"/}"
    [[ "$relative" != "$candidate" ]] || continue
    printf '\nConfiguration: ~/%s\n' "$relative"
    bundled=""
    if [[ -n "$BUNDLED_DOTFILES" && -d "$BUNDLED_DOTFILES" ]]; then
      bundled="$(find "$BUNDLED_DOTFILES" -path "*/$relative" -print -quit 2>/dev/null || true)"
      if [[ -n "$bundled" ]]; then
        diff -ru "$bundled" "$candidate" 2>/dev/null | sed -n '1,120p' || true
      fi
    fi
    if [[ -n "$bundled" ]]; then
      printf '  a) adopt local  h) use HomeWeave  m) merge/local wins  s) skip [s]: '
    else
      printf '  a) adopt local  s) skip [s]: '
    fi
    read -r answer
    case "$answer" in
      a|A|m|M)
        target="$ROOT/dotfiles/custom/$relative"
        mkdir -p "$(dirname "$target")"
        cp -a "$candidate" "$target"
        printf '%s\tadopt\n' "$relative" >>"$ROOT/.state/adoptions"
        ;;
      h|H)
        [[ -n "$bundled" ]] || fail "HomeWeave has no replacement for $relative"
        printf '%s\thome-weave\n' "$relative" >>"$ROOT/.state/adoptions"
        ;;
      *) printf '%s\n' "$relative" >>"$ROOT/.state/skipped-dotfiles" ;;
    esac
  done
}

prepare_adoptions() {
  local manifest="$ROOT/.state/adoptions" relative action source destination backup_root
  [[ -s "$manifest" ]] || return 0
  backup_root="$ROOT/backup/$(date -u +%Y%m%dT%H%M%SZ)/home"
  ADOPTION_BACKUP_ROOT="$backup_root"
  while IFS=$'\t' read -r relative action; do
    [[ -n "$relative" && "$relative" != /* && "/$relative/" != *"/../"* ]] \
      || fail "unsafe adoption path: $relative"
    source="$HOME/$relative"
    [[ -e "$source" || -L "$source" ]] || continue
    destination="$backup_root/$relative"
    mkdir -p "$(dirname "$destination")"
    mv "$source" "$destination"
  done <"$manifest"
}

restore_adoptions() {
  local manifest="$ROOT/.state/adoptions" relative action backup destination
  [[ -n "$ADOPTION_BACKUP_ROOT" && -s "$manifest" ]] || return 0
  while IFS=$'\t' read -r relative action; do
    backup="$ADOPTION_BACKUP_ROOT/$relative"
    [[ -e "$backup" || -L "$backup" ]] || continue
    destination="$HOME/$relative"
    rm -rf "$destination"
    mkdir -p "$(dirname "$destination")"
    mv "$backup" "$destination"
  done <"$manifest"
}

initialize_git() {
  local candidate paths=() message
  "$NO_GIT" && return 0
  require_commands git rsync
  scan_secrets "$ROOT"
  if [[ ! -d "$ROOT/.git" ]]; then
    git -C "$ROOT" init --quiet --initial-branch=main
  fi
  if [[ -z "$REMOTE_URL" && -t 0 ]]; then
    printf 'Private GitHub/GitLab SSH remote URL (optional): '
    read -r REMOTE_URL
  fi
  if [[ -n "$REMOTE_URL" ]]; then
    [[ "$REMOTE_URL" != *$'\n'* ]] || fail "invalid remote URL"
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$ROOT" remote set-url origin "$REMOTE_URL"
    else
      git -C "$ROOT" remote add origin "$REMOTE_URL"
    fi
  fi
  printf 'Git repository initialized at %s. Review files before committing or pushing.\n' "$ROOT"
  if [[ -t 0 ]] && confirm "Create the initial HomeWeave commit?"; then
    for candidate in flake.nix flake.lock home-weave home-weave.json nix dotfiles extensions README.md SECURITY.md setup.sh home.nix overlay.nix .gitignore; do
      [[ -e "$ROOT/$candidate" ]] && paths+=("$candidate")
    done
    git -C "$ROOT" add -- "${paths[@]}"
    git -C "$ROOT" diff --cached --check
    printf 'Commit message [Initialize HomeWeave]: '
    read -r message
    git -C "$ROOT" commit -m "${message:-Initialize HomeWeave}"
    if [[ -n "$REMOTE_URL" ]] && confirm "Push the initial commit to origin?"; then
      git -C "$ROOT" push -u origin main
    fi
  fi
}

run_profile_setup() {
  local mode="$1"
  read_state
  [[ -x "$ROOT/setup.sh" ]] || fail "$ROOT is not a HomeWeave profile"
  if [[ "$mode" == plan ]]; then
    HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      "$ROOT/setup.sh" --profile "$PROFILE" --shell "$PRIMARY_SHELL" --generate-only
  else
    if ! prepare_adoptions; then
      restore_adoptions
      fail "could not stage adopted configurations"
    fi
    if HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      "$ROOT/setup.sh" --profile "$PROFILE" --shell "$PRIMARY_SHELL"; then
      : >"$ROOT/.state/adoptions"
      ADOPTION_BACKUP_ROOT=""
    else
      restore_adoptions
      fail "activation failed; adopted configurations were restored"
    fi
  fi
}

setup_command() {
  local package filtered_packages=()
  require_commands cp date du find git realpath sed
  [[ -d "$TEMPLATE" ]] || fail "profile template is unavailable: $TEMPLATE"
  begin_root_replacement
  trap 'rollback_root_replacement' EXIT ERR INT TERM
  cp -R "$TEMPLATE/." "$ROOT/"
  chmod -R u+rwX "$ROOT"
  if [[ -n "$PROFILE_OVERLAY" ]]; then
    [[ -d "$PROFILE_OVERLAY" ]] || fail "profile overlay is unavailable: $PROFILE_OVERLAY"
    cp -R "$PROFILE_OVERLAY/." "$ROOT/"
  fi
  chmod -R u+rwX "$ROOT"
  if [[ "$BASE_URL" != "github:thoughtoinnovate/nix" ]]; then
    [[ "$BASE_URL" != *$'\n'* && "$BASE_URL" != *'|'* && "$BASE_URL" != *'&'* ]] \
      || fail "unsupported distribution URL: $BASE_URL"
    sed "s|github:thoughtoinnovate/nix|$BASE_URL|g" "$ROOT/flake.nix" >"$ROOT/.flake.nix.distribution"
    mv "$ROOT/.flake.nix.distribution" "$ROOT/flake.nix"
  fi
  mkdir -p "$ROOT/.state" "$ROOT/backup"
  choose_profile
  ensure_profile
  choose_shell
  update_profile_shell
  show_provider_inventory
  for package in "${REQUESTED_PACKAGES[@]}"; do
    if grep -Fxq "$package" <<<"$MANAGED_PROVIDER_IDS"; then
      warn "$package is already managed by a registered provider and was omitted from Nix"
    else
      filtered_packages+=("$package")
    fi
  done
  ((${#filtered_packages[@]} == 0)) || add_profile_packages "${filtered_packages[@]}"
  select_optional_packages
  write_state
  show_profile_packages
  scan_dotfiles
  initialize_git
  printf '\nHomeWeave repository created at %s\n' "$ROOT"
  printf 'Repository launcher: %s/home-weave\n' "$ROOT"
  if [[ -z "$APPLY_NOW" && -t 0 ]]; then
    confirm "Build and install HomeWeave now?" && APPLY_NOW=true || APPLY_NOW=false
  fi
  if [[ "$APPLY_NOW" == true ]]; then
    run_profile_setup apply
  else
    printf 'Run: %s/home-weave plan\n' "$ROOT"
    printf 'Then: %s/home-weave apply\n' "$ROOT"
  fi
  commit_root_replacement
  trap - EXIT ERR INT TERM
}

merge_restored_content() {
  local local_root="$1" subtree relative source destination answer
  for subtree in dotfiles nix; do
    [[ -d "$local_root/$subtree" ]] || continue
    while IFS= read -r source; do
      relative="${source#"$local_root"/}"
      destination="$ROOT/$relative"
      if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        mkdir -p "$(dirname "$destination")"
        cp -a "$source" "$destination"
        continue
      fi
      if [[ -f "$source" && -f "$destination" ]] && cmp -s "$source" "$destination"; then
        continue
      fi
      if [[ -L "$source" && -L "$destination" ]] \
        && [[ "$(readlink "$source")" == "$(readlink "$destination")" ]]; then
        continue
      fi
      [[ -t 0 && "$ASSUME_YES" == false ]] \
        || fail "restore merge has a conflict requiring interaction: $relative"
      printf '\nRestore conflict: %s\n' "$relative"
      if [[ -f "$source" && -f "$destination" ]]; then
        diff -u "$destination" "$source" | sed -n '1,160p' || true
      fi
      printf 'Choose: l) keep local  r) keep restored  s) skip [s]: '
      read -r answer
      case "$answer" in
        l|L)
          rm -rf "$destination"
          mkdir -p "$(dirname "$destination")"
          cp -a "$source" "$destination"
          ;;
        r|R|s|S|"") ;;
        *) fail "invalid merge choice" ;;
      esac
    done < <(find "$local_root/$subtree" -mindepth 1 \( -type f -o -type l \) -print)
  done
}

restore_command() {
  local url="${POSITIONAL_ARGS[0]:-}" staging old_copy link resolved schema repository
  require_commands git nix realpath rsync
  if [[ -z "$url" && -t 0 ]]; then printf 'Git repository URL: '; read -r url; fi
  [[ -n "$url" && "$url" != *$'\n'* ]] || fail "restore requires a Git URL"
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"; rollback_root_replacement' EXIT
  git clone --quiet "$url" "$staging/repository" \
    || fail "could not clone the HomeWeave repository; verify authentication"
  [[ -f "$staging/repository/flake.nix" && -x "$staging/repository/setup.sh" ]] \
    || fail "remote is not a HomeWeave repository"
  repository="$(realpath "$staging/repository")"
  scan_secrets "$repository"
  while IFS= read -r link; do
    resolved="$(realpath "$link" 2>/dev/null || true)"
    case "$resolved" in "$repository"/*) ;; *) fail "restore contains an unsafe symlink: $link" ;; esac
  done < <(find "$repository" -type l -print)
  schema="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$repository#lib.setup.schemaVersion" 2>/dev/null || true)"
  [[ "$schema" == 1 || "$schema" == 2 ]] || fail "remote has an unsupported HomeWeave schema"
  RESTORE_MODE="${RESTORE_MODE:-override}"
  if [[ "$RESTORE_MODE" == merge && -d "$ROOT" ]]; then
    old_copy="$staging/local"
    cp -R "$ROOT" "$old_copy"
  else
    old_copy=""
  fi
  begin_root_replacement
  trap 'rm -rf "$staging"; rollback_root_replacement' ERR INT TERM
  rm -rf "$ROOT"
  mv "$staging/repository" "$ROOT"
  if [[ -n "$old_copy" ]]; then
    merge_restored_content "$old_copy"
  fi
  printf 'Restored HomeWeave into %s (%s mode).\n' "$ROOT" "$RESTORE_MODE"
  if [[ "$APPLY_NOW" == true ]] || { [[ -z "$APPLY_NOW" ]] && confirm "Build and install restored configuration now?"; }; then
    run_profile_setup apply
  fi
  commit_root_replacement
  trap - ERR INT TERM EXIT
  rm -rf "$staging"
}

sync_command() {
  local branch upstream answer message candidate paths=()
  require_commands git rsync
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  [[ -d "$ROOT/.git" ]] || fail "$ROOT is not a Git repository"
  scan_secrets "$ROOT"
  git -C "$ROOT" status --short
  git -C "$ROOT" diff --stat
  branch="$(git -C "$ROOT" branch --show-current)"
  [[ -n "$branch" ]] || fail "sync requires a branch checkout"
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    if confirm "Commit the displayed local changes?"; then
      scan_secrets "$ROOT"
      printf 'Commit message [Update HomeWeave configuration]: '
      read -r message
      message="${message:-Update HomeWeave configuration}"
      for candidate in flake.nix flake.lock home-weave.json nix dotfiles extensions; do
        [[ -e "$ROOT/$candidate" ]] && paths+=("$candidate")
      done
      git -C "$ROOT" add -- "${paths[@]}"
      git -C "$ROOT" diff --cached --check
      git -C "$ROOT" commit -m "$message"
    else
      fail "sync stopped with uncommitted changes"
    fi
  fi
  git -C "$ROOT" fetch origin
  upstream="$(git -C "$ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    confirm "Push $branch and set its upstream?" && git -C "$ROOT" push -u origin "$branch"
    return
  fi
  git -C "$ROOT" log --oneline --left-right --graph "$upstream...HEAD" || true
  local behind ahead
  behind="$(git -C "$ROOT" rev-list --count "HEAD..$upstream")"
  ahead="$(git -C "$ROOT" rev-list --count "$upstream..HEAD")"
  if ((behind > 0 && ahead == 0)); then
    confirm "Rebase onto $upstream?" && git -C "$ROOT" pull --rebase
  elif ((ahead > 0 && behind == 0)); then
    confirm "Push $ahead local commit(s)?" && git -C "$ROOT" push
  elif ((ahead > 0 && behind > 0)); then
    printf 'Histories diverged: %s ahead, %s behind.\n' "$ahead" "$behind"
    printf 'Choose: r) rebase  l) keep local with force-with-lease  o) use remote  a) abort [a]: '
    read -r answer
    case "$answer" in
      r|R) git -C "$ROOT" pull --rebase ;;
      l|L)
        snapshot_configuration force-push
        git -C "$ROOT" branch "home-weave-remote-backup-$TIMESTAMP" "$upstream"
        git -C "$ROOT" push --force-with-lease
        ;;
      o|O)
        snapshot_configuration remote-reset
        git -C "$ROOT" branch "home-weave-backup-$(date -u +%Y%m%dT%H%M%SZ)" HEAD
        git -C "$ROOT" reset --hard "$upstream"
        ;;
      *) printf 'Sync aborted.\n' ;;
    esac
  else
    printf 'HomeWeave is already synchronized.\n'
  fi
}

update_command() {
  require_commands nix
  [[ -f "$ROOT/flake.nix" ]] || fail "$ROOT is not a HomeWeave repository"
  nix --extra-experimental-features 'nix-command flakes' flake update --flake "$ROOT"
  printf 'Inputs updated. Review %s/flake.lock, then run home-weave plan.\n' "$ROOT"
}

provider_command() {
  local action="${POSITIONAL_ARGS[0]:-list}" provider_name="${POSITIONAL_ARGS[1]:-}" provider command capabilities
  require_commands jq
  jq -e 'type == "array"' >/dev/null <<<"$EXTENSIONS_JSON" || fail "invalid extension manifest"
  if [[ "$action" == list ]]; then
    jq -r '.[] | "\(.name)\t\(.capabilities | join(","))"' <<<"$EXTENSIONS_JSON"
    return
  fi
  [[ -n "$provider_name" ]] || fail "provider $action requires a provider name"
  provider="$(jq -c --arg name "$provider_name" '.[] | select(.name == $name)' <<<"$EXTENSIONS_JSON")"
  [[ -n "$provider" ]] || fail "unknown provider: $provider_name"
  jq -e '.schemaVersion == 1' >/dev/null <<<"$provider" || fail "unsupported provider schema"
  command="$(jq -r '.executable' <<<"$provider")"
  capabilities="$(jq -r '.capabilities[]' <<<"$provider")"
  grep -Fxq "$action" <<<"$capabilities" || fail "$provider_name does not support $action"
  [[ -x "$command" ]] || fail "provider executable is unavailable: $command"
  if [[ "$action" == install || "$action" == update || "$action" == remove ]]; then
    "$command" plan --action "$action" "${POSITIONAL_ARGS[@]:2}"
    confirm "Allow $provider_name to $action the selected applications?" || fail "provider action declined"
    exec "$command" apply --action "$action" "${POSITIONAL_ARGS[@]:2}"
  else
    exec "$command" "$action" "${POSITIONAL_ARGS[@]:2}"
  fi
}

extension_command() {
  local name="${POSITIONAL_ARGS[0]:-list}" extension command
  require_commands jq
  jq -e 'type == "array"' >/dev/null <<<"$EXTENSIONS_JSON" || fail "invalid extension manifest"
  if [[ "$name" == list ]]; then
    jq -r '.[] | select(.capabilities | index("command")) | .name' <<<"$EXTENSIONS_JSON"
    return
  fi
  extension="$(jq -c --arg name "$name" '.[] | select(.name == $name)' <<<"$EXTENSIONS_JSON")"
  [[ -n "$extension" ]] || fail "unknown extension: $name"
  jq -e '.schemaVersion == 1 and (.capabilities | index("command"))' >/dev/null <<<"$extension" \
    || fail "$name is not a command extension"
  command="$(jq -r '.executable' <<<"$extension")"
  [[ -x "$command" ]] || fail "extension executable is unavailable: $command"
  exec "$command" command "${POSITIONAL_ARGS[@]:1}"
}

POSITIONAL_ARGS=()
parse_common_options "$@"
normalize_root

case "$COMMAND" in
  setup) setup_command ;;
  plan) run_profile_setup plan ;;
  apply) run_profile_setup apply ;;
  update) update_command ;;
  restore) restore_command ;;
  sync) sync_command ;;
  provider) provider_command ;;
  extension) extension_command ;;
  help|--help|-h) usage ;;
  *) fail "unknown command: $COMMAND (run home-weave help)" ;;
esac
