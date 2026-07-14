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
PUBLISHER_REGISTRY="${HOME_WEAVE_PUBLISHER_REGISTRY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/reviewed-publishers.json}"
PUBLISHER_FILTER="${HOME_WEAVE_PUBLISHER_FILTER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/verify-publishers.jq}"
ENV_RENDERER="${HOME_WEAVE_ENV_RENDERER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/home-weave-env.sh}"
CONFIG_SCHEMA="${HOME_WEAVE_CONFIG_SCHEMA:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/schemas/home-weave-v2.schema.json}"
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
LOG_LATEST=false
LOG_TAIL=100
UNINSTALL_ALL=false
UNINSTALL_NUKE=false
TIMESTAMP=""
OLD_ROOT=""
ADOPTION_BACKUP_ROOT=""
ROOT_REPLACEMENT_STARTED=false
OPERATION_LOG=""
OPERATION_PHASE=""
OPERATION_STARTED_AT=""
OPERATION_FINISHED=false
UNINSTALLED_DOTFILE_GENERATION=""

fail() {
  if [[ -n "$OPERATION_LOG" && "$OPERATION_FINISHED" == false ]]; then
    finish_operation_log failed
  fi
  if [[ -n "$OPERATION_LOG" ]]; then
    printf 'error: %s\n' "$*" | tee -a "$OPERATION_LOG" >&2
  else
    printf 'error: %s\n' "$*" >&2
  fi
  if [[ -n "$OPERATION_LOG" ]]; then
    {
      printf 'Operation phase: %s\n' "${OPERATION_PHASE:-unknown}"
      printf 'Operation log: %s\n' "$OPERATION_LOG"
    } | tee -a "$OPERATION_LOG" >&2
  fi
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

current_nix_system() {
  local os arch
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) fail "unsupported operating system" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; x86_64) arch=x86_64 ;; *) fail "unsupported architecture" ;; esac
  printf '%s-%s' "$arch" "$os"
}

write_operation_metadata() {
  local status="$1" finished_at="${2:-}" metadata="$ROOT/.state/last-operation.json"
  [[ -n "$OPERATION_LOG" ]] || return 0
  jq -n \
    --arg command "$COMMAND" --arg phase "${OPERATION_PHASE:-starting}" \
    --arg status "$status" --arg startedAt "$OPERATION_STARTED_AT" \
    --arg finishedAt "$finished_at" --arg logPath "$OPERATION_LOG" \
    '{schemaVersion: 1, command: $command, phase: $phase, status: $status,
      startedAt: $startedAt, finishedAt: (if $finishedAt == "" then null else $finishedAt end),
      logPath: $logPath}' >"$metadata.tmp.$$" || return 0
  mv "$metadata.tmp.$$" "$metadata"
}

start_operation_log() {
  local label="${1:-$COMMAND}" logs timestamp old
  [[ -z "$OPERATION_LOG" ]] || return 0
  [[ -d "$ROOT" ]] || return 0
  logs="$ROOT/.state/logs"
  mkdir -p "$logs"
  chmod 700 "$logs" 2>/dev/null || true
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  OPERATION_LOG="$logs/$timestamp-$label-$$.log"
  OPERATION_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OPERATION_PHASE=starting
  : >"$OPERATION_LOG"
  chmod 600 "$OPERATION_LOG"
  ln -sfn "$(basename "$OPERATION_LOG")" "$logs/latest"
  while IFS= read -r old; do
    rm -f "$old"
  done < <(find "$logs" -maxdepth 1 -type f -name '*.log' -print | sort -r | tail -n +21)
  write_operation_metadata running
  printf 'Operation log: %s\n' "$OPERATION_LOG" | tee -a "$OPERATION_LOG"
}

set_operation_phase() {
  OPERATION_PHASE="$1"
  [[ -z "$OPERATION_LOG" ]] || write_operation_metadata running
  if [[ -n "$OPERATION_LOG" ]]; then
    printf 'HomeWeave phase: %s\n' "$OPERATION_PHASE" | tee -a "$OPERATION_LOG"
  else
    printf 'HomeWeave phase: %s\n' "$OPERATION_PHASE"
  fi
}

run_logged() {
  if [[ -z "$OPERATION_LOG" ]]; then
    "$@"
    return
  fi
  set +e
  "$@" 2>&1 | tee -a "$OPERATION_LOG"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

finish_operation_log() {
  local status="$1"
  [[ -n "$OPERATION_LOG" && "$OPERATION_FINISHED" == false ]] || return 0
  write_operation_metadata "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OPERATION_FINISHED=true
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
  home-weave config validate|show [PROFILE] [--root PATH]
  home-weave status [--profile NAME] [--json]
  home-weave logs [--latest] [--tail N]
  home-weave snapshot create [PATH] [--root PATH]
  home-weave snapshot restore PATH [--root PATH] [--apply]
  home-weave restore [GIT_URL] [--merge|--override] [--root PATH]
  home-weave sync [--root PATH]
  home-weave uninstall [all|nuke] [options]
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
      --latest) LOG_LATEST=true; shift ;;
      --tail)
        [[ $# -ge 2 ]] || fail "--tail requires a positive integer"
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "--tail requires a positive integer"
        LOG_TAIL="$2"
        shift 2
        ;;
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

normalize_uninstall_mode() {
  local mode
  ((${#POSITIONAL_ARGS[@]} > 0)) || return 0
  mode="${POSITIONAL_ARGS[0]}"
  case "$mode" in
    all)
      ((${#POSITIONAL_ARGS[@]} == 1)) \
        || fail "uninstall all does not accept additional positional arguments"
      UNINSTALL_ALL=true
      ;;
    nuke)
      ((${#POSITIONAL_ARGS[@]} == 1)) \
        || fail "uninstall nuke does not accept additional positional arguments"
      UNINSTALL_NUKE=true
      UNINSTALL_ALL=true
      ;;
    *)
      fail "unknown uninstall mode: $mode (use uninstall, uninstall all, uninstall nuke, or --profile NAME)"
      ;;
  esac
  POSITIONAL_ARGS=()
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
  ROOT_REPLACEMENT_STARTED=false
  if [[ -e "$ROOT" ]]; then
    [[ -d "$ROOT" ]] || fail "$ROOT exists but is not a directory"
    if find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      printf 'Existing HomeWeave root: %s\n' "$ROOT"
      du -sh "$ROOT" 2>/dev/null || true
      confirm "Back up and replace the entire existing HomeWeave setup?" \
        || fail "existing setup was left unchanged"
      OLD_ROOT="${ROOT}.replacing.${TIMESTAMP}.$$"
      mv "$ROOT" "$OLD_ROOT"
      ROOT_REPLACEMENT_STARTED=true
    else
      rmdir "$ROOT"
      ROOT_REPLACEMENT_STARTED=true
    fi
  fi
  ROOT_REPLACEMENT_STARTED=true
  mkdir -p "$ROOT"
}

rollback_root_replacement() {
  "$ROOT_REPLACEMENT_STARTED" || return 0
  rm -rf "$ROOT"
  if [[ -n "$OLD_ROOT" && -d "$OLD_ROOT" ]]; then
    mv "$OLD_ROOT" "$ROOT"
  fi
  OLD_ROOT=""
  ROOT_REPLACEMENT_STARTED=false
}

commit_root_replacement() {
  local previous_backup
  if [[ -z "$OLD_ROOT" || ! -d "$OLD_ROOT" ]]; then
    ROOT_REPLACEMENT_STARTED=false
    return 0
  fi
  mkdir -p "$ROOT/backup"
  if [[ -d "$OLD_ROOT/backup" ]]; then
    while IFS= read -r previous_backup; do
      mv "$previous_backup" "$ROOT/backup/"
    done < <(find "$OLD_ROOT/backup" -mindepth 1 -maxdepth 1 -print)
    rmdir "$OLD_ROOT/backup" 2>/dev/null || true
  fi
  mv "$OLD_ROOT" "$ROOT/backup/$TIMESTAMP"
  OLD_ROOT=""
  ROOT_REPLACEMENT_STARTED=false
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
  local choice custom parent profiles answer
  local config="$ROOT/home-weave.json"
  [[ -f "$config" ]] || fail "profile configuration is missing: $config"
  if [[ -n "$PROFILE" ]]; then
    validate_name "$PROFILE"
    if jq -e --arg profile "$PROFILE" '.profiles | has($profile)' "$config" >/dev/null \
      && [[ -t 0 && "$ASSUME_YES" == false ]]; then
      printf "Profile '%s' already exists. Use it directly or create a child profile? [use/create] [use]: " "$PROFILE"
      read -r answer
      case "$answer" in
        create|c|C)
          printf 'New profile name: '
          read -r custom
          validate_name "$custom"
          jq -e --arg profile "$custom" '.profiles | has($profile) | not' "$config" >/dev/null \
            || fail "profile already exists: $custom"
          printf 'Extend profile [base] (enter development to inherit development tools): '
          read -r parent
          parent="${parent:-base}"
          validate_name "$parent"
          jq -e --arg profile "$parent" '.profiles | has($profile)' "$config" >/dev/null \
            || fail "parent profile does not exist: $parent"
          PROFILE="$custom"
          EXTENDS="$parent"
          printf "Creating profile '%s' extending '%s'.\n" "$PROFILE" "$EXTENDS"
          ;;
        use|u|U|"")
          printf "Using existing profile '%s'.\n" "$PROFILE"
          ;;
        *) fail "choose 'use' or 'create'" ;;
      esac
    elif ! jq -e --arg profile "$PROFILE" '.profiles | has($profile)' "$config" >/dev/null \
      && [[ -t 0 && "$ASSUME_YES" == false ]]; then
      printf "Creating new profile '%s'. Extend profile [base] (enter development to inherit development tools): " "$PROFILE"
      read -r parent
      parent="${parent:-base}"
      validate_name "$parent"
      jq -e --arg profile "$parent" '.profiles | has($profile)' "$config" >/dev/null \
        || fail "parent profile does not exist: $parent"
      EXTENDS="$parent"
      printf "Creating profile '%s' extending '%s'.\n" "$PROFILE" "$EXTENDS"
    fi
    return
  fi
  if [[ ! -t 0 ]]; then PROFILE=base; return; fi
  profiles="$(jq -r '.profiles | keys[]' "$config")"
  if command -v fzf >/dev/null 2>&1; then
    choice="$(printf '%s\n%s\n' "$profiles" '+ create custom profile' | fzf --prompt='Profile> ' || true)"
  else
    printf 'Available profiles:\n%s\nProfile [base]: ' "$profiles"
    read -r choice
  fi
  case "$choice" in
    '+ create custom profile'|custom)
      printf 'Custom profile name: '; read -r custom; validate_name "$custom"
      printf 'Extend profile [base] (enter development to inherit development tools): '
      read -r parent
      parent="${parent:-base}"
      validate_name "$parent"
      jq -e --arg profile "$parent" '.profiles | has($profile)' "$config" >/dev/null \
        || fail "parent profile does not exist: $parent"
      PROFILE="$custom"
      EXTENDS="$parent"
      ;;
    "") PROFILE=base ;;
    *) validate_name "$choice"; jq -e --arg profile "$choice" '.profiles | has($profile)' "$config" >/dev/null || fail "profile does not exist: $choice"; PROFILE="$choice" ;;
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
  local file="$ROOT/home-weave.json" temporary
  jq -e --arg profile "$PROFILE" '.profiles | has($profile)' "$file" >/dev/null && return 0
  validate_name "$PROFILE"
  validate_name "$EXTENDS"
  jq -e --arg profile "$EXTENDS" '.profiles | has($profile)' "$file" >/dev/null \
    || fail "parent profile does not exist: $EXTENDS"
  temporary="$file.tmp.$$"
  jq --arg profile "$PROFILE" --arg parent "$EXTENDS" \
    '.profiles[$profile] = {extends: $parent, shells: ["zsh"], primaryShell: "zsh", packageGroups: [], dotfiles: [], packages: {nix: []}}' \
    "$file" >"$temporary"
  mv "$temporary" "$file"
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
  local file="$ROOT/home-weave.json" temporary shell shells_json
  [[ -f "$file" ]] || fail "profile is missing: $PROFILE"
  while IFS= read -r shell; do
    case "$shell" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $shell" ;; esac
  done <<<"${SELECTED_SHELLS:-$PRIMARY_SHELL}"
  shells_json="$(printf '%s\n' ${SELECTED_SHELLS:-$PRIMARY_SHELL} | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
  temporary="$file.tmp.$$"
  jq --arg profile "$PROFILE" --arg primary "$PRIMARY_SHELL" --argjson shells "$shells_json" \
    '.profiles[$profile].shells = $shells | .profiles[$profile].primaryShell = $primary' "$file" >"$temporary"
  mv "$temporary" "$file"
}

add_profile_packages() {
  local file="$ROOT/home-weave.json" temporary package packages_json
  for package in "$@"; do
    [[ "$package" =~ ^[a-zA-Z0-9+_-]+([.][a-zA-Z0-9+_-]+)*$ ]] || fail "unsafe Nix package name: $package"
  done
  (($# > 0)) || return 0
  packages_json="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  temporary="$file.tmp.$$"
  jq --arg profile "$PROFILE" --argjson packages "$packages_json" \
    '.profiles[$profile].packages.nix = (((.profiles[$profile].packages.nix // []) + $packages) | unique_by(if type == "string" then . else .name end))' \
    "$file" >"$temporary"
  mv "$temporary" "$file"
}

add_profile_groups() {
  local file="$ROOT/home-weave.json" temporary group groups_json
  for group in "$@"; do
    case "$group" in
      python|data-jupyter|go|rust|java|web|cloud|desktop) ;;
      *) fail "unknown package group: $group" ;;
    esac
  done
  (($# > 0)) || return 0
  groups_json="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  temporary="$file.tmp.$$"
  jq --arg profile "$PROFILE" --argjson groups "$groups_json" \
    '.profiles[$profile].packageGroups = (((.profiles[$profile].packageGroups // []) + $groups) | unique)' \
    "$file" >"$temporary"
  mv "$temporary" "$file"
}

select_package_groups() {
  local catalog group count packages selected selection token index valid line
  local rows=() selected_groups=() tokens=()
  catalog="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "$BASE_URL#lib.packageCatalog.groups" 2>/dev/null || printf '{}')"
  [[ "$(jq -r 'type' <<<"$catalog")" == object ]] || return 0
  printf '\nOptional package groups (exact download and closure sizes appear in plan):\n'
  while IFS= read -r group; do
    count="$(jq -r --arg group "$group" '.[$group] | length' <<<"$catalog")"
    packages="$(jq -r --arg group "$group" '.[$group] | join(", ")' <<<"$catalog")"
    printf '  %-13s %2s packages  %s\n' "$group" "$count" "$packages"
    rows+=("$(printf '%-13s %2s packages  %s' "$group" "$count" "$packages")")
  done < <(jq -r 'keys[]' <<<"$catalog")

  if ((${#REQUESTED_GROUPS[@]} > 0)); then
    printf 'Selected package groups from --group: %s\n' "$(IFS=', '; printf '%s' "${REQUESTED_GROUPS[*]}")"
    return 0
  fi
  [[ -t 0 ]] || return 0

  if command -v gum >/dev/null 2>&1; then
    selected="$(
      {
        printf '%-13s %s\n' skip 'No optional package groups'
        printf '%s\n' "${rows[@]}"
      } | gum choose --no-limit --ordered --height=12 --show-help \
        --header='↑/↓ move • SPACE select/unselect • ENTER confirm • choose skip for none' \
        --cursor-prefix='› ' --selected-prefix='✓ ' --unselected-prefix='○ ' \
        || true
    )"
    while IFS= read -r line; do
      group="${line%%[[:space:]]*}"
      [[ -n "$group" && "$group" != skip ]] || continue
      selected_groups+=("$group")
    done <<<"$selected"
  else
    index=0
    for group in $(jq -r 'keys[]' <<<"$catalog"); do
      printf '  %d) %s\n' "$((++index))" "$group"
    done
    while :; do
      printf 'Select group numbers or names separated by commas, or Enter to skip: '
      read -r selection
      [[ -n "$selection" ]] || break
      selected_groups=()
      tokens=()
      read -r -a tokens <<<"${selection//,/ }"
      valid=true
      for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then
          index=$((10#$token - 1))
          group="$(jq -r --argjson index "$index" 'keys[$index] // empty' <<<"$catalog")"
        else
          group="$token"
        fi
        if [[ -z "$group" ]] || ! jq -e --arg group "$group" 'has($group)' >/dev/null <<<"$catalog"; then
          warn "unknown package group: $token"
          valid=false
          break
        fi
        printf '%s\n' "${selected_groups[@]}" | grep -Fxq "$group" || selected_groups+=("$group")
      done
      "$valid" && break
    done
  fi

  if ((${#selected_groups[@]} == 0)); then
    printf 'No optional package groups selected.\n'
  else
    REQUESTED_GROUPS=("${selected_groups[@]}")
    printf 'Selected package groups: %s\n' "$(IFS=', '; printf '%s' "${REQUESTED_GROUPS[*]}")"
  fi
}

add_profile_unfree() {
  local file="$ROOT/home-weave.json" temporary packages_json
  (($# > 0)) || return 0
  packages_json="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  temporary="$file.tmp.$$"
  jq --arg profile "$PROFILE" --argjson accepted "$packages_json" '
    (.profiles[$profile].packages.nix // []) as $entries
    | ($entries | map(if type == "string" then . else .name end)) as $entryNames
    | .profiles[$profile].packages.nix = ($entries | map(
      if ((if type == "string" then . else .name end) as $name | $accepted | index($name))
      then {name: (if type == "string" then . else .name end), allowUnfree: true}
      else . end))
    | .profiles[$profile].allowUnfree = (((.profiles[$profile].allowUnfree // []) + ($accepted - $entryNames)) | unique)' "$file" >"$temporary"
  mv "$temporary" "$file"
}

detect_unfree_packages() {
  local pinned="$1" paths_file expression package
  shift
  paths_file="$(mktemp)"
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | split("."))' >"$paths_file"
  expression="
    let
      flake = builtins.getFlake \"$pinned\";
      pkgs = import flake.outPath {
        system = builtins.currentSystem;
        config.allowUnfree = true;
      };
      paths = builtins.fromJSON (builtins.readFile \"$paths_file\");
      get = path: builtins.foldl' (set: name: builtins.getAttr name set) pkgs path;
      isFree = license:
        if license == null then true
        else if builtins.isList license then builtins.all isFree license
        else if builtins.isAttrs license then license.free or false
        else false;
      info = path:
        let package = get path; in {
          name = builtins.concatStringsSep \".\" path;
          free = isFree (package.meta.license or null);
        };
    in map info paths
  "
  if nix --extra-experimental-features 'nix-command flakes' eval --impure --json --expr "$expression" 2>/dev/null \
    | jq -r '.[] | select(.free == false) | .name'; then
    rm -f "$paths_file"
  else
    rm -f "$paths_file"
    return 1
  fi
}

accept_unfree_packages() {
  local pinned="$1"
  shift
  local unfree_packages=()
  (($# > 0)) || return 0
  mapfile -t unfree_packages < <(detect_unfree_packages "$pinned" "$@") \
    || fail "could not inspect selected package licenses"
  if ((${#unfree_packages[@]} > 0)); then
    printf 'Unfree license metadata: %s\n' "$(IFS=', '; printf '%s' "${unfree_packages[*]}")"
    confirm "Accept these upstream licenses and record the package allow-list?" \
      || fail "unfree package selection was not accepted"
    add_profile_unfree "${unfree_packages[@]}"
  fi
}

apply_reviewed_upstream_allowlist() {
  [[ -r "$PUBLISHER_REGISTRY" && -r "$PUBLISHER_FILTER" ]] \
    || fail "reviewed publisher verification data is unavailable"
  jq --slurpfile registry "$PUBLISHER_REGISTRY" -f "$PUBLISHER_FILTER"
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
    eval --json "path:$ROOT#lib.setup.profilesBySystem.\"$(current_nix_system)\"" 2>/dev/null || printf '{}')"
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
  local metadata="$1" package details version upstream maintainers author publisher_label
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
    if [[ "$(jq -r '.publisherVerified // false' <<<"$details")" == true ]]; then
      publisher_label="🟢 $(jq -r '.publisher' <<<"$details") verified"
    else
      publisher_label='🔴 Unverified upstream'
    fi
    printf '%-38.38s %-12.12s %-24.24s %-20.20s %s\n' \
      "$package" "$version" "$author" '🏢 Official Nixpkgs' "$publisher_label"
    maintainers="$(jq -r '(.maintainers // []) | join(", ")' <<<"$details")"
    [[ -z "$maintainers" ]] || printf '  Nix maintainers: %s\n' "$maintainers"
    [[ "$(jq -r '.publisherVerified // false' <<<"$details")" != true ]] \
      || printf '  Publisher evidence: %s\n' "$(jq -r '.publisherEvidence' <<<"$details")"
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
          results="$(apply_reviewed_upstream_allowlist <<<"$results")"
          normalized_metadata="$(jq -c '
            to_entries
            | map({key: (.key | split(".") | .[2:] | join(".")), value: .value})
            | from_entries
          ' <<<"$results")"
          selection_metadata="$(jq -cn \
            --argjson existing "$selection_metadata" \
            --argjson incoming "$normalized_metadata" \
            '$existing * $incoming')"
          printf 'Repository trust: official NixOS package repository. Green publishers match HomeWeave-reviewed upstream evidence; all others remain unverified.\n'
          already_included="$(jq -r 'keys[] | split(".") | .[2:] | join(".")' <<<"$results" \
            | while IFS= read -r package; do
                grep -Fxq "$package" <<<"$DEFAULT_PACKAGE_IDS" && printf '%s\n' "$package"
              done || true)"
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
                  publisher="$(jq -r --arg package "$package" '.[$package].publisher // "Upstream"' <<<"$normalized_metadata")"
                  publisher_evidence="$(jq -r --arg package "$package" '.[$package].publisherEvidence // ""' <<<"$normalized_metadata")"
                  if [[ "$(jq -r --arg package "$package" '.[$package].publisherVerified // false' <<<"$normalized_metadata")" == true ]]; then
                    display+="$(printf '\033[32m🟢 %s verified\033[0m' "$publisher")"
                    verification="verified"
                  else
                    display+=$'\033[31m🔴 Upstream unverified\033[0m'
                    verification="unverified"
                  fi
                  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$display" "$package" "$version" "$upstream" "$maintainers" \
                    "official NixOS package repository" "$verification" "true" "$license" "$description" \
                    "$publisher" "$publisher_evidence"
                fi
              done || true)"
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
    if [[ -z "$pinned" ]] && ! pinned="$(pinned_nixpkgs_ref)"; then
      fail "could not verify selected package licenses against pinned Nixpkgs"
    fi
    add_profile_packages "${package_list[@]}"
    accept_unfree_packages "$pinned" "${package_list[@]}"
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

reconcile_profile_providers() {
  local mode="$1" profiles="$2" profile_json provider_packages provider_name provider command removal_policy
  local inventory item refreshed id display_name state ownership status='[]' inventory_only degraded=false native_packages native_selected='[]' os_id
  local pending_file="$ROOT/.state/provider-status.pending.json"
  load_builtin_provider
  profile_json="$(jq -ce --arg profile "$PROFILE" '.[$profile] // empty' <<<"$profiles")" \
    || fail "profile does not exist: $PROFILE"
  provider_packages="$(jq -c '.providerPackages // {}' <<<"$profile_json")"
  native_packages="$(jq -c '.nativePackages // {}' <<<"$profile_json")"
  if [[ "$(uname -s)" == Darwin ]]; then
    native_selected="$(jq -c '.homebrewFormulae // []' <<<"$native_packages")"
  elif [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
    case "$os_id" in
      debian|ubuntu) native_selected="$(jq -c '.apt // []' <<<"$native_packages")" ;;
      arch) native_selected="$(jq -c '.pacman // []' <<<"$native_packages")" ;;
    esac
  fi
  if (($(jq 'length' <<<"$native_selected") > 0)); then
    provider_packages="$(jq -cn --argjson providers "$provider_packages" --argjson native "$native_selected" \
      '$providers + {"native-official": (((($providers["native-official"] // []) + $native) | unique))}')"
  fi
  [[ "$(jq -r 'type' <<<"$provider_packages")" == object ]] \
    || fail "profile $PROFILE has invalid providerPackages metadata"
  (($(jq 'length' <<<"$provider_packages") > 0)) || {
    if [[ "$mode" == apply ]]; then
      mkdir -p "$ROOT/.state"
      jq -n --arg profile "$PROFILE" \
        '{schemaVersion: 1, profile: $profile, complete: true, degraded: false, items: []}' >"$pending_file"
    fi
    return 0
  }

  printf '\nProfile provider plan:\n'
  while IFS= read -r provider_name; do
    provider="$(jq -c --arg name "$provider_name" '.[] | select(.name == $name)' <<<"$EXTENSIONS_JSON")"
    [[ -n "$provider" ]] || fail "profile $PROFILE requires unavailable provider: $provider_name"
    jq -e '.schemaVersion == 1 and (.capabilities | index("inventory")) and (.capabilities | index("install"))' \
      >/dev/null <<<"$provider" || fail "provider $provider_name cannot reconcile profile applications"
    command="$(jq -r '.executable' <<<"$provider")"
    [[ -x "$command" ]] || fail "provider executable is unavailable: $command"
    removal_policy="$(jq -r '.removalPolicy // "remove"' <<<"$provider")"
    [[ "$removal_policy" == remove || "$removal_policy" == retain ]] \
      || fail "provider $provider_name has invalid removalPolicy"
    inventory="$($command inventory)" || fail "provider inventory failed: $provider_name"
    jq -e '.schemaVersion == 1 and (.items | type == "array")' >/dev/null <<<"$inventory" \
      || fail "provider $provider_name returned invalid inventory"

    while IFS= read -r inventory_only; do
      [[ -n "$inventory_only" ]] || continue
      status="$(jq -cn --argjson items "$status" --argjson item "$inventory_only" \
        --arg provider "$provider_name" --arg removalPolicy "$removal_policy" '
          $items + [($item + {provider: $provider, requested: false, state: "inventory-only",
            ownership: "provider", removalPolicy: $removalPolicy})]
        ')"
    done < <(jq -c '.items[] | select(.inventoryOnly == true)' <<<"$inventory")

    while IFS= read -r id; do
      [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "unsafe provider package id: $id"
      [[ "$(jq --arg id "$id" '[.items[] | select(.id == $id)] | length' <<<"$inventory")" == 1 ]] \
        || fail "provider $provider_name must expose exactly one inventory item for $id"
      item="$(jq -c --arg id "$id" '.items[] | select(.id == $id)' <<<"$inventory")"
      display_name="$(jq -r '.name // .id' <<<"$item")"
      if [[ "$(jq -r '.installed // false' <<<"$item")" == true ]]; then
        state=preexisting
        ownership=provider
        printf '  [%-18s] %-24s already installed\n' "$provider_name" "$display_name"
      else
        "$command" plan --action install "$id" \
          || fail "provider $provider_name could not plan installation of $id"
        if [[ "$mode" == plan ]]; then
          state=planned
          ownership=none
        elif confirm "Install $display_name through $provider_name?"; then
          if ! "$command" apply --action install "$id"; then
            state=failed
            ownership=provider
            status="$(jq -cn --argjson items "$status" --argjson item "$item" \
              --arg provider "$provider_name" --arg state "$state" --arg ownership "$ownership" \
              --arg removalPolicy "$removal_policy" '
                $items + [($item + {provider: $provider, requested: true, state: $state,
                  ownership: $ownership, removalPolicy: $removalPolicy})]
              ')"
            mkdir -p "$ROOT/.state"
            jq -n --arg profile "$PROFILE" --argjson items "$status" \
              '{schemaVersion: 1, profile: $profile, complete: false, degraded: true, items: $items}' \
              >"$pending_file"
            fail "provider $provider_name failed to install $id"
          fi
          refreshed="$($command inventory)" || fail "provider inventory failed after installing $id"
          item="$(jq -c --arg id "$id" '.items[] | select(.id == $id)' <<<"$refreshed")"
          [[ "$(jq -r '.installed // false' <<<"$item")" == true ]] \
            || fail "provider $provider_name did not verify $id after installation"
          inventory="$refreshed"
          state=installed
          ownership=home-weave
        else
          state=declined
          ownership=none
          degraded=true
          printf '  [%-18s] %-24s declined; profile will be marked degraded\n' "$provider_name" "$display_name"
        fi
      fi
      status="$(jq -cn --argjson items "$status" --argjson item "$item" \
        --arg provider "$provider_name" --arg state "$state" --arg ownership "$ownership" \
        --arg removalPolicy "$removal_policy" '
          $items + [($item + {provider: $provider, requested: true, state: $state,
            ownership: $ownership, removalPolicy: $removalPolicy})]
        ')"
    done < <(jq -r --arg provider "$provider_name" '.[$provider][]' <<<"$provider_packages")
  done < <(jq -r 'keys[]' <<<"$provider_packages")

  if [[ "$mode" == apply ]]; then
    mkdir -p "$ROOT/.state"
    jq -n --arg profile "$PROFILE" --argjson degraded "$degraded" --argjson items "$status" \
      '{schemaVersion: 1, profile: $profile, complete: true, degraded: $degraded, items: $items}' \
      >"$pending_file.tmp.$$"
    mv "$pending_file.tmp.$$" "$pending_file"
  fi
}

show_profile_packages() {
  local file="$ROOT/home-weave.json"
  printf '\nProfile configuration: %s\n' "$file"
  printf 'Inherited defaults come from %s and are pinned by flake.lock.\n' "$BASE_URL"
  jq --arg profile "$PROFILE" '.profiles[$profile]' "$file"
  printf 'Add future packages and dotfile components to this profile in home-weave.json.\n'
}

scan_dotfiles() {
  local candidate relative answer target bundled
  [[ -t 0 ]] || return 0
  printf '\nHomeWeave can adopt selected existing configurations.\n'
  mkdir -p "$ROOT/.state" "$ROOT/dotfiles/custom"
  : >"$ROOT/.state/adoptions"
  for candidate in \
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.gitconfig" \
    "$HOME/.home_weave_profile" \
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
    eval --json "path:$ROOT#lib.setup.profilesBySystem.\"$(current_nix_system)\""
}

record_receipt() {
  local receipts="$ROOT/.state/receipts" timestamp receipt temporary previous profiles system revision
  local inventory='[]' preflight='{}' dotfiles='[]' casks='[]' providers='[]' provider_status='{}' provider_status_file parent_chain='[]' cursor parent
  local current_generation previous_generation changes
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  receipt="$receipts/${timestamp//:/-}.json"
  temporary="$receipt.tmp.$$"
  mkdir -p "$receipts"
  printf 'Recording activation receipt...\n'
  profiles="$(profile_metadata)"
  system="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --impure --raw --expr builtins.currentSystem)"
  if [[ "$system" == x86_64-darwin ]]; then
    revision="$(jq -r '.nodes["nixpkgs-x86-darwin"].locked.rev // "unknown"' "$ROOT/flake.lock" 2>/dev/null || printf unknown)"
  else
    revision="$(jq -r '.nodes.nixpkgs.locked.rev // "unknown"' "$ROOT/flake.lock" 2>/dev/null || printf unknown)"
  fi
  [[ -r "$ROOT/.state/last-inventory.json" ]] \
    || fail "activation inventory is missing; receipt cannot be recorded"
  inventory="$(<"$ROOT/.state/last-inventory.json")"
  jq -e 'type == "array"' >/dev/null <<<"$inventory" \
    || fail "activation inventory is invalid; receipt cannot be recorded"
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
  provider_status_file="$ROOT/.state/provider-status.json"
  [[ ! -s "$ROOT/.state/provider-status.pending.json" ]] || provider_status_file="$ROOT/.state/provider-status.pending.json"
  if [[ -s "$provider_status_file" ]]; then
    provider_status="$(<"$provider_status_file")"
    jq -e '.schemaVersion == 1 and (.items | type == "array")' >/dev/null <<<"$provider_status" \
      || fail "invalid provider status state"
    providers="$(jq -c '.items' <<<"$provider_status")"
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
    --argjson packages "$inventory" --argjson providers "$providers" --argjson dotfiles "$dotfiles" \
    --slurpfile old "${previous:-/dev/null}" '
      ($old[0] // {packages: [], applications: {providers: []}, dotfiles: []}) as $previous
      | ($packages | map(.name)) as $newPackages
      | ($previous.packages | map(.name)) as $oldPackages
      | ($providers | map("provider:" + .provider + ":" + .id)) as $newProviders
      | (($previous.applications.providers // []) | map("provider:" + .provider + ":" + .id)) as $oldProviders
      | ($dotfiles | map(.destination)) as $newDots
      | ($previous.dotfiles | map(.destination)) as $oldDots
      | {
          added: (($newPackages - $oldPackages) + ($newProviders - $oldProviders) + ($newDots - $oldDots)),
          removed: (($oldPackages - $newPackages) + ($oldProviders - $newProviders) + ($oldDots - $newDots)),
          retained: (($newPackages - ($newPackages - $oldPackages))
            + ($newProviders - ($newProviders - $oldProviders)) + ($newDots - ($newDots - $oldDots))),
          changed: [ $packages[] as $new | $previous.packages[]? | select(.name == $new.name and (.storePath != $new.storePath)) | $new.name ]
        }')"
  jq -n \
    --arg timestamp "$timestamp" --arg profile "$PROFILE" --argjson parentChain "$parent_chain" \
    --arg system "$system" --arg shell "$PRIMARY_SHELL" --arg revision "$revision" \
    --argjson packages "$inventory" --argjson preflight "$preflight" \
    --argjson casks "$casks" --argjson providers "$providers" --argjson providerStatus "$provider_status" \
    --argjson dotfiles "$dotfiles" --argjson changes "$changes" \
    --arg currentGeneration "$current_generation" --arg previousGeneration "$previous_generation" \
    '{schemaVersion: 1, timestamp: $timestamp, activeProfile: $profile,
      parentChain: $parentChain, system: $system, shell: $shell, nixpkgsRevision: $revision,
      packages: $packages, build: $preflight,
      applications: {homebrew: $casks, native: [], providers: $providers},
      providerDegraded: ($providerStatus.degraded // false), dotfiles: $dotfiles,
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
    (.applications[] | .[] | "  \(.provider // "native"): \(.id // .name) [\(.state // "installed")]"),
    "Provider profile: \(if .providerDegraded then "degraded" else "complete" end)",
    "Managed dotfiles:",
    (.dotfiles[] | "  \(.destination) <- \(.source) [\(.sourceLayer)]"),
    "Changes: +\(.changes.added | length) -\(.changes.removed | length) ~\(.changes.changed | length) retained \(.changes.retained | length)",
    "Rollback Home Manager generation: \(.rollback.previousHomeManagerGeneration // "none")"' "$receipt"
}

status_command() {
  local receipt="" candidate last_operation='null'
  if [[ -s "$ROOT/.state/last-operation.json" ]] \
    && jq -e '.schemaVersion == 1' "$ROOT/.state/last-operation.json" >/dev/null 2>&1; then
    last_operation="$(jq -c . "$ROOT/.state/last-operation.json")"
  fi
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
      jq -n --arg profile "${PROFILE:-}" --argjson lastOperation "$last_operation" \
        '{installed: false, activeProfile: (if $profile == "" then null else $profile end),
          lastOperation: $lastOperation}'
    else
      printf 'HomeWeave has no successful activation receipt%s.\n' "${PROFILE:+ for profile $PROFILE}"
      if [[ "$last_operation" != null ]]; then
        jq -r '"Last operation: \(.command) \(.status) during \(.phase)\nOperation log:  \(.logPath)"' \
          <<<"$last_operation"
      fi
    fi
    return
  fi
  if "$STATUS_JSON"; then
    jq --argjson lastOperation "$last_operation" '. + {lastOperation: $lastOperation}' "$receipt"
    return
  fi
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
    "  Provider state: \(if .providerDegraded then "degraded" else "complete" end)",
    "  Managed files:  \(.dotfiles | length)",
    "  Changes:        +\(.changes.added | length) -\(.changes.removed | length) ~\(.changes.changed | length) =\(.changes.retained | length)",
    "  Rollback:       \(.rollback.previousHomeManagerGeneration // "none")"' "$receipt"
  if [[ "$last_operation" != null ]]; then
    jq -r '"  Last operation: \(.command) \(.status) during \(.phase)\n  Operation log:  \(.logPath)"' \
      <<<"$last_operation"
  fi
}

logs_command() {
  local logs="$ROOT/.state/logs" latest file
  [[ -d "$logs" ]] || {
    printf 'HomeWeave has no operation logs.\n'
    return
  }
  if "$LOG_LATEST"; then
    if [[ -L "$logs/latest" ]]; then
      latest="$(readlink -f "$logs/latest" 2>/dev/null || true)"
    else
      latest="$(find "$logs" -maxdepth 1 -type f -name '*.log' -print | sort -r | head -n 1)"
    fi
    [[ -n "$latest" && -r "$latest" ]] || fail "latest operation log is unavailable"
    tail -n "$LOG_TAIL" "$latest"
    return
  fi
  while IFS= read -r file; do
    printf '%s\n' "$file"
  done < <(find "$logs" -maxdepth 1 -type f -name '*.log' -print | sort -r)
}

is_sensitive_environment_name() {
  [[ "$1" =~ (TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|CREDENTIAL) ]]
}

is_machine_environment_name() {
  [[ "$1" =~ ^(PATH|HOME|USER|LOGNAME|SHELL|PWD|OLDPWD|SHLVL|TMPDIR|TERM|TERM_PROGRAM|SSH_.*|NIX_.*|__CF_.*)$ ]]
}

portable_path() {
  local path="$1" parent
  case "$path" in
    \~/*) path="$HOME/${path#\~/}" ;;
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  [[ "$path" != / && "$path" != "$HOME" ]] || fail "refusing unsafe snapshot path: $path"
  parent="$(dirname "$path")"
  [[ -d "$parent" ]] || fail "snapshot parent directory does not exist: $parent"
  printf '%s/%s\n' "$(realpath "$parent")" "$(basename "$path")"
}

snapshot_environment() {
  local destination="$1" profile_document='{}' secret_document='{}' shell_document='{}'
  local file line key value public_document secret_keys='[]' profile_file secret_template
  [[ -r "$ENV_RENDERER" ]] || fail "HomeWeave environment renderer is unavailable"
  profile_document="$(bash "$ENV_RENDERER" render json "$HOME/.home_weave_profile")" \
    || fail "could not canonicalize ~/.home_weave_profile"
  secret_document="$(bash "$ENV_RENDERER" render json "$HOME/.home_weave_secrets")" \
    || fail "could not safely inspect ~/.home_weave_secrets"
  secret_keys="$(jq -c 'keys' <<<"$secret_document")"

  # Migrate only exported values already present in the running environment.
  # Raw shell files are never evaluated by snapshot creation.
  for file in "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
      key="${BASH_REMATCH[1]}"
      printenv "$key" >/dev/null 2>&1 || continue
      is_machine_environment_name "$key" && continue
      value="$(printenv "$key")"
      if is_sensitive_environment_name "$key"; then
        secret_keys="$(jq -cn --argjson keys "$secret_keys" --arg key "$key" '$keys + [$key] | unique')"
      elif [[ "$value" == *$'\n'* || "$value" == *$'\t'* || "$value" == *'`'* || "$value" == *'$('* ]]; then
        warn "snapshot skipped shell export $key because its value is not canonical-safe"
      else
        shell_document="$(jq -cn --argjson current "$shell_document" --arg key "$key" --arg value "$value" \
          '$current + {($key): $value}')"
      fi
    done <"$file"
  done

  # Any secret-like name accidentally placed in the non-secret profile is
  # redacted into the template instead of being copied with its value.
  while IFS= read -r key; do
    if is_sensitive_environment_name "$key"; then
      secret_keys="$(jq -cn --argjson keys "$secret_keys" --arg key "$key" '$keys + [$key] | unique')"
      profile_document="$(jq -c --arg key "$key" 'del(.[$key])' <<<"$profile_document")"
    fi
  done < <(jq -r 'keys[]' <<<"$profile_document")
  public_document="$(jq -cn --argjson profile "$profile_document" --argjson shell "$shell_document" \
    '$profile + $shell')"

  profile_file="$destination/dotfiles/custom/.home_weave_profile"
  mkdir -p "$(dirname "$profile_file")" "$destination/metadata"
  {
    printf '%s\n' '# Canonical non-secret environment captured by HomeWeave snapshot.'
    while IFS= read -r key; do
      value="$(jq -r --arg key "$key" '.[$key]' <<<"$public_document")"
      printf '%s=%s\n' "$key" "$value"
    done < <(jq -r 'keys[]' <<<"$public_document")
  } >"$profile_file"

  secret_template="$destination/metadata/home_weave_secrets.example"
  {
    printf '%s\n' '# Variable names only. Restore values from an approved secret manager.'
    printf '%s\n' '# Copy locally to ~/.home_weave_secrets and set mode 0600.'
    jq -r 'sort[] | . + "="' <<<"$secret_keys"
  } >"$secret_template"
}

snapshot_create() {
  local destination="${POSITIONAL_ARGS[1]:-$HOME/home-weave-snapshot-$(date -u +%Y%m%dT%H%M%SZ)}"
  local receipt='{}' profiles external='[]' timestamp
  [[ -f "$ROOT/flake.nix" && -x "$ROOT/home-weave" ]] || fail "$ROOT is not a HomeWeave repository"
  read_state
  destination="$(portable_path "$destination")"
  [[ ! -e "$destination" ]] || fail "snapshot destination already exists: $destination"
  case "$destination" in "$ROOT"/*) fail "snapshot destination must be outside the HomeWeave root" ;; esac
  require_commands jq rsync
  scan_secrets "$ROOT"
  mkdir -p "$destination"
  rsync -a \
    --exclude='.git/' --exclude='.state/' --exclude='backup/' --exclude='result' \
    --exclude='.home_weave_secrets' "$ROOT/" "$destination/"
  snapshot_environment "$destination"

  if [[ -L "$ROOT/.state/receipts/latest" ]]; then
    receipt="$(jq -c '.' "$(readlink -f "$ROOT/.state/receipts/latest")")"
  fi
  profiles="$(profile_metadata)"
  external="$(nix profile list --json 2>/dev/null | jq -c '
    to_entries | map({name: .key, storePaths: (.value.storePaths // []),
      originalUrl: ((.value.originalUrl // null) as $url
        | if ($url | type) == "string" and ($url | startswith("path:")) then null else $url end)})' \
    2>/dev/null || printf '[]')"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg timestamp "$timestamp" --arg profile "$PROFILE" --arg shell "$PRIMARY_SHELL" \
    --argjson receipt "$receipt" \
    --argjson profiles "$profiles" --argjson external "$external" \
    '{schemaVersion: 1, createdAt: $timestamp, activeProfile: ($receipt.activeProfile // $profile),
      parentChain: ($receipt.parentChain // []), system: ($receipt.system // null),
      shell: ($receipt.shell // $shell), nixpkgsRevision: ($receipt.nixpkgsRevision // null),
      profiles: $profiles, packages: ($receipt.packages // []),
      applications: ($receipt.applications // {homebrew: [], native: [], providers: []}),
      observedExternalNixProfile: $external,
      portability: {externalNixProfileIsInventoryOnly: true, secretValuesIncluded: false}}' \
    >"$destination/snapshot.json"
  mkdir -p "$destination/.state"
  jq -r '.activeProfile' "$destination/snapshot.json" >"$destination/.state/selected-profile"
  jq -r '.shell' "$destination/snapshot.json" >"$destination/.state/primary-shell"
  find "$destination" -name .home_weave_secrets -print -quit | grep -q . \
    && fail "internal error: snapshot contains a secrets file"
  scan_secrets "$destination"
  printf 'Portable HomeWeave snapshot created at %s\n' "$destination"
  printf 'Secret values were not included. Required names: %s\n' \
    "$destination/metadata/home_weave_secrets.example"
  printf 'On another machine, run: home-weave snapshot restore %q --root ~/.home-weave-restored\n' "$destination"
}

snapshot_restore() {
  local source="${POSITIONAL_ARGS[1]:-}"
  [[ -n "$source" ]] || fail "snapshot restore requires a path"
  source="$(portable_path "$source")"
  [[ -d "$source" && -f "$source/snapshot.json" && -f "$source/flake.nix" ]] \
    || fail "not a portable HomeWeave snapshot: $source"
  jq -e '.schemaVersion == 1 and .portability.secretValuesIncluded == false' \
    "$source/snapshot.json" >/dev/null || fail "unsupported or unsafe snapshot manifest"
  find "$source" -name .home_weave_secrets -print -quit | grep -q . \
    && fail "snapshot restore refuses a bundled .home_weave_secrets file"
  [[ ! -e "$ROOT" ]] || {
    [[ -d "$ROOT" && -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
      || fail "restore target must be absent or empty: $ROOT"
  }
  require_commands jq rsync
  mkdir -p "$ROOT"
  rsync -a --exclude='metadata/' --exclude='.home_weave_secrets' "$source/" "$ROOT/"
  printf 'Snapshot restored as a HomeWeave repository at %s\n' "$ROOT"
  printf 'Secret values were not restored. See %s\n' "$source/metadata/home_weave_secrets.example"
  printf 'Review with: %s/home-weave plan\n' "$ROOT"
  if [[ "$APPLY_NOW" == true ]]; then
    HOME_WEAVE_ROOT="$ROOT" bash "$ROOT/home-weave" plan
    confirm "Apply the restored snapshot?" || fail "snapshot restored but activation was cancelled"
    HOME_WEAVE_ROOT="$ROOT" bash "$ROOT/home-weave" apply
  fi
}

snapshot_command() {
  local action="${POSITIONAL_ARGS[0]:-create}"
  case "$action" in
    create) snapshot_create ;;
    restore) snapshot_restore ;;
    *) fail "unknown snapshot command: $action (use create or restore)" ;;
  esac
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
      file="$ROOT/home-weave.json"
      jq --arg name "$name" --arg parent "$EXTENDS" \
        '.profiles[$name] = {extends: $parent, shells: ["zsh"], primaryShell: "zsh", packageGroups: [], dotfiles: [], packages: {nix: []}}' \
        "$file" >"$file.tmp.$$"
      mv "$file.tmp.$$" "$file"
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
      for field in packageGroups dotfiles homebrewFormulae homebrewCasks allowUnfree shells; do
        printf '\n%s:\n' "$field"
        jq -nr --argjson old "$current_json" --argjson new "$target_json" --arg field "$field" '
          (((($new[$field] // []) - ($old[$field] // []))[]) | "+ " + .),
          (((($old[$field] // []) - ($new[$field] // []))[]) | "- " + .)' || true
      done
      printf '\nproviderPackages:\n'
      jq -nr --argjson old "$current_json" --argjson new "$target_json" '
        ((($old.providerPackages // {}) | keys) + (($new.providerPackages // {}) | keys) | unique)[] as $provider
        | (((($new.providerPackages[$provider] // []) - ($old.providerPackages[$provider] // []))[])
            | "+ [" + $provider + "] " + .),
          (((($old.providerPackages[$provider] // []) - ($new.providerPackages[$provider] // []))[])
            | "- [" + $provider + "] " + .)
      ' || true
      printf '\nnativePackages:\n'
      jq -nr --argjson old "$current_json" --argjson new "$target_json" '
        ["homebrewFormulae", "apt", "pacman"][] as $manager
        | (((($new.nativePackages[$manager] // []) - ($old.nativePackages[$manager] // []))[])
            | "+ [" + $manager + "] " + .),
          (((($old.nativePackages[$manager] // []) - ($new.nativePackages[$manager] // []))[])
            | "- [" + $manager + "] " + .)
      ' || true
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
      if "$DRY_RUN"; then
        printf 'Would delete profile definition %s.\n' "$name"
      else
        file="$ROOT/home-weave.json"
        jq --arg name "$name" 'del(.profiles[$name])' "$file" >"$file.tmp.$$"
        mv "$file.tmp.$$" "$file"
      fi
      ;;
    *) fail "unknown profile command: $action" ;;
  esac
}

run_profile_setup() {
  local mode="$1" profiles selected_shell setup_args=()
  start_operation_log "$mode"
  set_operation_phase profile-evaluation
  read_state
  [[ -f "$ROOT/setup.sh" ]] || fail "$ROOT is not a HomeWeave profile"
  profiles="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profilesBySystem.\"$(current_nix_system)\"" 2>/dev/null || printf '{}')"
  selected_shell="$(jq -r --arg profile "$PROFILE" '.[$profile].primaryShell // empty' <<<"$profiles")"
  [[ -z "$selected_shell" ]] || PRIMARY_SHELL="$selected_shell"
  "$ASSUME_YES" && setup_args+=(--yes)
  if [[ "$mode" == plan ]]; then
    set_operation_phase nix-preflight
    if ! HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      run_logged bash "$ROOT/setup.sh" --profile "$PROFILE" --shell "$PRIMARY_SHELL" --generate-only "${setup_args[@]}"; then
      [[ ! -r "$ROOT/.state/operation-phase" ]] || OPERATION_PHASE="$(<"$ROOT/.state/operation-phase")"
      fail "plan failed"
    fi
    set_operation_phase provider-plan
    reconcile_profile_providers plan "$profiles" || fail "provider planning failed"
    finish_operation_log success
  else
    set_operation_phase provider-reconciliation
    reconcile_profile_providers apply "$profiles" || fail "provider reconciliation failed"
    set_operation_phase adoption-staging
    if ! prepare_adoptions; then
      restore_adoptions
      fail "could not stage adopted configurations"
    fi
    set_operation_phase activation
    if HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      run_logged bash "$ROOT/setup.sh" --profile "$PROFILE" --shell "$PRIMARY_SHELL" "${setup_args[@]}"; then
      set_operation_phase receipt
      record_receipt || fail "activation succeeded but receipt creation failed"
      : >"$ROOT/.state/adoptions"
      if [[ -f "$ROOT/.state/provider-status.pending.json" ]]; then
        mv "$ROOT/.state/provider-status.pending.json" "$ROOT/.state/provider-status.json"
      fi
      date -u +%Y%m%dT%H%M%SZ >"$ROOT/.state/applied"
      write_state
      rm -f "$ROOT/.state/home-manager-pending"
      printf 'Active HomeWeave profile: %s\n' "$PROFILE"
      ADOPTION_BACKUP_ROOT=""
      finish_operation_log success
    else
      [[ ! -r "$ROOT/.state/operation-phase" ]] || OPERATION_PHASE="$(<"$ROOT/.state/operation-phase")"
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
  UNINSTALLED_DOTFILE_GENERATION="$backup"
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

normalize_absolute_path() {
  local path="$1" segment normalized=""
  local parts=()
  [[ "$path" == /* ]] || return 1
  while IFS= read -r segment; do
    case "$segment" in
      ""|.) ;;
      ..)
        ((${#parts[@]} > 0)) || return 1
        parts=("${parts[@]:0:${#parts[@]}-1}")
        ;;
      *) parts+=("$segment") ;;
    esac
  done < <(tr '/' '\n' <<<"$path")
  for segment in "${parts[@]}"; do
    normalized="$normalized/$segment"
  done
  printf '%s\n' "${normalized:-/}"
}

is_stale_dotfile_link_owned_by_root() {
  local link="$1" raw candidate managed_root
  [[ -L "$link" && ! -e "$link" ]] || return 1
  [[ "$link" != "$ROOT" && "$link" != "$ROOT/"* ]] || return 1
  raw="$(readlink "$link")" || return 1
  if [[ "$raw" == /* ]]; then
    candidate="$raw"
  else
    candidate="$(dirname "$link")/$raw"
  fi
  candidate="$(normalize_absolute_path "$candidate")" || return 1
  managed_root="$(normalize_absolute_path "$ROOT/.state/dotfiles/current")" || return 1
  [[ "$candidate" == "$managed_root" || "$candidate" == "$managed_root/"* ]]
}

collect_stale_dotfile_links() {
  local generation staged relative link receipt destination

  # Inspect only destinations HomeWeave can prove it managed. Walking the
  # entire home is both unnecessary and extremely slow on macOS homes with
  # cloud storage, application sandboxes, or protected directories.
  for generation in \
    "$ROOT/.state/dotfiles/current" \
    "$UNINSTALLED_DOTFILE_GENERATION"; do
    [[ -n "$generation" && -d "$generation" ]] || continue
    while IFS= read -r -d '' staged; do
      relative="${staged#"$generation"/}"
      link="$HOME/$relative"
      is_stale_dotfile_link_owned_by_root "$link" || continue
      printf '%s\0' "$link"
    done < <(find "$generation" \( -type f -o -type l \) -print0)
  done

  if [[ -d "$ROOT/.state/receipts" ]]; then
    while IFS= read -r receipt; do
      while IFS= read -r destination; do
        [[ "$destination" == "$HOME/"* ]] || continue
        is_stale_dotfile_link_owned_by_root "$destination" || continue
        printf '%s\0' "$destination"
      done < <(jq -r '.dotfiles[]?.destination // empty' "$receipt" 2>/dev/null || true)
    done < <(find "$ROOT/.state/receipts" -maxdepth 1 -type f -name '*.json' -print)
  fi
}

cleanup_stale_dotfile_links() {
  local link existing duplicate
  local stale_links=()
  while IFS= read -r -d '' link; do
    duplicate=false
    for existing in "${stale_links[@]-}"; do
      if [[ "$existing" == "$link" ]]; then
        duplicate=true
        break
      fi
    done
    "$duplicate" && continue
    stale_links+=("$link")
  done < <(collect_stale_dotfile_links)

  if ((${#stale_links[@]} == 0)); then
    printf 'No dangling links owned by %s were found.\n' "$ROOT"
    return 0
  fi

  printf 'Dangling links owned by %s:\n' "$ROOT"
  for link in "${stale_links[@]}"; do
    printf '  %s -> %s\n' "$link" "$(readlink "$link")"
  done

  if "$DRY_RUN"; then
    printf 'Would remove %d dangling HomeWeave-owned link(s).\n' "${#stale_links[@]}"
    return 0
  fi
  for link in "${stale_links[@]}"; do
    # Recheck ownership immediately before removal so a link changed during
    # the confirmation window is never deleted.
    if is_stale_dotfile_link_owned_by_root "$link"; then
      rm "$link"
    else
      warn "link changed during cleanup and was retained: $link"
    fi
  done
  printf 'Removed %d dangling HomeWeave-owned link(s).\n' "${#stale_links[@]}"
}

uninstall_home_manager() {
  local generated="$ROOT/.state/generated" receipt="" receipt_generation="" current_generation=""
  local has_marker=false has_matching_receipt=false
  [[ ! -f "$ROOT/.state/applied" && ! -f "$ROOT/.state/home-manager-pending" ]] || has_marker=true
  if [[ -L "$ROOT/.state/receipts/latest" ]]; then
    receipt="$(readlink -f "$ROOT/.state/receipts/latest" 2>/dev/null || true)"
  fi
  if [[ -n "$receipt" && -r "$receipt" ]] \
    && jq -e '.schemaVersion == 1 and (.rollback.currentHomeManagerGeneration | type == "string")' \
      "$receipt" >/dev/null 2>&1; then
    receipt_generation="$(jq -r '.rollback.currentHomeManagerGeneration' "$receipt")"
    current_generation="$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" 2>/dev/null || true)"
    if [[ -n "$receipt_generation" && "$receipt_generation" == "$current_generation" ]]; then
      has_matching_receipt=true
    elif [[ -n "$receipt_generation" && -n "$current_generation" ]]; then
      fail "the latest receipt does not own the current Home Manager generation; refusing to remove another environment or delete uninstall evidence"
    fi
  fi
  if [[ "$has_marker" == false && "$has_matching_receipt" == false ]]; then
    printf 'No HomeWeave activation marker was found; Home Manager uninstall was skipped.\n'
    return
  fi
  if [[ "$has_marker" == false ]]; then
    printf 'Activation receipt matches the current Home Manager generation; recovering the missing uninstall marker.\n'
  fi
  printf 'Home Manager will remove its managed packages, files, and generations.\n'
  "$DRY_RUN" && return 0
  [[ -f "$generated/flake.nix" ]] || fail "generated Home Manager configuration is missing"
  printf 'y\n' | nix --extra-experimental-features 'nix-command flakes' \
    run "path:$generated#home-manager" -- uninstall
  rm -f "$ROOT/.state/applied" "$ROOT/.state/home-manager-pending"
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
  local status_file="$ROOT/.state/provider-status.json"
  local provider_name id provider command item removal_policy ownership
  load_builtin_provider
  if [[ -s "$status_file" ]]; then
    while IFS= read -r item; do
      provider_name="$(jq -r '.provider' <<<"$item")"
      id="$(jq -r '.id' <<<"$item")"
      removal_policy="$(jq -r '.removalPolicy // "remove"' <<<"$item")"
      ownership="$(jq -r '.ownership // "provider"' <<<"$item")"
      [[ "$removal_policy" != retain ]] || {
        printf 'Retained provider-managed application: [%s] %s\n' "$provider_name" "$id"
        continue
      }
      [[ "$ownership" == home-weave ]] || continue
      provider="$(jq -c --arg name "$provider_name" '.[] | select(.name == $name)' <<<"$EXTENSIONS_JSON")"
      if [[ -z "$provider" ]] || ! jq -e '.capabilities | index("remove")' >/dev/null <<<"$provider"; then
        warn "provider $provider_name cannot remove recorded application $id; it was retained"
        continue
      fi
      command="$(jq -r '.executable' <<<"$provider")"
      "$command" plan --action remove "$id"
      "$DRY_RUN" || "$command" apply --action remove "$id"
    done < <(jq -c '.items[] | select(.requested == true and (.state == "installed" or .state == "preexisting"))' "$status_file")
    "$DRY_RUN" || rm -f "$status_file" "$ROOT/.state/provider-status.pending.json"
  fi
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

  # Nuke confirmation must happen before Home Manager, Stow, provider, state,
  # or repository changes. --yes intentionally cannot bypass this guard.
  if "$UNINSTALL_NUKE" && ! "$DRY_RUN"; then
    [[ -t 0 ]] || fail "uninstall --nuke requires an interactive typed confirmation"
    printf 'This permanently deletes only the HomeWeave root after removing recorded HomeWeave effects.\n'
    printf 'Type the complete phrase shown below exactly:\n  DELETE %s\nConfirmation: ' "$ROOT"
    read -r confirmation
    [[ "$confirmation" == "DELETE $ROOT" ]] || fail "nuke confirmation did not match; nothing was changed"
  fi

  if "$UNINSTALL_ALL" || "$ASSUME_YES"; then
    UNINSTALL_REMOVE_CASKS=true
  fi
  if "$UNINSTALL_NUKE"; then
    UNINSTALL_ARCHIVE_ROOT=false
  elif "$UNINSTALL_ALL" && [[ -t 0 && "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
    confirm "Proceed with uninstall --all and remove every recorded HomeWeave effect?" \
      || fail "uninstall --all cancelled"
  elif [[ -t 0 && "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
    confirm "Remove the Home Manager environment?" || UNINSTALL_KEEP_HOME_MANAGER=true
    confirm "Unlink HomeWeave-managed dotfiles?" || UNINSTALL_KEEP_DOTFILES=true
    confirm "Restore available pre-adoption dotfiles?" || UNINSTALL_NO_RESTORE=true
    confirm "Remove casks and provider applications recorded as installed by HomeWeave?" && UNINSTALL_REMOVE_CASKS=true
    confirm "Archive the HomeWeave repository after uninstall?" && UNINSTALL_ARCHIVE_ROOT=true
    confirm "Proceed with the displayed uninstall choices?" || fail "uninstall cancelled"
  fi
  "$UNINSTALL_KEEP_HOME_MANAGER" || uninstall_home_manager
  "$UNINSTALL_KEEP_DOTFILES" || uninstall_dotfiles
  "$UNINSTALL_KEEP_DOTFILES" || cleanup_stale_dotfile_links
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
  local package group pinned filtered_packages=() group_unfree=()
  require_commands cp date du find git realpath sed
  [[ -d "$TEMPLATE" ]] || fail "profile template is unavailable: $TEMPLATE"
  begin_root_replacement
  trap 'rollback_root_replacement; release_operation_lock' EXIT ERR INT TERM
  cp -R "$TEMPLATE/." "$ROOT/"
  chmod -R u+rwX "$ROOT"
  if [[ -n "$PROFILE_OVERLAY" ]]; then
    [[ -d "$PROFILE_OVERLAY" ]] || fail "profile overlay is unavailable: $PROFILE_OVERLAY"
    if [[ -f "$PROFILE_OVERLAY/home-weave.json" ]]; then
      jq -s '.[0] * .[1]' "$ROOT/home-weave.json" "$PROFILE_OVERLAY/home-weave.json" \
        >"$ROOT/home-weave.json.tmp.$$"
      mv "$ROOT/home-weave.json.tmp.$$" "$ROOT/home-weave.json"
    fi
    rsync -a --exclude='/home-weave.json' "$PROFILE_OVERLAY/" "$ROOT/"
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
  if [[ -n "${filtered_packages[*]-}" ]]; then
    pinned="$(pinned_nixpkgs_ref)" || fail "could not verify requested packages against pinned Nixpkgs"
    add_profile_packages "${filtered_packages[@]}"
    accept_unfree_packages "$pinned" "${filtered_packages[@]}"
  fi
  select_package_groups
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
  [[ "$schema" == 4 ]] || fail "remote has an unsupported HomeWeave schema"
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
  start_operation_log update
  set_operation_phase nix-update
  run_logged nix --extra-experimental-features 'nix-command flakes' flake update --flake "path:$ROOT" \
    || fail "Nix input update failed"
  printf 'Inputs updated. Review %s/flake.lock, then run home-weave plan.\n' "$ROOT"
  finish_operation_log success
}

provider_command() {
  local action="${POSITIONAL_ARGS[0]:-list}" provider_name="${POSITIONAL_ARGS[1]:-}" provider command capabilities removal_policy
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
  removal_policy="$(jq -r '.removalPolicy // "remove"' <<<"$provider")"
  capabilities="$(jq -r '.capabilities[]' <<<"$provider")"
  grep -Fxq "$action" <<<"$capabilities" || fail "$provider_name does not support $action"
  [[ -x "$command" ]] || fail "provider executable is unavailable: $command"
  if [[ "$action" == install || "$action" == update || "$action" == remove ]]; then
    "$command" plan --action "$action" "${POSITIONAL_ARGS[@]:2}"
    confirm "Allow $provider_name to $action the selected applications?" || fail "provider action declined"
    "$command" apply --action "$action" "${POSITIONAL_ARGS[@]:2}"
    if [[ "$action" == install ]]; then
      if [[ "$removal_policy" == retain ]]; then
        printf 'Provider %s retains lifecycle ownership; installed applications will not be removed by HomeWeave.\n' "$provider_name"
      else
        printf 'Provider action completed. Profile-owned installation receipts are written only by profile apply.\n'
      fi
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

config_command() {
  local action="${POSITIONAL_ARGS[0]:-show}" name="${POSITIONAL_ARGS[1]:-}" config="$ROOT/home-weave.json"
  [[ -f "$config" ]] || fail "configuration is missing: $config"
  require_commands jq nix
  case "$action" in
    validate)
      [[ -r "$CONFIG_SCHEMA" ]] || fail "HomeWeave configuration schema is unavailable: $CONFIG_SCHEMA"
      command -v check-jsonschema >/dev/null 2>&1 \
        || fail "check-jsonschema is required to validate home-weave.json"
      check-jsonschema --schemafile "$CONFIG_SCHEMA" "$config" \
        || fail "home-weave.json does not satisfy the HomeWeave v2 schema"
      nix --extra-experimental-features 'nix-command flakes' eval --json \
        "path:$ROOT#lib.setup.profilesBySystem.\"$(current_nix_system)\"" >/dev/null \
        || fail "home-weave.json could not be resolved for this system"
      printf 'Configuration is valid: %s\n' "$config"
      ;;
    show)
      name="${name:-${PROFILE:-$(jq -r '.defaults.profile' "$config")}}"
      validate_name "$name"
      jq -e --arg name "$name" '.profiles | has($name)' "$config" >/dev/null \
        || fail "profile does not exist: $name"
      jq --arg name "$name" '.profiles[$name]' "$config"
      printf '\nDotfile placement (GNU Stow layout; target is $HOME):\n'
      jq -r --arg name "$name" '.profiles[$name].dotfiles[]? | "  dotfiles/\(.)/<home-relative-path> -> ~/<home-relative-path>"' "$config"
      ;;
    *) fail "unknown config command: $action (use validate or show)" ;;
  esac
}

POSITIONAL_ARGS=()
parse_common_options "$@"
[[ "$COMMAND" != uninstall ]] || normalize_uninstall_mode
normalize_root

case "$COMMAND" in
  setup|apply|update|uninstall|snapshot) acquire_operation_lock ;;
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
  config) config_command ;;
  logs) logs_command ;;
  snapshot) snapshot_command ;;
  provider) provider_command ;;
  extension) extension_command ;;
  help|--help|-h) usage ;;
  *) fail "unknown command: $COMMAND (run home-weave help)" ;;
esac
