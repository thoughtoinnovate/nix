#!/usr/bin/env bash

set -Eeuo pipefail

# HomeWeave never opts into third-party binary caches. Users may still manage
# daemon-wide trust policy themselves, but every HomeWeave Nix invocation
# requests only the official cache, whose signing key is Nix's built-in default.
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}substituters = https://cache.nixos.org/"

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
REQUESTED_GROUPS=()
MANAGED_PROVIDER_IDS=""
DEFAULT_PACKAGE_IDS=""
REMOTE_URL=""
RESTORE_MODE=""
NO_GIT=false
UNINSTALL_REMOVE_CASKS=false
UNINSTALL_ARCHIVE_ROOT=false
UNINSTALL_KEEP_DOTFILES=false
UNINSTALL_KEEP_HOME_MANAGER=false
UNINSTALL_NO_RESTORE=false
DRY_RUN=false
STATUS_JSON=false
UNINSTALL_ALL=false
UNINSTALL_NUKE=false
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
  home-weave profile list|show|create|diff|switch|delete ...
  home-weave status [--profile NAME] [--json]
  home-weave restore [GIT_URL] [--merge|--override] [--root PATH]
  home-weave sync [--root PATH]
  home-weave uninstall [options]
  home-weave provider list|inventory|search|install|update|remove|status ...
  home-weave extension list|NAME [arguments...]

Setup options:
  --root PATH             User repository (default: ~/.home-weave)
  --profile NAME          base, development, or a custom profile
  --extends NAME          Parent for a new custom profile (default: base)
  --shell NAME[,NAME...]  Shells to install; the first is primary
  --package NAME          Add a Nix package; may be repeated
  --group NAME            Add a package group; may be repeated
  --remote URL            Existing private Git remote
  --apply                 Activate after generating the repository
  --no-apply              Generate only
  --no-git                Do not initialize Git
  --yes                   Confirm safe non-interactive defaults

Profile package groups:
  python, data-jupyter, go, rust, java, web, cloud, desktop

Uninstall options:
  --profile NAME          Switch an active profile to its parent
  --all                   Remove every active HomeWeave effect; keep the root
  --nuke                  Run --all, then delete only the HomeWeave root
  --remove-casks          Remove casks/provider apps recorded as HomeWeave-installed
  --archive-root          Move the repository to a timestamped sibling directory
  --keep-dotfiles         Leave managed Stow links active
  --keep-home-manager     Leave Home Manager packages and generations active
  --no-restore            Do not restore pre-adoption dotfile backups
  --dry-run               Display actions without changing anything

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

LOCK_DIR=""
acquire_operation_lock() {
  local owner=""
  LOCK_DIR="${ROOT}.operation-lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    [[ ! -r "$LOCK_DIR/pid" ]] || owner="$(<"$LOCK_DIR/pid")"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      warn "removing stale HomeWeave operation lock from process $owner"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" || fail "could not acquire operation lock: $LOCK_DIR"
    else
      fail "another HomeWeave operation is using this repository${owner:+ (process $owner)}"
    fi
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  printf '%s\n' "$COMMAND" >"$LOCK_DIR/command"
  trap release_operation_lock EXIT
}

release_operation_lock() {
  [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]] || return 0
  if [[ ! -r "$LOCK_DIR/pid" || "$(<"$LOCK_DIR/pid")" == "$$" ]]; then
    rm -rf "$LOCK_DIR"
  fi
  LOCK_DIR=""
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
      --group) [[ $# -ge 2 ]] || fail "--group requires a name"; REQUESTED_GROUPS+=("$2"); shift 2 ;;
      --remote) [[ $# -ge 2 ]] || fail "--remote requires a URL"; REMOTE_URL="$2"; shift 2 ;;
      --apply) APPLY_NOW=true; shift ;;
      --no-apply) APPLY_NOW=false; shift ;;
      --no-git) NO_GIT=true; shift ;;
      --remove-casks) UNINSTALL_REMOVE_CASKS=true; shift ;;
      --archive-root) UNINSTALL_ARCHIVE_ROOT=true; shift ;;
      --keep-dotfiles) UNINSTALL_KEEP_DOTFILES=true; shift ;;
      --keep-home-manager) UNINSTALL_KEEP_HOME_MANAGER=true; shift ;;
      --no-restore) UNINSTALL_NO_RESTORE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --json) STATUS_JSON=true; shift ;;
      --all) UNINSTALL_ALL=true; shift ;;
      --nuke) UNINSTALL_NUKE=true; UNINSTALL_ALL=true; shift ;;
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
  rm -f "$ROOT/.state/selected-profile"
  printf '%s\n' "$PRIMARY_SHELL" >"$ROOT/.state/primary-shell"
}

write_pending_state() {
  mkdir -p "$ROOT/.state"
  printf '%s\n' "$PROFILE" >"$ROOT/.state/selected-profile"
  printf '%s\n' "$PRIMARY_SHELL" >"$ROOT/.state/primary-shell"
}

read_state() {
  [[ -n "$PROFILE" || ! -r "$ROOT/.state/active-profile" ]] \
    || PROFILE="$(<"$ROOT/.state/active-profile")"
  [[ -n "$PROFILE" || ! -r "$ROOT/.state/selected-profile" ]] \
    || PROFILE="$(<"$ROOT/.state/selected-profile")"
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
  packageGroups = [ ];
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
  packageGroups = [ ];
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

add_profile_groups() {
  local file="$ROOT/nix/$PROFILE/profile.nix" temporary group group_values=""
  for group in "$@"; do
    case "$group" in
      python|data-jupyter|go|rust|java|web|cloud|desktop) ;;
      *) fail "unknown package group: $group" ;;
    esac
    group_values+=" \"$group\""
  done
  [[ -n "$group_values" ]] || return 0
  temporary="$file.tmp.$$"
  sed -E "s/packageGroups = \[[^]]*\];/packageGroups = [$group_values ];/" "$file" >"$temporary"
  mv "$temporary" "$file"
}

show_package_groups() {
  local catalog group count packages
  catalog="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "$BASE_URL#lib.packageCatalog.groups" 2>/dev/null || printf '{}')"
  [[ "$(jq -r 'type' <<<"$catalog")" == object ]] || return 0
  printf '\nSelectable package groups (exact download and closure sizes appear in plan):\n'
  while IFS= read -r group; do
    count="$(jq -r --arg group "$group" '.[$group] | length' <<<"$catalog")"
    packages="$(jq -r --arg group "$group" '.[$group] | join(", ")' <<<"$catalog")"
    printf '  %-13s %2s packages  %s\n' "$group" "$count" "$packages"
  done < <(jq -r 'keys[]' <<<"$catalog")
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

load_default_package_ids() {
  local catalog profiles profile_metadata development
  catalog="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "$BASE_URL#lib.packageCatalog" 2>/dev/null || printf '{}')"
  profiles="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profiles" 2>/dev/null || printf '{}')"
  profile_metadata="$(jq -c --arg profile "$PROFILE" '.[$profile] // {}' <<<"$profiles")"
  development="$(jq -r '.development // false' <<<"$profile_metadata")"
  DEFAULT_PACKAGE_IDS="$(jq -rn \
    --argjson catalog "$catalog" \
    --argjson profile "$profile_metadata" \
    --arg development "$development" '
      (
        ($catalog.base // [])
        + (if $development == "true" then ($catalog.development // []) else [] end)
        + (($profile.packageGroups // []) | map($catalog.groups[.] // []) | add // [])
        + ($profile.shells // [])
        + ($profile.nixPackages // [])
      )
      | unique[]
    ')"
}

preview_final_package_selection() {
  local metadata="$1" package details version upstream maintainers author
  shift
  printf '\nFinal package selection:\n'
  printf '%-38s %-12s %-24s %-20s %s\n' \
    'PACKAGE' 'VERSION' 'UPSTREAM/AUTHOR' 'PACKAGE TYPE' 'PUBLISHER'
  printf '%-38s %-12s %-24s %-20s %s\n' \
    '-------' '-------' '---------------' '------------' '---------'
  for package in "$@"; do
    details="$(jq -c --arg package "$package" '.[$package] // {}' <<<"$metadata")"
    version="$(jq -r '.version // "profile default"' <<<"$details")"
    upstream="$(jq -r '.homepage // "Nixpkgs"' <<<"$details")"
    author="$upstream"
    if [[ "$author" == http://* || "$author" == https://* ]]; then
      author="${author#*://}"
      author="${author%%/*}"
      if [[ "$author" == github.com && "$upstream" == *github.com/* ]]; then
        author="${upstream#*github.com/}"
        author="github:${author%%/*}"
      fi
    fi
    printf '%-38.38s %-12.12s %-24.24s %-20.20s \033[31m%s\033[0m\n' \
      "$package" "$version" "$author" '🏢 Official Nixpkgs' '🔴 Unverified upstream'
    maintainers="$(jq -r '(.maintainers // []) | join(", ")' <<<"$details")"
    [[ -z "$maintainers" ]] || printf '  Nix maintainers: %s\n' "$maintainers"
  done
}

select_optional_packages() {
  local selected="" query="" pinned="" results searched="" query_selected package results_file result_count author display
  local search_rows already_included
  local selection_metadata='{}' normalized_metadata selected_count
  local selection token index=0 valid available_packages=() package_list=() tokens=()
  [[ -t 0 ]] || return 0
  load_default_package_ids
  printf '\nOptional Nix packages:\n'
  for package in bat eza jq tmux htop awscli2 terraform kubectl vscode; do
    if ! grep -Fxq "$package" <<<"$MANAGED_PROVIDER_IDS" \
      && ! grep -Fxq "$package" <<<"$DEFAULT_PACKAGE_IDS"; then
      available_packages+=("$package")
    fi
  done
  if grep -Eq '^(kubectl|vscode)$' <<<"$DEFAULT_PACKAGE_IDS"; then
    printf 'Packages already supplied by inherited profiles or selected groups are omitted from this list.\n'
  fi
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
  while :; do
    printf 'Search pinned Nixpkgs (enter another keyword, or leave blank to finish): '
    read -r query
    [[ -n "$query" ]] || break
    if [[ -z "$pinned" ]]; then
      if ! pinned="$(pinned_nixpkgs_ref)"; then
        warn "could not resolve the pinned Nixpkgs input; package search was skipped"
        break
      fi
    fi
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
          normalized_metadata="$(jq -c '
            to_entries
            | map({key: (.key | split(".") | .[2:] | join(".")), value: .value})
            | from_entries
          ' <<<"$results")"
          selection_metadata="$(jq -cn \
            --argjson existing "$selection_metadata" \
            --argjson incoming "$normalized_metadata" \
            '$existing * $incoming')"
          printf 'Repository trust: official NixOS package repository. Upstream publisher identity remains unverified.\n'
          already_included="$(jq -r 'keys[] | split(".") | .[2:] | join(".")' <<<"$results" \
            | while IFS= read -r package; do
                grep -Fxq "$package" <<<"$DEFAULT_PACKAGE_IDS" && printf '%s\n' "$package"
              done)"
          if [[ -n "$already_included" ]]; then
            printf 'Already included by profile %q (not added again): %s\n' \
              "$PROFILE" "$(paste -sd, <<<"$already_included")"
          fi
          search_rows="$(jq -r '
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
                if ! grep -Fxq "$package" <<<"$MANAGED_PROVIDER_IDS" \
                  && ! grep -Fxq "$package" <<<"$DEFAULT_PACKAGE_IDS"; then
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
                    "$package" "$version" "$author" '🏢 Official Nixpkgs')"
                  display+=$'\033[31m🔴 Upstream unverified\033[0m'
                  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$display" "$package" "$version" "$upstream" "$maintainers" \
                    "official NixOS package repository" "unverified" "Nixpkgs" "$license" "$description"
                fi
              done)"
          if [[ -n "$search_rows" ]]; then
            query_selected="$(printf '%s\n' "$search_rows" \
              | fzf --multi --ansi --delimiter=$'\t' --with-nth=1 \
                --bind='space:toggle,tab:toggle+down,shift-tab:toggle+up' \
                --marker='✓ ' --pointer='›' --info=inline-right \
                --header='PACKAGE                                VERSION     UPSTREAM/AUTHOR        PACKAGE TYPE        PUBLISHER' \
                --header-first \
                --preview="bash '$PACKAGE_PREVIEW' {}" --preview-window='down,45%,wrap' \
                --prompt='SPACE/TAB select • ENTER confirm > ' \
              | cut -f2 || true)"
          else
            query_selected=""
          fi
          if [[ -n "$query_selected" ]]; then
            searched+="$query_selected"$'\n'
            selected_count="$(printf '%s\n%s\n' "$selected" "$searched" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
            printf 'Accumulated package selections: %s\n' "$selected_count"
          else
            printf 'No packages were selected for %q. You can search another keyword.\n' "$query"
          fi
        fi
      fi
  done
  mapfile -t package_list < <(printf '%s\n%s\n' "$selected" "$searched" | sed '/^$/d' | sort -u)
  if ((${#package_list[@]} > 0)); then
    preview_final_package_selection "$selection_metadata" "${package_list[@]}"
    if ! confirm "Add all displayed packages to profile '$PROFILE'?"; then
      printf 'Package selections were discarded.\n'
      return 0
    fi
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

load_builtin_provider() {
  if [[ -n "${HOME_WEAVE_NATIVE_PROVIDER:-}" && -x "$HOME_WEAVE_NATIVE_PROVIDER" ]] \
    && ! jq -e 'any(.[]; .name == "native-official")' >/dev/null <<<"$EXTENSIONS_JSON"; then
    EXTENSIONS_JSON="$(jq -cn --argjson extensions "$EXTENSIONS_JSON" --arg executable "$HOME_WEAVE_NATIVE_PROVIDER" '
      $extensions + [{schemaVersion: 1, name: "native-official", executable: $executable,
        capabilities: ["inventory", "search", "install", "update", "remove", "status"]}]')"
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
          | "  [\($provider)] \(.name) \(.version // "") — Repository: \(.repositoryTrust // (if .official == true then "official package repository" else "provider-declared repository" end)) • Publisher: \(.publisher // "not declared") \(if .publisherVerified == true then "🟢 Verified" else "🔴 Unverified" end)"' \
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

profile_metadata() {
  nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profiles"
}

record_receipt() {
  local receipts="$ROOT/.state/receipts" timestamp receipt temporary previous profiles system revision
  local inventory='[]' preflight='{}' dotfiles='[]' casks='[]' providers='[]' parent_chain='[]' cursor parent
  local current_generation previous_generation changes
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  receipt="$receipts/${timestamp//:/-}.json"
  temporary="$receipt.tmp.$$"
  mkdir -p "$receipts"
  profiles="$(profile_metadata)"
  system="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --impure --raw --expr builtins.currentSystem)"
  if [[ "$system" == x86_64-darwin ]]; then
    revision="$(jq -r '.nodes["nixpkgs-x86-darwin"].locked.rev // "unknown"' "$ROOT/flake.lock" 2>/dev/null || printf unknown)"
  else
    revision="$(jq -r '.nodes.nixpkgs.locked.rev // "unknown"' "$ROOT/flake.lock" 2>/dev/null || printf unknown)"
  fi
  inventory="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT/.state/generated#homeWeaveInventory.$system" 2>/dev/null || printf '[]')"
  [[ ! -r "$ROOT/.state/last-preflight.json" ]] || preflight="$(<"$ROOT/.state/last-preflight.json")"
  if [[ -d "$ROOT/.state/dotfiles/current" ]]; then
    dotfiles="$(find "$ROOT/.state/dotfiles/current" -mindepth 1 \( -type f -o -type l \) -print \
      | sed "s|^$ROOT/.state/dotfiles/current/||" \
      | jq -Rsc --arg home "$HOME" --arg source "$ROOT/.state/dotfiles/current" \
        'split("\n") | map(select(length > 0) | {destination: ($home + "/" + .), source: ($source + "/" + .), sourceLayer: "composed"})')"
  fi
  if [[ -s "$ROOT/.state/installed-casks" ]]; then
    casks="$(jq -Rsc 'split("\n") | map(select(length > 0) | {id: ., provider: "homebrew", repositoryTrust: "official Homebrew repository"})' \
      <"$ROOT/.state/installed-casks")"
  fi
  if [[ -s "$ROOT/.state/provider-installations.tsv" ]]; then
    providers="$(jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") |
      {provider: .[0], id: .[1], repositoryTrust: "provider-declared official repository"})' \
      <"$ROOT/.state/provider-installations.tsv")"
  fi
  cursor="$PROFILE"
  while :; do
    parent="$(jq -r --arg profile "$cursor" '.[$profile].extends // empty' <<<"$profiles")"
    [[ -n "$parent" ]] || break
    parent_chain="$(jq -cn --argjson chain "$parent_chain" --arg parent "$parent" '$chain + [$parent]')"
    cursor="$parent"
  done
  current_generation="$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" 2>/dev/null || true)"
  previous_generation="$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager-1-link" 2>/dev/null || true)"
  previous=""
  [[ ! -L "$receipts/latest" ]] || previous="$(readlink -f "$receipts/latest" 2>/dev/null || true)"
  changes="$(jq -cn \
    --argjson packages "$inventory" --argjson dotfiles "$dotfiles" \
    --slurpfile old "${previous:-/dev/null}" '
      ($old[0] // {packages: [], dotfiles: []}) as $previous
      | ($packages | map(.name)) as $newPackages
      | ($previous.packages | map(.name)) as $oldPackages
      | ($dotfiles | map(.destination)) as $newDots
      | ($previous.dotfiles | map(.destination)) as $oldDots
      | {
          added: (($newPackages - $oldPackages) + ($newDots - $oldDots)),
          removed: (($oldPackages - $newPackages) + ($oldDots - $newDots)),
          retained: (($newPackages - ($newPackages - $oldPackages)) + ($newDots - ($newDots - $oldDots))),
          changed: [ $packages[] as $new | $previous.packages[]? | select(.name == $new.name and (.storePath != $new.storePath)) | $new.name ]
        }')"
  jq -n \
    --arg timestamp "$timestamp" --arg profile "$PROFILE" --argjson parentChain "$parent_chain" \
    --arg system "$system" --arg shell "$PRIMARY_SHELL" --arg revision "$revision" \
    --argjson packages "$inventory" --argjson preflight "$preflight" \
    --argjson casks "$casks" --argjson providers "$providers" --argjson dotfiles "$dotfiles" --argjson changes "$changes" \
    --arg currentGeneration "$current_generation" --arg previousGeneration "$previous_generation" \
    '{schemaVersion: 1, timestamp: $timestamp, activeProfile: $profile,
      parentChain: $parentChain, system: $system, shell: $shell, nixpkgsRevision: $revision,
      packages: $packages, build: $preflight,
      applications: {homebrew: $casks, native: [], providers: $providers}, dotfiles: $dotfiles,
      changes: $changes,
      rollback: {currentHomeManagerGeneration: $currentGeneration,
        previousHomeManagerGeneration: $previousGeneration, previousStowGeneration: "dotfiles/current.previous"}}' \
    >"$temporary"
  mv "$temporary" "$receipt"
  ln -sfn "$(basename "$receipt")" "$receipts/latest"
  printf 'Activation receipt: %s\n' "$receipt"
  jq -r '
    "Installed packages:",
    (.packages[] | "  \(.name) \(.version) [\(.group // "profile")] \(.storePath) — \(.source)"),
    "Managed applications:",
    (.applications[] | .[] | "  \(.provider // "native"): \(.id // .name)"),
    "Managed dotfiles:",
    (.dotfiles[] | "  \(.destination) <- \(.source) [\(.sourceLayer)]"),
    "Changes: +\(.changes.added | length) -\(.changes.removed | length) ~\(.changes.changed | length) retained \(.changes.retained | length)",
    "Rollback Home Manager generation: \(.rollback.previousHomeManagerGeneration // "none")"' "$receipt"
}

status_command() {
  local receipt="" candidate
  if [[ -n "$PROFILE" ]]; then
    validate_name "$PROFILE"
    while IFS= read -r candidate; do
      if [[ "$(jq -r '.activeProfile' "$candidate")" == "$PROFILE" ]]; then receipt="$candidate"; break; fi
    done < <(find "$ROOT/.state/receipts" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort -r)
  elif [[ -L "$ROOT/.state/receipts/latest" ]]; then
    receipt="$(readlink -f "$ROOT/.state/receipts/latest")"
  fi
  if [[ -z "$receipt" || ! -r "$receipt" ]]; then
    if "$STATUS_JSON"; then
      jq -n --arg profile "${PROFILE:-}" '{installed: false, activeProfile: (if $profile == "" then null else $profile end)}'
    else
      printf 'HomeWeave has no successful activation receipt%s.\n' "${PROFILE:+ for profile $PROFILE}"
    fi
    return
  fi
  if "$STATUS_JSON"; then cat "$receipt"; return; fi
  jq -r '
    "HomeWeave status",
    "  Active profile: \(.activeProfile)",
    "  Parent chain:   \(.parentChain | if length == 0 then "none" else join(" -> ") end)",
    "  System:         \(.system)",
    "  Shell:          \(.shell)",
    "  Applied:        \(.timestamp)",
    "  Nixpkgs:        \(.nixpkgsRevision)",
    "  Packages:       \(.packages | length)",
    "  Managed apps:   \([.applications[] | length] | add)",
    "  Managed files:  \(.dotfiles | length)",
    "  Changes:        +\(.changes.added | length) -\(.changes.removed | length) ~\(.changes.changed | length) =\(.changes.retained | length)",
    "  Rollback:       \(.rollback.previousHomeManagerGeneration // "none")"' "$receipt"
}

profile_command() {
  local action="${POSITIONAL_ARGS[0]:-list}" name="${POSITIONAL_ARGS[1]:-}" profiles active parent children file
  local current_json target_json field catalog old_packages new_packages
  [[ -f "$ROOT/flake.nix" ]] || fail "$ROOT is not a HomeWeave repository"
  profiles="$(profile_metadata)"
  active=""
  [[ ! -r "$ROOT/.state/active-profile" ]] || active="$(<"$ROOT/.state/active-profile")"
  case "$action" in
    list)
      jq -r --arg active "$active" 'to_entries[] | (if .key == $active then "* " else "  " end) + .key + (if .value.extends == null then "" else " (extends " + .value.extends + ")" end)' <<<"$profiles"
      ;;
    show)
      [[ -n "$name" ]] || fail "profile show requires a name"; validate_name "$name"
      jq -e --arg name "$name" '.[$name]' <<<"$profiles" || fail "profile does not exist: $name"
      ;;
    create)
      [[ -n "$name" ]] || fail "profile create requires a name"; validate_name "$name"; validate_name "$EXTENDS"
      [[ -z "$(jq -r --arg name "$name" '.[$name] // empty' <<<"$profiles")" ]] || fail "profile already exists: $name"
      [[ -n "$(jq -r --arg name "$EXTENDS" '.[$name] // empty' <<<"$profiles")" ]] || fail "parent profile does not exist: $EXTENDS"
      mkdir -p "$ROOT/nix/$name"
      file="$ROOT/nix/$name/profile.nix"
      {
        printf '{\n  extends = "%s";\n' "$EXTENDS"
        printf '  shells = [ "zsh" ];\n  primaryShell = "zsh";\n'
        printf '  packageGroups = [ ];\n  nixPackages = [ ];\n  homebrewCasks = [ ];\n  allowUnfree = [ ];\n}\n'
      } >"$file"
      printf 'Created profile %s extending %s.\n' "$name" "$EXTENDS"
      ;;
    diff)
      [[ -n "$name" ]] || fail "profile diff requires a name"; validate_name "$name"
      target_json="$(jq -ce --arg name "$name" '.[$name]' <<<"$profiles")" || fail "profile does not exist: $name"
      current_json="$(jq -c --arg name "${active:-base}" '.[$name] // {}' <<<"$profiles")"
      printf 'Profile diff: %s -> %s\n' "${active:-none}" "$name"
      catalog="$(nix --extra-experimental-features 'nix-command flakes' eval --json "$BASE_URL#lib.packageCatalog")"
      old_packages="$(jq -cn --argjson profile "$current_json" --argjson catalog "$catalog" '
        (($catalog.base // []) + (if ($profile.development // false) then ($catalog.development // []) else [] end)
          + (($profile.packageGroups // []) | map($catalog.groups[.] // []) | add // [])
          + ($profile.shells // []) + ($profile.nixPackages // [])) | unique')"
      new_packages="$(jq -cn --argjson profile "$target_json" --argjson catalog "$catalog" '
        (($catalog.base // []) + (if ($profile.development // false) then ($catalog.development // []) else [] end)
          + (($profile.packageGroups // []) | map($catalog.groups[.] // []) | add // [])
          + ($profile.shells // []) + ($profile.nixPackages // [])) | unique')"
      printf '\npackages:\n'
      jq -nr --argjson old "$old_packages" --argjson new "$new_packages" \
        '(($new - $old)[] | "+ " + .), (($old - $new)[] | "- " + .)' || true
      for field in packageGroups homebrewCasks allowUnfree shells; do
        printf '\n%s:\n' "$field"
        jq -nr --argjson old "$current_json" --argjson new "$target_json" --arg field "$field" '
          (((($new[$field] // []) - ($old[$field] // []))[]) | "+ " + .),
          (((($old[$field] // []) - ($new[$field] // []))[]) | "- " + .)' || true
      done
      printf '\nProviders: no profile-specific provider changes\nDotfiles: layers are reconciled during switch\n'
      ;;
    switch)
      [[ -n "$name" ]] || fail "profile switch requires a name"; validate_name "$name"
      jq -e --arg name "$name" 'has($name)' >/dev/null <<<"$profiles" || fail "profile does not exist: $name"
      PROFILE="$name"
      run_profile_setup plan
      confirm "Activate profile '$name' after this plan?" || fail "profile switch cancelled"
      run_profile_setup apply
      ;;
    delete)
      [[ -n "$name" ]] || fail "profile delete requires a name"; validate_name "$name"
      [[ "$name" != base && "$name" != development ]] || fail "built-in profile $name cannot be deleted"
      parent="$(jq -r --arg name "$name" '.[$name].extends // empty' <<<"$profiles")"
      [[ -n "$parent" ]] || fail "profile does not exist: $name"
      [[ "$active" != "$name" ]] || fail "active profile $name must first be switched to its parent: $parent"
      children="$(jq -r --arg name "$name" 'to_entries[] | select(.value.extends == $name) | .key' <<<"$profiles")"
      [[ -z "$children" ]] || fail "profile $name still has child profiles: $(paste -sd, <<<"$children")"
      if "$DRY_RUN"; then printf 'Would delete profile definition %s.\n' "$name"; else rm -rf "$ROOT/nix/$name"; fi
      ;;
    *) fail "unknown profile command: $action" ;;
  esac
}

run_profile_setup() {
  local mode="$1" profiles selected_shell setup_args=()
  read_state
  [[ -f "$ROOT/setup.sh" ]] || fail "$ROOT is not a HomeWeave profile"
  profiles="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profiles" 2>/dev/null || printf '{}')"
  selected_shell="$(jq -r --arg profile "$PROFILE" '.[$profile].primaryShell // empty' <<<"$profiles")"
  [[ -z "$selected_shell" ]] || PRIMARY_SHELL="$selected_shell"
  "$ASSUME_YES" && setup_args+=(--yes)
  if [[ "$mode" == plan ]]; then
    HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      bash "$ROOT/setup.sh" --profile "$PROFILE" --shell "$PRIMARY_SHELL" --generate-only "${setup_args[@]}"
  else
    if ! prepare_adoptions; then
      restore_adoptions
      fail "could not stage adopted configurations"
    fi
    if HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      bash "$ROOT/setup.sh" --profile "$PROFILE" --shell "$PRIMARY_SHELL" "${setup_args[@]}"; then
      : >"$ROOT/.state/adoptions"
      date -u +%Y%m%dT%H%M%SZ >"$ROOT/.state/applied"
      write_state
      record_receipt
      printf 'Active HomeWeave profile: %s\n' "$PROFILE"
      ADOPTION_BACKUP_ROOT=""
    else
      restore_adoptions
      fail "activation failed; adopted configurations were restored"
    fi
  fi
}

uninstall_dotfiles() {
  local stow_root="$ROOT/.state/dotfiles" current="$ROOT/.state/dotfiles/current"
  local backup
  backup="$ROOT/backup/$(date -u +%Y%m%dT%H%M%SZ)-uninstalled-dotfiles"
  [[ -d "$current" ]] || { printf 'No active HomeWeave dotfile generation was found.\n'; return; }
  require_commands stow
  stow --simulate --delete --no-folding --dir="$stow_root" --target="$HOME" current \
    || fail "could not preflight dotfile unlinking"
  "$DRY_RUN" && return 0
  stow --delete --no-folding --dir="$stow_root" --target="$HOME" current \
    || fail "could not unlink the active HomeWeave dotfiles"
  mkdir -p "$(dirname "$backup")"
  mv "$current" "$backup"
  printf 'Unlinked HomeWeave dotfiles; generation saved at %s.\n' "$backup"
}

restore_adopted_backups() {
  local home_backup restored=false
  [[ -d "$ROOT/backup" ]] || return 0
  require_commands rsync
  while IFS= read -r home_backup; do
    if "$DRY_RUN"; then
      printf 'Would restore missing files from %s.\n' "$home_backup"
    else
      rsync -a --ignore-existing "$home_backup/" "$HOME/"
      restored=true
    fi
  done < <(find "$ROOT/backup" -mindepth 2 -maxdepth 2 -type d -name home -print | sort -r)
  if "$restored"; then
    printf 'Restored available pre-adoption files without overwriting current files.\n'
  fi
  return 0
}

uninstall_home_manager() {
  local generated="$ROOT/.state/generated"
  [[ -f "$ROOT/.state/applied" ]] || {
    printf 'No HomeWeave activation marker was found; Home Manager uninstall was skipped.\n'
    return
  }
  [[ -f "$generated/flake.nix" ]] || fail "generated Home Manager configuration is missing"
  printf 'Home Manager will remove its managed packages, files, and generations.\n'
  "$DRY_RUN" && return 0
  printf 'y\n' | nix --extra-experimental-features 'nix-command flakes' \
    run "$generated#home-manager" -- uninstall
  rm -f "$ROOT/.state/applied"
  printf 'Home Manager environment removed. Nix itself was not removed.\n'
}

uninstall_recorded_casks() {
  local record="$ROOT/.state/installed-casks" cask
  [[ -s "$record" ]] || { printf 'No HomeWeave-installed Homebrew casks were recorded.\n'; return; }
  command -v brew >/dev/null 2>&1 || { warn "Homebrew is unavailable; recorded casks were left installed"; return; }
  while IFS= read -r cask; do
    [[ "$cask" =~ ^[a-zA-Z0-9@+._-]+$ ]] || fail "unsafe recorded cask name: $cask"
    if "$DRY_RUN"; then
      printf 'Would uninstall Homebrew cask: %s\n' "$cask"
    elif brew list --cask "$cask" >/dev/null 2>&1; then
      brew uninstall --cask "$cask"
    fi
  done <"$record"
  "$DRY_RUN" || rm -f "$record"
}

uninstall_recorded_providers() {
  local record="$ROOT/.state/provider-installations.tsv" provider_name id provider command
  [[ -s "$record" ]] || return 0
  load_builtin_provider
  while IFS=$'\t' read -r provider_name id; do
    provider="$(jq -c --arg name "$provider_name" '.[] | select(.name == $name)' <<<"$EXTENSIONS_JSON")"
    if [[ -z "$provider" ]]; then warn "provider $provider_name is unavailable; recorded application $id was retained"; continue; fi
    command="$(jq -r '.executable' <<<"$provider")"
    if "$DRY_RUN"; then
      "$command" plan --action remove "$id"
    else
      "$command" plan --action remove "$id"
      "$command" apply --action remove "$id"
    fi
  done <"$record"
  "$DRY_RUN" || rm -f "$record"
}

uninstall_command() {
  local archive active parent confirmation profiles
  [[ -d "$ROOT" && -f "$ROOT/flake.nix" ]] || fail "$ROOT is not a HomeWeave repository"
  active=""
  [[ ! -r "$ROOT/.state/active-profile" ]] || active="$(<"$ROOT/.state/active-profile")"
  if [[ -n "$PROFILE" && "$UNINSTALL_ALL" == false && "$UNINSTALL_NUKE" == false ]]; then
    validate_name "$PROFILE"
    if [[ "$PROFILE" != "$active" ]]; then
      printf 'Profile %s is inactive; its reusable definition was retained and no machine changes were needed.\n' "$PROFILE"
      return
    fi
    profiles="$(profile_metadata)"
    parent="$(jq -r --arg profile "$PROFILE" '.[$profile].extends // empty' <<<"$profiles")"
    [[ -n "$parent" ]] || fail "active profile $PROFILE has no parent; use uninstall --all instead"
    if "$DRY_RUN"; then
      printf 'Would plan and switch active profile %s to its parent %s; the profile definition would be retained.\n' "$PROFILE" "$parent"
      return
    fi
    PROFILE="$parent"
    run_profile_setup plan
    confirm "Switch active profile to parent '$parent'?" || fail "profile uninstall cancelled"
    run_profile_setup apply
    return
  fi
  if [[ ! -t 0 && "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
    fail "non-interactive uninstall requires --yes or --dry-run"
  fi
  printf 'HomeWeave uninstall target: %s\n' "$ROOT"
  printf 'Nix itself and unrelated Homebrew packages will not be removed.\n'
  if "$UNINSTALL_ALL" || "$ASSUME_YES"; then
    UNINSTALL_REMOVE_CASKS=true
  fi
  if [[ -t 0 && "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
    confirm "Remove the Home Manager environment?" || UNINSTALL_KEEP_HOME_MANAGER=true
    confirm "Unlink HomeWeave-managed dotfiles?" || UNINSTALL_KEEP_DOTFILES=true
    confirm "Restore available pre-adoption dotfiles?" || UNINSTALL_NO_RESTORE=true
    confirm "Remove casks and provider applications recorded as installed by HomeWeave?" && UNINSTALL_REMOVE_CASKS=true
    confirm "Archive the HomeWeave repository after uninstall?" && UNINSTALL_ARCHIVE_ROOT=true
    confirm "Proceed with the displayed uninstall choices?" || fail "uninstall cancelled"
  fi
  "$UNINSTALL_KEEP_HOME_MANAGER" || uninstall_home_manager
  "$UNINSTALL_KEEP_DOTFILES" || uninstall_dotfiles
  "$UNINSTALL_NO_RESTORE" || restore_adopted_backups
  "$UNINSTALL_REMOVE_CASKS" && uninstall_recorded_casks
  "$UNINSTALL_REMOVE_CASKS" && uninstall_recorded_providers
  "$DRY_RUN" || rm -f "$ROOT/.state/active-profile" "$ROOT/.state/selected-profile"
  if "$UNINSTALL_NUKE"; then
    if "$DRY_RUN"; then
      printf 'Would delete HomeWeave-owned root, state, receipts, backups, generated configurations, and private clones: %s\n' "$ROOT"
      printf 'Would retain Nix and would not run global garbage collection.\n'
      return
    fi
    [[ -t 0 ]] || fail "uninstall --nuke requires an interactive typed confirmation"
    printf 'Type DELETE %s to permanently remove only the HomeWeave root: ' "$ROOT"
    read -r confirmation
    [[ "$confirmation" == "DELETE $ROOT" ]] || fail "nuke confirmation did not match"
    rm -rf "$ROOT"
    printf 'HomeWeave root removed. Nix and the shared store were retained.\n'
    return
  fi
  if "$UNINSTALL_ARCHIVE_ROOT"; then
    archive="${ROOT}.uninstalled.$(date -u +%Y%m%dT%H%M%SZ)"
    if "$DRY_RUN"; then
      printf 'Would archive repository to %s.\n' "$archive"
    else
      mv "$ROOT" "$archive"
      printf 'Repository archived at %s.\n' "$archive"
    fi
  else
    printf 'Repository retained at %s.\n' "$ROOT"
  fi
  printf 'HomeWeave uninstall complete. Nix store cleanup was not run.\n'
}

setup_command() {
  local package group filtered_packages=() group_unfree=()
  require_commands cp date du find git realpath sed
  [[ -d "$TEMPLATE" ]] || fail "profile template is unavailable: $TEMPLATE"
  begin_root_replacement
  trap 'rollback_root_replacement; release_operation_lock' EXIT ERR INT TERM
  cp -R "$TEMPLATE/." "$ROOT/"
  chmod -R u+rwX "$ROOT"
  if [[ -n "$PROFILE_OVERLAY" ]]; then
    [[ -d "$PROFILE_OVERLAY" ]] || fail "profile overlay is unavailable: $PROFILE_OVERLAY"
    cp -R "$PROFILE_OVERLAY/." "$ROOT/"
  fi
  chmod -R u+rwX "$ROOT"
  chmod u+x "$ROOT/home-weave" "$ROOT/setup.sh"
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
  for package in "${REQUESTED_PACKAGES[@]-}"; do
    [[ -n "$package" ]] || continue
    if grep -Fxq "$package" <<<"$MANAGED_PROVIDER_IDS"; then
      warn "$package is already managed by a registered provider and was omitted from Nix"
    else
      filtered_packages+=("$package")
    fi
  done
  [[ -z "${filtered_packages[*]-}" ]] || add_profile_packages "${filtered_packages[@]}"
  [[ ! -t 0 ]] || show_package_groups
  if [[ -n "${REQUESTED_GROUPS[*]-}" ]]; then
    add_profile_groups "${REQUESTED_GROUPS[@]}"
    for group in "${REQUESTED_GROUPS[@]}"; do
      case "$group" in cloud) group_unfree+=(terraform) ;; desktop) group_unfree+=(vscode) ;; esac
    done
    if ((${#group_unfree[@]} > 0)); then
      confirm "Accept the declared unfree licenses required by the selected groups (${group_unfree[*]})?" \
        || fail "selected package groups require explicit unfree-package acceptance"
      add_profile_unfree "${group_unfree[@]}"
    fi
  fi
  select_optional_packages
  write_pending_state
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
  release_operation_lock
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
  trap 'rm -rf "$staging"; rollback_root_replacement; release_operation_lock' EXIT
  git clone --quiet "$url" "$staging/repository" \
    || fail "could not clone the HomeWeave repository; verify authentication"
  [[ -f "$staging/repository/flake.nix" && -f "$staging/repository/setup.sh" ]] \
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
  chmod u+x "$ROOT/home-weave" "$ROOT/setup.sh" 2>/dev/null || true
  if [[ -n "$old_copy" ]]; then
    merge_restored_content "$old_copy"
  fi
  printf 'Restored HomeWeave into %s (%s mode).\n' "$ROOT" "$RESTORE_MODE"
  if [[ "$APPLY_NOW" == true ]] || { [[ -z "$APPLY_NOW" ]] && confirm "Build and install restored configuration now?"; }; then
    run_profile_setup apply
  fi
  commit_root_replacement
  release_operation_lock
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
  local action="${POSITIONAL_ARGS[0]:-list}" provider_name="${POSITIONAL_ARGS[1]:-}" provider command capabilities id record temporary installed_before=""
  require_commands jq
  load_builtin_provider
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
    if [[ "$action" == install ]] && grep -Fxq inventory <<<"$capabilities"; then
      installed_before="$("$command" inventory 2>/dev/null \
        | jq -r '.items[]? | select(.installed == true) | .id' 2>/dev/null || true)"
    fi
    "$command" plan --action "$action" "${POSITIONAL_ARGS[@]:2}"
    confirm "Allow $provider_name to $action the selected applications?" || fail "provider action declined"
    "$command" apply --action "$action" "${POSITIONAL_ARGS[@]:2}"
    record="$ROOT/.state/provider-installations.tsv"
    mkdir -p "$ROOT/.state"
    if [[ "$action" == install ]]; then
      touch "$record"
      for id in "${POSITIONAL_ARGS[@]:2}"; do
        grep -Fxq "$id" <<<"$installed_before" && continue
        grep -Fqx "$provider_name"$'\t'"$id" "$record" || printf '%s\t%s\n' "$provider_name" "$id" >>"$record"
      done
    elif [[ "$action" == remove && -f "$record" ]]; then
      temporary="$record.tmp.$$"
      cp "$record" "$temporary"
      for id in "${POSITIONAL_ARGS[@]:2}"; do
        grep -Fvx "$provider_name"$'\t'"$id" "$temporary" >"$record" || true
        cp "$record" "$temporary"
      done
      rm -f "$temporary"
    fi
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
  setup|apply|update|uninstall) acquire_operation_lock ;;
  profile)
    case "${POSITIONAL_ARGS[0]:-list}" in create|switch|delete) acquire_operation_lock ;; esac
    ;;
esac

case "$COMMAND" in
  setup) setup_command ;;
  plan) run_profile_setup plan ;;
  apply) run_profile_setup apply ;;
  update) update_command ;;
  restore) restore_command ;;
  sync) sync_command ;;
  uninstall) uninstall_command ;;
  profile) profile_command ;;
  status) status_command ;;
  provider) provider_command ;;
  extension) extension_command ;;
  help|--help|-h) usage ;;
  *) fail "unknown command: $COMMAND (run home-weave help)" ;;
esac
