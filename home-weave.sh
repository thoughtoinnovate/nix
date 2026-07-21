#!/usr/bin/env bash

set -Eeuo pipefail

# HomeWeave accepts substitutions only from the signed official Nix cache and
# requests sandboxing for derivations that still require local construction.
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
require-sigs = true
sandbox = true"

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
CONFIG_SCHEMA="${HOME_WEAVE_CONFIG_SCHEMA:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/schemas/home-weave-v4.schema.json}"
EXTENSIONS_JSON="${HOME_WEAVE_EXTENSIONS_JSON-}"
PLUGINS_JSON="${HOME_WEAVE_PLUGINS_JSON-}"
[[ -n "$EXTENSIONS_JSON" ]] || EXTENSIONS_JSON='[]'
[[ -n "$PLUGINS_JSON" ]] || PLUGINS_JSON='{}'
ASSUME_YES=false
PUBLISH=false
APPLY_NOW=""
PROFILE=""
EXTENDS="base"
PRIMARY_SHELL=""
SELECTED_SHELLS=""
SHELL_EXPLICIT=false
REQUESTED_PACKAGES=()
REQUESTED_GROUPS=()
MANAGED_PROVIDER_IDS=""
DEFAULT_PACKAGE_IDS=""
REMOTE_URL=""
REMOTE_BRANCH=""
RESTORE_MODE=""
NO_GIT=false
UNINSTALL_REMOVE_CASKS=false
UNINSTALL_ARCHIVE_ROOT=false
UNINSTALL_KEEP_DOTFILES=false
UNINSTALL_KEEP_PACKAGES=false
UNINSTALL_NO_RESTORE=false
DRY_RUN=false
STATUS_JSON=false
LOG_LATEST=false
LOG_TAIL=100
UNINSTALL_ALL=false
UNINSTALL_NUKE=false
NUKE_ALL_CONFIRMED=false
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

show_homeweave_banner() {
  [[ "${HOME_WEAVE_NO_BANNER:-}" != 1 ]] || return 0
  [[ -t 1 || "${HOME_WEAVE_FORCE_BANNER:-}" == 1 ]] || return 0
  cat <<'HOME_WEAVE_BANNER'
██╗  ██╗ ██████╗ ███╗   ███╗███████╗██╗    ██╗███████╗ █████╗ ██╗   ██╗███████╗
██║  ██║██╔═══██╗████╗ ████║██╔════╝██║    ██║██╔════╝██╔══██╗██║   ██║██╔════╝
███████║██║   ██║██╔████╔██║█████╗  ██║ █╗ ██║█████╗  ███████║██║   ██║█████╗
██╔══██║██║   ██║██║╚██╔╝██║██╔══╝  ██║███╗██║██╔══╝  ██╔══██║╚██╗ ██╔╝██╔══╝
██║  ██║╚██████╔╝██║ ╚═╝ ██║███████╗╚███╔███╔╝███████╗██║  ██║ ╚████╔╝ ███████╗
╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝ ╚══╝╚══╝ ╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝

/\/\  reproducible homes, layered cleanly

HOME_WEAVE_BANNER
}

current_nix_system() {
  local os arch
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) fail "unsupported operating system" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; x86_64) arch=x86_64 ;; *) fail "unsupported architecture" ;; esac
  printf '%s-%s' "$arch" "$os"
}

normalize_shell_name() {
  local candidate
  candidate="$(basename -- "$1")"
  candidate="${candidate#-}"
  case "$candidate" in
    bash|zsh|fish) printf '%s\n' "$candidate" ;;
    nu|nushell) printf 'nushell\n' ;;
    *) return 1 ;;
  esac
}

detect_active_shell() {
  local candidate pid parent command attempts=0
  if [[ -n "${HOME_WEAVE_ACTIVE_SHELL:-}" ]]; then
    normalize_shell_name "$HOME_WEAVE_ACTIVE_SHELL" \
      || fail "HOME_WEAVE_ACTIVE_SHELL is unsupported: $HOME_WEAVE_ACTIVE_SHELL"
    return
  fi

  # Walk past the Nix/app launcher and locate the interactive shell that
  # invoked HomeWeave. Fall back to the login shell when process ancestry is
  # unavailable (for example in a restricted CI environment).
  pid="$PPID"
  while [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && $attempts -lt 8 ]]; do
    command="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    if [[ -n "$command" ]] && candidate="$(normalize_shell_name "$command" 2>/dev/null)"; then
      printf '%s\n' "$candidate"
      return
    fi
    parent="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$parent" != "$pid" ]] || break
    pid="$parent"
    attempts=$((attempts + 1))
  done

  if [[ -n "${SHELL:-}" ]] && candidate="$(normalize_shell_name "$SHELL" 2>/dev/null)"; then
    printf '%s\n' "$candidate"
  elif [[ "$(uname -s)" == Darwin ]]; then
    printf 'zsh\n'
  else
    printf 'bash\n'
  fi
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
  home-weave nuke-all [--root PATH] [--dry-run]
  home-weave provider list|inventory|search|install|update|remove|status ...
  home-weave plugin list|show|status [NAME]
  home-weave extension list|NAME [arguments...]

Setup options:
  --root PATH             User repository (default: ~/.home-weave)
  --profile NAME          base, development, or a custom profile
  --extends NAME          Parent for a new custom profile (default: base)
  --shell NAME[,NAME...]  Shells to install; the first is primary
  --package NAME          Add a Nix package; may be repeated
  --group NAME            Add a package group; may be repeated
  --remote URL            Existing private Git remote
  --branch NAME           Target branch for --remote (prompted when omitted)
  --publish               Commit and push generated files to --remote
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
  --keep-packages     Leave the HomeWeave Nix package profile active
  --no-restore            Do not restore pre-adoption dotfile backups
  --dry-run               Display actions without changing anything

Nuke-all:
  Removes the selected HomeWeave root and the current user's default Nix
  profile, its history, user channels/definitions/cache, then runs global
  Nix garbage collection. It retains the Nix daemon and installation.
  A dry run is strongly recommended. --yes never bypasses the exact typed
  confirmation required by this command.

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
        SHELL_EXPLICIT=true
        shift 2
        ;;
      --package) [[ $# -ge 2 ]] || fail "--package requires a name"; REQUESTED_PACKAGES+=("$2"); shift 2 ;;
      --group) [[ $# -ge 2 ]] || fail "--group requires a name"; REQUESTED_GROUPS+=("$2"); shift 2 ;;
      --remote) [[ $# -ge 2 ]] || fail "--remote requires a URL"; REMOTE_URL="$2"; shift 2 ;;
      --branch) [[ $# -ge 2 ]] || fail "--branch requires a name"; REMOTE_BRANCH="$2"; shift 2 ;;
      --publish) PUBLISH=true; shift ;;
      --apply) APPLY_NOW=true; shift ;;
      --no-apply) APPLY_NOW=false; shift ;;
      --no-git) NO_GIT=true; shift ;;
      --remove-casks) UNINSTALL_REMOVE_CASKS=true; shift ;;
      --archive-root) UNINSTALL_ARCHIVE_ROOT=true; shift ;;
      --keep-dotfiles) UNINSTALL_KEEP_DOTFILES=true; shift ;;
      --keep-packages) UNINSTALL_KEEP_PACKAGES=true; shift ;;
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
      --refresh)
        fail "--refresh is a Nix option; place it before 'run' (nix --refresh run ... -- setup)"
        ;;
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
  write_active_root_launcher
}

active_root_state_file() {
  printf '%s/home-weave/active-root\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

active_root_launcher_path() {
  printf '%s/.local/bin/home-weave\n' "$HOME"
}

write_active_root_launcher() {
  local state_file launcher temporary
  state_file="$(active_root_state_file)"
  launcher="$(active_root_launcher_path)"
  if [[ -e "$launcher" || -L "$launcher" ]]; then
    if ! grep -Fqx '# HomeWeave active-root launcher' "$launcher" 2>/dev/null; then
      warn "cannot install the root-aware HomeWeave launcher because $launcher is not HomeWeave-managed"
      return 0
    fi
  fi
  install -d -m 0700 "$(dirname "$state_file")"
  printf '%s\n' "$ROOT" >"$state_file"
  chmod 0600 "$state_file"
  install -d -m 0755 "$(dirname "$launcher")"
  temporary="${launcher}.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# HomeWeave active-root launcher'
    printf 'export HOME_WEAVE_ROOT=%q\n' "$ROOT"
    printf '%s\n' 'profile_bin="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave/bin/home-weave"'
    printf '%s\n' 'if [[ ! -x "$profile_bin" ]]; then'
    printf '%s\n' '  printf "error: HomeWeave Nix profile launcher is unavailable: %s\\n" "$profile_bin" >&2'
    printf '%s\n' '  exit 127'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec "$profile_bin" "$@"'
  } >"$temporary"
  chmod 0755 "$temporary"
  mv "$temporary" "$launcher"
  printf 'Installed root-aware HomeWeave launcher: %s\n' "$launcher"
}

remove_active_root_launcher() {
  local state_file launcher active_root
  state_file="$(active_root_state_file)"
  launcher="$(active_root_launcher_path)"
  [[ -r "$state_file" ]] || return 0
  active_root="$(<"$state_file")"
  [[ "$active_root" == "$ROOT" || "$UNINSTALL_NUKE" == true ]] || return 0
  if [[ -f "$launcher" ]] && grep -Fqx '# HomeWeave active-root launcher' "$launcher"; then
    rm -f "$launcher"
    printf 'Removed root-aware HomeWeave launcher: %s\n' "$launcher"
  fi
  rm -f "$state_file"
  rmdir "$(dirname "$state_file")" 2>/dev/null || true
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
      -o -name '*.pfx' -o -name '.env' -o -name '.env.local' -o -name '.home_weave_secrets' \
      -o -name '.home_weave_secrets.*' \) -print -quit)
  if command -v rg >/dev/null 2>&1 && rg -l --hidden \
    'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|aws_(access_key_id|secret_access_key|session_token)[[:space:]]*=|glpat-[A-Za-z0-9_-]{20,}|gh[opsu]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|(^|[^A-Z])API_TOKEN[[:space:]]*=' \
    "$scope" --glob '!backup/**' --glob '!.state/**' --glob '!.git/**' | grep -q .; then
    fail "likely secret content was detected; keep credentials in a local secret store"
  fi
}

inheritance_profile_delta() {
  local parent="$1" shell shells_json
  validate_name "$parent"
  if ! "$SHELL_EXPLICIT"; then
    jq -cn --arg parent "$parent" \
      '{extends: $parent, exclude: {}, packageGroups: [], dotfiles: ["custom"], packages: {nix: []}}'
    return
  fi
  while IFS= read -r shell; do
    case "$shell" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $shell" ;; esac
  done <<<"${SELECTED_SHELLS:-$PRIMARY_SHELL}"
  shells_json="$(printf '%s\n' ${SELECTED_SHELLS:-$PRIMARY_SHELL} \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
  jq -cn --arg parent "$parent" --arg primary "$PRIMARY_SHELL" --argjson shells "$shells_json" \
    '{extends: $parent, shells: $shells, primaryShell: $primary,
      exclude: {}, packageGroups: [], dotfiles: ["custom"], packages: {nix: []}}'
}

ensure_profile() {
  local file="$ROOT/home-weave.json" temporary profile_delta
  jq -e --arg profile "$PROFILE" '.profiles | has($profile)' "$file" >/dev/null && return 0
  validate_name "$PROFILE"
  validate_name "$EXTENDS"
  jq -e --arg profile "$EXTENDS" '.profiles | has($profile)' "$file" >/dev/null \
    || fail "parent profile does not exist: $EXTENDS"
  profile_delta="$(inheritance_profile_delta "$EXTENDS")"
  temporary="$file.tmp.$$"
  jq --arg profile "$PROFILE" --argjson profileDelta "$profile_delta" \
    '.profiles[$profile] = $profileDelta' \
    "$file" >"$temporary"
  mv "$temporary" "$file"
}

choose_shell() {
  local selected primary detected configured
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
  detected="$(detect_active_shell)"
  configured="$(jq -r --arg profile "$PROFILE" '.profiles[$profile].shells[]? // empty' \
    "$ROOT/home-weave.json")"
  selected="$(printf '%s\n%s\n' "$detected" "$configured" \
    | jq -Rrsc 'split("\n") | map(select(length > 0))
      | reduce .[] as $shell ([]; if index($shell) then . else . + [$shell] end) | .[]')"
  [[ -n "$selected" ]] || selected="$detected"
  PRIMARY_SHELL="$detected"
  SELECTED_SHELLS="$selected"
  printf 'Detected %s with active shell %s; configuring: %s\n' \
    "$(current_nix_system)" "$PRIMARY_SHELL" "$(paste -sd, - <<<"$SELECTED_SHELLS")"
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
      ai|python|data-jupyter|go|rust|java|web|cloud|desktop) ;;
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
  local catalog group count packages selected selection token index valid line package
  local rows=() selectable_groups=() selected_groups=() requested_groups=() tokens=()
  catalog="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "$BASE_URL#lib.packageCatalog.groups" 2>/dev/null || printf '{}')"
  [[ "$(jq -r 'type' <<<"$catalog")" == object ]] || return 0
  load_default_package_ids

  group_is_inherited() {
    local candidate
    while IFS= read -r candidate; do
      grep -Fxq "$candidate" <<<"$DEFAULT_PACKAGE_IDS" || return 1
    done < <(jq -r --arg group "$1" '.[$group][]' <<<"$catalog")
    return 0
  }

  printf '\nOptional package groups (including AI tools; exact download and closure sizes appear in plan):\n'
  while IFS= read -r group; do
    count="$(jq -r --arg group "$group" '.[$group] | length' <<<"$catalog")"
    packages="$(jq -r --arg group "$group" '.[$group] | join(", ")' <<<"$catalog")"
    if group_is_inherited "$group"; then
      printf '  %-13s %2s packages  %s [already included]\n' "$group" "$count" "$packages"
    else
      printf '  %-13s %2s packages  %s\n' "$group" "$count" "$packages"
      selectable_groups+=("$group")
      rows+=("$(printf '%-13s %2s packages  %s' "$group" "$count" "$packages")")
    fi
  done < <(jq -r 'keys[]' <<<"$catalog")

  if ((${#REQUESTED_GROUPS[@]} > 0)); then
    for group in "${REQUESTED_GROUPS[@]}"; do
      jq -e --arg group "$group" 'has($group)' >/dev/null <<<"$catalog" \
        || fail "unknown package group: $group"
      if group_is_inherited "$group"; then
        printf 'Package group %s is already supplied by the inherited profile.\n' "$group"
      else
        requested_groups+=("$group")
      fi
    done
    REQUESTED_GROUPS=("${requested_groups[@]}")
    ((${#REQUESTED_GROUPS[@]} == 0)) \
      || printf 'Selected package groups from --group: %s\n' "$(IFS=', '; printf '%s' "${REQUESTED_GROUPS[*]}")"
    return 0
  fi
  [[ -t 0 ]] || return 0
  if ((${#selectable_groups[@]} == 0)); then
    printf 'All optional package groups are already included.\n'
    return 0
  fi

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
    for group in "${selectable_groups[@]}"; do
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
          if ((index < 0 || index >= ${#selectable_groups[@]})); then
            group=""
          else
            group="${selectable_groups[$index]}"
          fi
        else
          group="$token"
        fi
        if [[ -z "$group" ]] \
          || ! printf '%s\n' "${selectable_groups[@]}" | grep -Fxq "$group"; then
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
  local profiles profile_metadata
  profiles="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profilesBySystem.\"$(current_nix_system)\"" 2>/dev/null || printf '{}')"
  profile_metadata="$(jq -c --arg profile "$PROFILE" '.[$profile] // {}' <<<"$profiles")"
  DEFAULT_PACKAGE_IDS="$(jq -rn \
    --argjson profile "$profile_metadata" '
      (($profile.shells // []) + ($profile.nixPackages // [])) | unique[]')"
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
      $extensions + [{schemaVersion: 2, name: "native-official", executable: $executable,
        capabilities: ["inventory", "search", "install", "update", "remove", "status"],
        inventoryMode: "installed-only",
        removalPolicy: "remove",
        platforms: ["aarch64-darwin", "x86_64-darwin", "aarch64-linux", "x86_64-linux"]}]')"
  fi
}

show_provider_inventory() {
  local provider command output
  jq -e 'type == "array"' >/dev/null <<<"$EXTENSIONS_JSON" || fail "invalid extension manifest"
  while IFS= read -r provider; do
    jq -e '.schemaVersion == 2 and (.name | type == "string") and
      (.executable | type == "string") and (.capabilities | type == "array") and
      ((.removalPolicy == "remove") or (.removalPolicy == "retain")) and
      (.platforms | type == "array")' \
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

write_profile_provider_packages() {
  local provider="$1" groups_json="$2" items_json="$3" platform temporary config="$ROOT/home-weave.json"
  [[ "$provider" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "unsafe provider name: $provider"
  platform=linux
  [[ "$(uname -s)" != Darwin ]] || platform=macos
  temporary="$config.tmp.$$"
  jq --arg profile "$PROFILE" --arg platform "$platform" --arg provider "$provider" \
    --argjson groups "$groups_json" --argjson items "$items_json" '
      .profiles[$profile].platforms = (.profiles[$profile].platforms // {})
      | .profiles[$profile].platforms[$platform] = (.profiles[$profile].platforms[$platform] // {})
      | .profiles[$profile].platforms[$platform].plugins = (.profiles[$profile].platforms[$platform].plugins // {})
      | .profiles[$profile].platforms[$platform].plugins[$provider] =
          {enabled: true, groups: $groups, items: $items}
    ' "$config" >"$temporary"
  mv "$temporary" "$config"
}

select_provider_packages() {
  local provider provider_name command catalog inventory selected_groups selected_items selected_ids group rows item_rows
  local id label state platform config effective_ids
  local selected_group_ids='[]' selected_item_ids='[]' final_ids='[]'
  [[ -t 0 ]] || return 0
  while IFS= read -r provider; do
    jq -e '.schemaVersion == 2 and (.capabilities | index("catalog"))' >/dev/null <<<"$provider" || continue
    provider_name="$(jq -r '.name' <<<"$provider")"
    command="$(jq -r '.executable' <<<"$provider")"
    [[ -x "$command" ]] || fail "provider executable is unavailable: $command"
    catalog="$($command catalog)" || fail "provider catalog failed: $provider_name"
    inventory="$($command inventory)" || fail "provider inventory failed: $provider_name"
    jq -e '.schemaVersion == 1 and (.groups | type == "array") and (.items | type == "array")' \
      >/dev/null <<<"$catalog" || fail "provider $provider_name returned an invalid selectable catalog"
    jq -e '.schemaVersion == 1 and (.items | type == "array")' >/dev/null <<<"$inventory" \
      || fail "provider $provider_name returned invalid inventory"

    printf '\nOptional applications from provider %s (select none to skip):\n' "$provider_name"
    rows="$(jq -r --argjson inventory "$inventory" '
      .groups[] as $group
      | ([.items[] | select(.group == $group.id)] | length) as $total
      | ([.items[] | select(.group == $group.id) | .id] as $ids
        | [$inventory.items[] | select(.installed == true and (.id as $id | $ids | index($id)))] | length) as $installed
      | [$group.id, ($group.name // $group.id), ($installed|tostring), ($total|tostring)] | @tsv
    ' <<<"$catalog")"
    if [[ -n "$rows" ]]; then
      printf 'Application groups:\n'
      while IFS=$'\t' read -r group label installed total; do
        printf '  %-16s %-24s %s/%s installed\n' "$group" "$label" "$installed" "$total"
      done <<<"$rows"
      if command -v gum >/dev/null 2>&1; then
        selected_groups="$(printf '%s\n' "$rows" | gum choose --no-limit --height=12 \
          --header='Provider groups: SPACE select/unselect • ENTER confirm • select none to skip' || true)"
      else
        printf 'Group IDs, comma separated, or Enter to skip groups: '
        read -r selected_groups
        selected_groups="$(tr ',' '\n' <<<"$selected_groups")"
      fi
      selected_group_ids="$(while IFS=$'\t' read -r group _; do [[ -n "$group" ]] && printf '%s\n' "$group"; done \
        <<<"$selected_groups" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
    fi

    item_rows="$(jq -r --argjson groups "$selected_group_ids" --argjson inventory "$inventory" '
      .items[]
      | select((.inventoryOnly // false) == false)
      | . as $item
      | select($item.group == null or ($groups | index($item.group)) == null)
      | ($inventory.items | map(select(.id == $item.id and .installed == true)) | length > 0) as $installed
      | [$item.id, ($item.name // $item.id), (if $installed then "installed" else "missing" end)] | @tsv
    ' <<<"$catalog")"
    if [[ -n "$item_rows" ]]; then
      printf 'Individual applications not covered by selected groups:\n'
      while IFS=$'\t' read -r id label state; do
        printf '  %-24s %-28s %s\n' "$id" "$label" "$state"
      done <<<"$item_rows"
      if command -v gum >/dev/null 2>&1; then
        selected_items="$(printf '%s\n' "$item_rows" | gum choose --no-limit --height=14 \
          --header='Individual applications: SPACE select/unselect • ENTER confirm • select none to skip' || true)"
      else
        printf 'Application IDs, comma separated, or Enter to skip: '
        read -r selected_items
        selected_items="$(tr ',' '\n' <<<"$selected_items")"
      fi
      selected_item_ids="$(while IFS=$'\t' read -r id _; do [[ -n "$id" ]] && printf '%s\n' "$id"; done \
        <<<"$selected_items" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
    fi

    final_ids="$(jq -cn --argjson catalog "$catalog" --argjson groups "$selected_group_ids" \
      --argjson items "$selected_item_ids" '
        (([$catalog.items[] | . as $item | select($item.group != null and ($groups | index($item.group)) != null) | .id] + $items) | unique)
      ')"
    if (($(jq 'length' <<<"$final_ids") > 0)); then
      write_profile_provider_packages "$provider_name" "$selected_group_ids" "$selected_item_ids"
      printf 'Selected %s application(s) from %s.\n' "$(jq 'length' <<<"$final_ids")" "$provider_name"
      effective_ids="$final_ids"
    else
      platform=linux
      [[ "$(uname -s)" != Darwin ]] || platform=macos
      config="$ROOT/home-weave.json"
      effective_ids="$(jq -c --arg profile "$PROFILE" --arg platform "$platform" \
        --arg provider "$provider_name" --argjson catalog "$catalog" '
          (.profiles[$profile].platforms[$platform].plugins[$provider] // {}) as $selection
          | (([$catalog.items[] | . as $item
              | select($item.group != null and (($selection.groups // []) | index($item.group)) != null)
              | .id] + ($selection.items // [])) | unique)
        ' "$config")"
      if (($(jq 'length' <<<"$effective_ids") > 0)); then
        printf 'No new selection from %s; retaining %s application(s) already configured by profile %s.\n' \
          "$provider_name" "$(jq 'length' <<<"$effective_ids")" "$PROFILE"
      else
        printf 'No applications selected from %s; this optional provider will be skipped.\n' "$provider_name"
      fi
    fi

    if (($(jq 'length' <<<"$effective_ids") > 0)); then
      printf 'Configured applications from %s:\n' "$provider_name"
      while IFS= read -r id; do
        label="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .name // .id' <<<"$catalog")"
        [[ -n "$label" ]] || label="$id"
        if jq -e --arg id "$id" '.items[] | select(.id == $id and .installed == true)' \
          >/dev/null <<<"$inventory"; then
          state='already installed'
        else
          state='missing; plan/apply will request installation'
        fi
        printf '  %-28s %s\n' "$label" "$state"
      done < <(jq -r '.[]' <<<"$effective_ids")
    fi
  done < <(jq -c '.[]' <<<"$EXTENSIONS_JSON")
}

reconcile_profile_providers() {
  local mode="$1" profiles="$2" profile_json provider_packages provider_name provider command removal_policy
  local failure_policy require_publisher_verification inventory_mode inventory item refreshed id display_name state ownership prior_ownership
  local status='[]' inventory_only degraded=false native_packages native_selected='[]' os_id item_count plan_ok install_status
  local pending_file="$ROOT/.state/provider-status.pending.json" ownership_journal='{"items":[]}' journal
  load_builtin_provider
  profile_json="$(jq -ce --arg profile "$PROFILE" '.[$profile] // empty' <<<"$profiles")" \
    || fail "profile does not exist: $PROFILE"
  for journal in "$pending_file" "$ROOT/.state/provider-status.json"; do
    if [[ -f "$journal" ]] && jq -e --arg profile "$PROFILE" \
      '.schemaVersion == 1 and .profile == $profile and (.items | type == "array")' \
      "$journal" >/dev/null 2>&1; then
      ownership_journal="$(<"$journal")"
      break
    fi
  done
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
    jq -e '.schemaVersion == 2 and (.capabilities | index("inventory")) and (.capabilities | index("install"))
      and ((.failurePolicy // "strict") | IN("strict", "best-effort"))
      and ((.requirePublisherVerification // false) | type == "boolean")' \
      >/dev/null <<<"$provider" || fail "provider $provider_name cannot reconcile profile applications"
    command="$(jq -r '.executable' <<<"$provider")"
    removal_policy="$(jq -r '.removalPolicy // "remove"' <<<"$provider")"
    failure_policy="$(jq -r '.failurePolicy // "strict"' <<<"$provider")"
    require_publisher_verification="$(jq -r '.requirePublisherVerification // false' <<<"$provider")"
    inventory_mode="$(jq -r '.inventoryMode // "complete"' <<<"$provider")"
    [[ "$removal_policy" == remove || "$removal_policy" == retain ]] \
      || fail "provider $provider_name has invalid removalPolicy"
    [[ "$inventory_mode" == complete || "$inventory_mode" == installed-only ]] \
      || fail "provider $provider_name has invalid inventoryMode"
    if [[ ! -x "$command" ]]; then
      [[ "$failure_policy" == best-effort ]] || fail "provider executable is unavailable: $command"
      degraded=true
      while IFS= read -r id; do
        [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "unsafe provider package id: $id"
        warn "provider $provider_name is unavailable; skipped $id and will retry it later"
        item="$(jq -cn --arg id "$id" '{id: $id, name: $id, installed: false}')"
        status="$(jq -cn --argjson items "$status" --argjson item "$item" \
          --arg provider "$provider_name" --arg removalPolicy "$removal_policy" '
            $items + [($item + {provider: $provider, requested: true, state: "provider-unavailable",
              ownership: "none", removalPolicy: $removalPolicy})]
          ')"
      done < <(jq -r --arg provider "$provider_name" '.[$provider][]' <<<"$provider_packages")
      continue
    fi
    if ! inventory="$($command inventory)"; then
      [[ "$failure_policy" == best-effort ]] || fail "provider inventory failed: $provider_name"
      degraded=true
      while IFS= read -r id; do
        [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "unsafe provider package id: $id"
        warn "provider $provider_name inventory failed; skipped $id and will retry it later"
        item="$(jq -cn --arg id "$id" '{id: $id, name: $id, installed: false}')"
        status="$(jq -cn --argjson items "$status" --argjson item "$item" \
          --arg provider "$provider_name" --arg removalPolicy "$removal_policy" '
            $items + [($item + {provider: $provider, requested: true, state: "provider-unavailable",
              ownership: "none", removalPolicy: $removalPolicy})]
          ')"
      done < <(jq -r --arg provider "$provider_name" '.[$provider][]' <<<"$provider_packages")
      continue
    fi
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
      perform_install=false
      replace_existing=false
      [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "unsafe provider package id: $id"
      item_count="$(jq --arg id "$id" '[.items[] | select(.id == $id)] | length' <<<"$inventory")"
      if [[ "$item_count" == 0 && "$inventory_mode" == installed-only ]]; then
        item="$(jq -cn --arg id "$id" '{id: $id, name: $id, installed: false}')"
      elif [[ "$item_count" == 0 && "$failure_policy" == best-effort ]]; then
        degraded=true
        warn "provider $provider_name does not expose $id; skipped it and will retry it later"
        item="$(jq -cn --arg id "$id" '{id: $id, name: $id, installed: false}')"
        state=unavailable
        ownership=none
        status="$(jq -cn --argjson items "$status" --argjson item "$item" \
          --arg provider "$provider_name" --arg state "$state" --arg ownership "$ownership" \
          --arg removalPolicy "$removal_policy" '
            $items + [($item + {provider: $provider, requested: true, state: $state,
              ownership: $ownership, removalPolicy: $removalPolicy})]
        ')"
        continue
      else
        [[ "$item_count" == 1 ]] || fail "provider $provider_name must expose exactly one inventory item for $id"
        item="$(jq -c --arg id "$id" '.items[] | select(.id == $id)' <<<"$inventory")"
      fi
      display_name="$(jq -r '.name // .id' <<<"$item")"
      if [[ "$(jq -r '.installed // false' <<<"$item")" == true \
        && "$require_publisher_verification" == true \
        && "$(jq -r '.publisherVerified // false' <<<"$item")" != true ]]; then
        fail "provider $provider_name reported an unverified publisher for installed item $id"
      fi
      if [[ "$(jq -r '.preexistingCommand // false' <<<"$item")" == true ]]; then
        plan_ok=true
        "$command" plan --action install "$id" || plan_ok=false
        if ! "$plan_ok" && [[ "$failure_policy" == best-effort ]]; then
          state=plan-failed; ownership=none; degraded=true
          warn "provider $provider_name could not plan replacement of $id; skipped it and will retry it later"
        elif ! "$plan_ok"; then
          fail "provider $provider_name could not plan replacement of $id"
        elif [[ "$mode" == plan ]]; then
          state=planned-replacement
          ownership=none
        elif confirm "Replace the existing $display_name command through $provider_name (the original will be preserved)?"; then
          perform_install=true
          replace_existing=true
        else
          state=preexisting
          ownership=provider
          degraded=true
          printf '  [%-18s] %-24s warning: pre-existing command retained; continuing with remaining items\n' \
            "$provider_name" "$display_name"
        fi
      elif [[ "$(jq -r '.conflict // false' <<<"$item")" == true ]]; then
        plan_ok=true
        "$command" plan --action install "$id" || plan_ok=false
        if ! "$plan_ok" && [[ "$failure_policy" == best-effort ]]; then
          state=plan-failed; ownership=none; degraded=true
          warn "provider $provider_name could not plan replacement of $id; skipped it and will retry it later"
        elif ! "$plan_ok"; then
          fail "provider $provider_name could not plan replacement of $id"
        elif [[ "$mode" == plan ]]; then
          state=planned-replacement
          ownership=none
        elif confirm "Replace the conflicting $display_name destination through $provider_name (the original will be preserved)?"; then
          perform_install=true
          replace_existing=true
        else
          state=conflict
          ownership=provider
          degraded=true
          printf '  [%-18s] %-24s warning: conflicting destination retained; continuing with remaining items\n' \
            "$provider_name" "$display_name"
        fi
      elif [[ "$(jq -r '.installed // false' <<<"$item")" == true ]]; then
        prior_ownership="$(jq -r --arg provider "$provider_name" --arg id "$id" \
          '[.items[] | select(.provider == $provider and .id == $id) | .ownership] | last // "none"' \
          <<<"$ownership_journal")"
        if [[ "$prior_ownership" == home-weave ]]; then
          state=installed
          ownership=home-weave
          printf '  [%-18s] %-24s already installed (HomeWeave-owned)\n' "$provider_name" "$display_name"
        else
          state=preexisting
          ownership=provider
          printf '  [%-18s] %-24s already installed\n' "$provider_name" "$display_name"
        fi
      else
        plan_ok=true
        "$command" plan --action install "$id" || plan_ok=false
        if ! "$plan_ok" && [[ "$failure_policy" == best-effort ]]; then
          state=plan-failed; ownership=none; degraded=true
          warn "provider $provider_name could not plan installation of $id; skipped it and will retry it later"
        elif ! "$plan_ok"; then
          fail "provider $provider_name could not plan installation of $id"
        elif [[ "$mode" == plan ]]; then
          state=planned
          ownership=none
        elif confirm "Install $display_name through $provider_name?"; then
          perform_install=true
        else
          state=declined
          ownership=none
          degraded=true
          printf '  [%-18s] %-24s declined; profile will be marked degraded\n' "$provider_name" "$display_name"
        fi
      fi
      if "$perform_install"; then
        install_status=0
        if "$replace_existing"; then
          HOME_WEAVE_VERIFIED_REPLACE_EXISTING=1 "$command" apply --action install "$id" \
            || install_status=$?
        else
          "$command" apply --action install "$id" || install_status=$?
        fi
        if [[ "$install_status" != 0 && "$failure_policy" == best-effort ]]; then
          state=install-failed
          ownership=provider
          degraded=true
          warn "provider $provider_name failed to install $id; continuing and will retry it later"
        elif [[ "$install_status" != 0 ]]; then
          fail "provider $provider_name failed to install $id"
        else
          refreshed="$($command inventory)" || fail "provider inventory failed after installing $id"
          jq -e '.schemaVersion == 1 and (.items | type == "array")' >/dev/null <<<"$refreshed" \
            || fail "provider $provider_name returned invalid inventory after installing $id"
          item_count="$(jq --arg id "$id" '[.items[] | select(.id == $id)] | length' <<<"$refreshed")"
          [[ "$item_count" -le 1 ]] || fail "provider $provider_name returned ambiguous inventory for $id"
          if [[ "$item_count" == 0 || "$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .installed // false' <<<"$refreshed")" != true ]]; then
            if [[ "$failure_policy" == best-effort ]]; then
              state=not-detected
              ownership=provider
              degraded=true
              warn "provider $provider_name did not detect $id after installation; continuing and will retry it later"
            else
              fail "provider $provider_name did not verify $id after installation"
            fi
          else
            item="$(jq -c --arg id "$id" '.items[] | select(.id == $id)' <<<"$refreshed")"
            if [[ "$require_publisher_verification" == true \
              && "$(jq -r '.publisherVerified // false' <<<"$item")" != true ]]; then
              fail "provider $provider_name reported an unverified publisher after installing $id"
            fi
            if "$replace_existing" && [[ "$(jq -r '.publisherVerified // false' <<<"$item")" != true ]]; then
              fail "provider $provider_name did not verify the replacement for $id"
            fi
            inventory="$refreshed"
            state=installed
            ownership=home-weave
          fi
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

  if "$degraded"; then
    warn "provider reconciliation is degraded; unresolved applications will be retried on the next plan or apply"
  fi

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
  local candidate relative answer target bundled lookup_relative
  local candidates=()
  [[ -t 0 ]] || return 0
  printf '\nHomeWeave can adopt selected existing configurations.\n'
  mkdir -p "$ROOT/.state" "$ROOT/dotfiles/custom"
  : >"$ROOT/.state/adoptions"
  candidates=(
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.gitconfig" \
    "$HOME/.home_weave_profile" \
    "$HOME/.config"/* "$HOME/.configs"/*
  )
  if [[ "$(uname -s)" == Darwin ]]; then
    candidates+=("$HOME/Library/Application Support/nushell")
  fi
  for candidate in "${candidates[@]}"; do
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
    # Repositories always store Nushell under .config/nushell, while macOS
    # runs it from Library/Application Support/nushell. If both live paths
    # exist, offer only the native path below: adopting it still writes the
    # canonical repository location, and the legacy XDG path is retained.
    if [[ "$(uname -s)" == Darwin \
      && "$relative" == ".config/nushell" \
      && ( -e "$HOME/Library/Application Support/nushell" \
        || -L "$HOME/Library/Application Support/nushell" ) ]]; then
      warn "retaining legacy ~/.config/nushell; macOS setup will reconcile the native Nushell path"
      continue
    fi
    lookup_relative="$relative"
    [[ "$relative" != "Library/Application Support/nushell" ]] \
      || lookup_relative=".config/nushell"
    printf '\nConfiguration: ~/%s\n' "$relative"
    bundled=""
    if [[ -n "$BUNDLED_DOTFILES" && -d "$BUNDLED_DOTFILES" ]]; then
      bundled="$(find "$BUNDLED_DOTFILES" -path "*/$lookup_relative" -print -quit 2>/dev/null || true)"
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
        # Keep repository content canonical even when the host uses a native
        # platform destination. The adoption manifest retains the native path
        # so backup/restore still operates on the file the user selected.
        target="$ROOT/dotfiles/custom/$lookup_relative"
        mkdir -p "$(dirname "$target")"
        if [[ "$lookup_relative" == ".config/nushell" && -d "$candidate" ]]; then
          mkdir -p "$target"
          rsync --archive --exclude='history.*' "$candidate/" "$target/"
        else
          cp -a "$candidate" "$target"
        fi
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

render_profile_readme() {
  local rendered="$ROOT/README.md.rendered.$$"
  [[ -f "$ROOT/README.md" ]] || return 0
  sed "s/@PROFILE@/$PROFILE/g" "$ROOT/README.md" >"$rendered"
  mv "$rendered" "$ROOT/README.md"
}

confirm_without_assume_yes() {
  local prompt="$1" answer
  [[ -t 0 ]] || return 1
  printf '%s [y/N] ' "$prompt"
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]]
}

initialize_git() {
  local candidate message branch staging default_branch identity_name identity_email confirmation
  local branch_exists=false should_publish=false
  local publish_paths=(flake.nix flake.lock home-weave home-weave.json packages.json nix dotfiles extensions README.md SECURITY.md setup.sh home.nix overlay.nix .gitignore)
  "$NO_GIT" && return 0
  require_commands git rsync
  scan_secrets "$ROOT"

  if [[ -z "$REMOTE_URL" && -t 0 ]]; then
    printf 'Existing private GitHub/GitLab SSH remote URL (optional): '
    read -r REMOTE_URL
  fi

  if [[ -z "$REMOTE_URL" ]]; then
    "$PUBLISH" && fail "--publish requires --remote"
    [[ -d "$ROOT/.git" ]] || git -C "$ROOT" init --quiet --initial-branch=main
    printf 'Git repository initialized at %s. Review files before committing or pushing.\n' "$ROOT"
    if confirm_without_assume_yes "Create the initial HomeWeave commit?"; then
      for candidate in "${publish_paths[@]}"; do
        [[ -e "$ROOT/$candidate" ]] && git -C "$ROOT" add -- "$candidate"
      done
      git -C "$ROOT" diff --cached --check
      if ! git -C "$ROOT" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
        printf 'Git author name: '
        read -r identity_name
        printf 'Git author email: '
        read -r identity_email
        [[ -n "$identity_name" && -n "$identity_email" ]] || fail "Git author name and email are required"
        git -C "$ROOT" config user.name "$identity_name"
        git -C "$ROOT" config user.email "$identity_email"
      fi
      printf 'Commit message [Initialize HomeWeave]: '
      read -r message
      git -C "$ROOT" commit -m "${message:-Initialize HomeWeave}"
    fi
    return 0
  fi

  [[ "$REMOTE_URL" != *$'\n'* ]] || fail "invalid remote URL"
  if [[ -z "$REMOTE_BRANCH" ]]; then
    if [[ -t 0 ]]; then
      printf 'Target branch [main]: '
      read -r REMOTE_BRANCH
      REMOTE_BRANCH="${REMOTE_BRANCH:-main}"
    else
      REMOTE_BRANCH=main
    fi
  fi
  git check-ref-format --branch "$REMOTE_BRANCH" >/dev/null 2>&1 \
    || fail "invalid Git branch name: $REMOTE_BRANCH"
  git ls-remote "$REMOTE_URL" >/dev/null \
    || fail "remote repository is unavailable; create it and verify access before setup: $REMOTE_URL"

  branch="$REMOTE_BRANCH"
  staging="$ROOT/.state/git-publish.$$"
  rm -rf "$staging"
  if git ls-remote --exit-code --heads "$REMOTE_URL" "refs/heads/$branch" >/dev/null 2>&1; then
    branch_exists=true
    git clone --quiet --single-branch --branch "$branch" "$REMOTE_URL" "$staging" \
      || fail "could not clone existing remote branch: $branch"
  else
    default_branch="$(git ls-remote --symref "$REMOTE_URL" HEAD 2>/dev/null \
      | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -n 1)"
    if [[ -n "$default_branch" ]]; then
      git clone --quiet --single-branch --branch "$default_branch" "$REMOTE_URL" "$staging" \
        || fail "could not clone remote default branch: $default_branch"
      git -C "$staging" switch --quiet -c "$branch"
    else
      mkdir -p "$staging"
      git -C "$staging" init --quiet --initial-branch="$branch"
      git -C "$staging" remote add origin "$REMOTE_URL"
    fi
  fi

  git -C "$staging" rm -r --ignore-unmatch -- . >/dev/null 2>&1 || true
  find "$staging" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  for candidate in "${publish_paths[@]}"; do
    [[ -e "$ROOT/$candidate" || -L "$ROOT/$candidate" ]] || continue
    if [[ -d "$ROOT/$candidate" && ! -L "$ROOT/$candidate" ]]; then
      rsync -a "$ROOT/$candidate" "$staging/"
    else
      cp -a "$ROOT/$candidate" "$staging/"
    fi
  done
  scan_secrets "$staging"
  git -C "$staging" add -A
  git -C "$staging" diff --cached --check
  printf '\nGenerated Git changes for %s branch %s:\n' "$REMOTE_URL" "$branch"
  git -C "$staging" status --short

  if "$PUBLISH" || confirm_without_assume_yes "Commit and push these generated files now?"; then
    should_publish=true
  fi
  if ! "$should_publish"; then
    git -C "$staging" reset --quiet 2>/dev/null || true
    rm -rf "$ROOT/.git"
    mv "$staging/.git" "$ROOT/.git"
    rm -rf "$staging"
    printf 'Remote %s is configured on branch %s; generated changes remain uncommitted.\n' \
      "$REMOTE_URL" "$branch"
    return 0
  fi

  if "$branch_exists" && ! git -C "$staging" diff --cached --quiet; then
    printf '\nPublishing will replace tracked content on branch %s.\n' "$branch"
    git -C "$staging" diff --cached --stat
    printf 'Type the complete phrase shown below exactly:\n'
    printf '  REPLACE %s %s\n' "$REMOTE_URL" "$branch"
    [[ -t 0 ]] || fail "publishing replacement content requires interactive typed confirmation"
    printf 'Confirmation: '
    read -r confirmation
    [[ "$confirmation" == "REPLACE $REMOTE_URL $branch" ]] \
      || fail "remote replacement confirmation did not match"
  fi

  if ! git -C "$staging" diff --cached --quiet; then
    if ! git -C "$staging" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
      [[ -t 0 ]] || fail "Git author identity is missing; configure user.name and user.email"
      printf 'Git author name: '
      read -r identity_name
      printf 'Git author email: '
      read -r identity_email
      [[ -n "$identity_name" && -n "$identity_email" ]] \
        || fail "Git author name and email are required"
      git -C "$staging" config user.name "$identity_name"
      git -C "$staging" config user.email "$identity_email"
    fi
    if [[ -t 0 ]]; then
      printf 'Commit message [Initialize HomeWeave]: '
      read -r message
    fi
    git -C "$staging" commit -m "${message:-Initialize HomeWeave}"
  else
    printf 'Generated HomeWeave files already match remote branch %s.\n' "$branch"
  fi

  if git -C "$staging" rev-parse --verify HEAD >/dev/null 2>&1; then
    printf 'Pushing branch %s without force...\n' "$branch"
    git -C "$staging" push -u origin "HEAD:refs/heads/$branch" \
      || fail "push was rejected; remote changed or is not writable, and HomeWeave will not force-push"
  fi
  rm -rf "$ROOT/.git"
  mv "$staging/.git" "$ROOT/.git"
  rm -rf "$staging"
  printf 'Git repository synchronized with %s branch %s.\n' "$REMOTE_URL" "$branch"
}
profile_metadata() {
  nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profilesBySystem.\"$(current_nix_system)\""
}

home_weave_package_profile() {
  printf '%s/nix/profiles/home-weave\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

package_profile_generation() {
  local profile="$1" target
  [[ -L "$profile" ]] || return 0
  target="$(readlink "$profile" 2>/dev/null || true)"
  target="$(basename "$target")"
  if [[ "$target" =~ ^home-weave-([0-9]+)-link$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

guard_legacy_home_manager() {
  local legacy_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
  if [[ -e "$legacy_profile" || -L "$legacy_profile" ]]; then
    fail "an active legacy Home Manager profile was found at $legacy_profile; remove the old HomeWeave installation before using this breaking release"
  fi
}

read_package_profile_pending() {
  local pending="$ROOT/.state/package-profile-pending.json" expected actual_store actual_generation
  expected="$(home_weave_package_profile)"
  [[ -r "$pending" ]] || fail "package profile activation state is missing: $pending"
  jq -e --arg expected "$expected" '
    .schemaVersion == 1
    and .profilePath == $expected
    and (.currentGeneration | type == "number")
    and (.currentStorePath | type == "string" and length > 0)
    and ((.previousGeneration == null) or (.previousGeneration | type == "number"))
    and ((.previousStorePath == null) or (.previousStorePath | type == "string"))
  ' "$pending" >/dev/null || fail "package profile activation state is invalid"
  actual_store="$(readlink -f "$expected" 2>/dev/null || true)"
  actual_generation="$(package_profile_generation "$expected")"
  [[ "$actual_store" == "$(jq -r '.currentStorePath' "$pending")" ]] \
    || fail "package profile activation state does not match the active store path"
  [[ "$actual_generation" == "$(jq -r '.currentGeneration | tostring' "$pending")" ]] \
    || fail "package profile activation state does not match the active generation"
  jq -c '. + {backend: "nix-profile"}' "$pending"
}

record_receipt() {
  local receipts="$ROOT/.state/receipts" timestamp receipt temporary previous profiles system revision seen_profiles
  local inventory='[]' preflight='{}' dotfiles='[]' casks='[]' providers='[]' plugins='{}' provider_status='{}' provider_status_file parent_chain='[]' cursor parent
  local package_profile changes
  profiles="${1:?resolved profile metadata is required}"
  system="${2:?resolved Nix system is required}"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  receipt="$receipts/${timestamp//:/-}.json"
  temporary="$receipt.tmp.$$"
  mkdir -p "$receipts"
  printf 'Recording activation receipt...\n'
  plugins="$(jq -c --arg profile "$PROFILE" '.[$profile].pluginContributions // {}' <<<"$profiles")"
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
  seen_profiles="|$PROFILE|"
  while :; do
    parent="$(jq -r --arg profile "$cursor" '.[$profile].extends // empty' <<<"$profiles")"
    [[ -n "$parent" ]] || break
    [[ "$parent" != "$cursor" ]] || break
    jq -e --arg profile "$parent" 'has($profile)' >/dev/null <<<"$profiles" \
      || fail "profile $cursor extends missing profile: $parent"
    [[ "$seen_profiles" != *"|$parent|"* ]] \
      || fail "profile inheritance cycle detected at $parent"
    parent_chain="$(jq -cn --argjson chain "$parent_chain" --arg parent "$parent" '$chain + [$parent]')"
    seen_profiles+="$parent|"
    cursor="$parent"
  done
  package_profile="$(read_package_profile_pending)"
  previous=""
  [[ ! -L "$receipts/latest" ]] || previous="$(readlink -f "$receipts/latest" 2>/dev/null || true)"
  [[ -z "$previous" || ! -r "$previous" ]] || jq -e '.schemaVersion == 2' "$previous" >/dev/null 2>&1 || previous=""
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
    --argjson plugins "$plugins" --argjson dotfiles "$dotfiles" --argjson changes "$changes" \
    --argjson packageProfile "$package_profile" \
    '{schemaVersion: 2, timestamp: $timestamp, activeProfile: $profile,
      parentChain: $parentChain, system: $system, shell: $shell, nixpkgsRevision: $revision,
      packages: $packages, build: $preflight,
      plugins: $plugins,
      applications: {homebrew: $casks, native: [], providers: $providers},
      providerDegraded: ($providerStatus.degraded // false), dotfiles: $dotfiles,
      changes: $changes,
      packageProfile: $packageProfile,
      rollback: {previousPackageGeneration: $packageProfile.previousGeneration,
        previousPackageStorePath: $packageProfile.previousStorePath,
        previousStowGeneration: "dotfiles/current.previous"}}' \
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
    "Plugins: \((.plugins // {}) | keys | if length == 0 then "none" else join(", ") end)",
    "Managed dotfiles:",
    (.dotfiles[] | "  \(.destination) <- \(.source) [\(.sourceLayer)]"),
    "Changes: +\(.changes.added | length) -\(.changes.removed | length) ~\(.changes.changed | length) retained \(.changes.retained | length)",
    "Rollback package generation: \(.rollback.previousPackageGeneration // "none")"' "$receipt"
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
      if jq -e --arg profile "$PROFILE" '.schemaVersion == 2 and .activeProfile == $profile' "$candidate" >/dev/null 2>&1; then receipt="$candidate"; break; fi
    done < <(find "$ROOT/.state/receipts" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort -r)
  elif [[ -L "$ROOT/.state/receipts/latest" ]]; then
    receipt="$(readlink -f "$ROOT/.state/receipts/latest")"
  fi
  [[ -z "$receipt" || ! -r "$receipt" ]] || jq -e '.schemaVersion == 2' "$receipt" >/dev/null 2>&1 || receipt=""
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
    "  Plugins:        \((.plugins // {}) | keys | if length == 0 then "none" else join(", ") end)",
    "  Managed apps:   \([.applications[] | length] | add)",
    "  Provider state: \(if .providerDegraded then "degraded" else "complete" end)",
    "  Managed files:  \(.dotfiles | length)",
    "  Changes:        +\(.changes.added | length) -\(.changes.removed | length) ~\(.changes.changed | length) =\(.changes.retained | length)",
    "  Package profile: \(.packageProfile.profilePath)",
    "  Package store:   \(.packageProfile.currentStorePath)",
    "  Generation:      \(.packageProfile.currentGeneration)",
    "  Rollback:        \(.rollback.previousPackageGeneration // "none")"' "$receipt"
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

snapshot_provider_extensions() {
  local destination="$1" provider name command output platform temporary config="$destination/home-weave.json"
  load_builtin_provider
  platform=linux
  [[ "$(uname -s)" != Darwin ]] || platform=macos
  mkdir -p "$destination/metadata"
  while IFS= read -r provider; do
    jq -e '.schemaVersion == 2 and (.capabilities | index("snapshot"))' \
      >/dev/null <<<"$provider" || continue
    name="$(jq -r '.name' <<<"$provider")"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "unsafe snapshot provider name: $name"
    command="$(jq -r '.executable' <<<"$provider")"
    [[ -x "$command" ]] || fail "snapshot provider executable is unavailable: $command"
    output="$($command snapshot)" || fail "provider snapshot failed: $name"
    jq -e '.schemaVersion == 1 and (.selectedPackages | type == "array") and (.inventory | type == "object")' \
      >/dev/null <<<"$output" || fail "provider $name returned an invalid snapshot"
    printf '%s\n' "$output" | jq '.' >"$destination/metadata/provider-$name.json"
    temporary="$config.tmp.$$"
    jq --arg profile "$PROFILE" --arg platform "$platform" --arg provider "$name" \
      --argjson selected "$(jq -c '.selectedPackages' <<<"$output")" '
        .profiles[$profile].platforms = (.profiles[$profile].platforms // {})
        | .profiles[$profile].platforms[$platform] = (.profiles[$profile].platforms[$platform] // {})
        | .profiles[$profile].platforms[$platform].plugins = (.profiles[$profile].platforms[$platform].plugins // {})
        | .profiles[$profile].platforms[$platform].plugins[$provider] =
            {enabled: true, groups: [], items: $selected}
      ' "$config" >"$temporary"
    mv "$temporary" "$config"
    temporary="$destination/snapshot.json.tmp.$$"
    jq --arg provider "$name" --argjson snapshot "$output" \
      '.providerSnapshots = (.providerSnapshots // {}) | .providerSnapshots[$provider] = $snapshot' \
      "$destination/snapshot.json" >"$temporary"
    mv "$temporary" "$destination/snapshot.json"
  done < <(jq -c '.[]' <<<"$EXTENSIONS_JSON")
}

snapshot_create() {
  local destination="${POSITIONAL_ARGS[1]:-$HOME/home-weave-snapshot-$(date -u +%Y%m%dT%H%M%SZ)}"
  local receipt='{}' receipt_file="" profiles external='[]' timestamp
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
    receipt_file="$(readlink -f "$ROOT/.state/receipts/latest" 2>/dev/null || true)"
    if [[ -r "$receipt_file" ]] && jq -e '.schemaVersion == 2' "$receipt_file" >/dev/null 2>&1; then
      receipt="$(jq -c '.' "$receipt_file")"
    fi
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
  snapshot_provider_extensions "$destination"
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
  local current_json target_json field catalog old_packages new_packages profile_delta
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
      profile_delta="$(inheritance_profile_delta "$EXTENDS")"
      jq --arg name "$name" --argjson profileDelta "$profile_delta" \
        '.profiles[$name] = $profileDelta' \
        "$file" >"$file.tmp.$$"
      mv "$file.tmp.$$" "$file"
      printf 'Created profile %s extending %s.\n' "$name" "$EXTENDS"
      printf '\nNext steps:\n'
      printf '  cd %q\n' "$ROOT"
      printf '  vi home-weave.json\n'
      printf '  ./home-weave config validate\n'
      printf '  ./home-weave profile diff %q\n' "$name"
      printf '  ./home-weave profile switch %q\n' "$name"
      ;;
    diff)
      [[ -n "$name" ]] || fail "profile diff requires a name"; validate_name "$name"
      target_json="$(jq -ce --arg name "$name" '.[$name]' <<<"$profiles")" || fail "profile does not exist: $name"
      current_json="$(jq -c --arg name "${active:-base}" '.[$name] // {}' <<<"$profiles")"
      printf 'Profile diff: %s -> %s\n' "${active:-none}" "$name"
      old_packages="$(jq -cn --argjson profile "$current_json" \
        '((($profile.shells // []) + ($profile.nixPackages // [])) | unique)')"
      new_packages="$(jq -cn --argjson profile "$target_json" \
        '((($profile.shells // []) + ($profile.nixPackages // [])) | unique)')"
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
        ["homebrewFormulae", "homebrewCasks", "apt", "pacman"][] as $manager
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
  local mode="$1" profiles selected_shell system setup_args=() setup_command=()
  guard_legacy_home_manager
  start_operation_log "$mode"
  set_operation_phase profile-evaluation
  read_state
  [[ -f "$ROOT/flake.nix" ]] || fail "$ROOT is not a HomeWeave profile"
  system="$(current_nix_system)"
  profiles="$(nix --extra-experimental-features 'nix-command flakes' \
    eval --json "path:$ROOT#lib.setup.profilesBySystem.\"$system\"" 2>/dev/null || printf '{}')"
  selected_shell="$(jq -r --arg profile "$PROFILE" '.[$profile].primaryShell // empty' <<<"$profiles")"
  [[ -z "$selected_shell" ]] || PRIMARY_SHELL="$selected_shell"
  "$ASSUME_YES" && setup_args+=(--yes)
  if [[ "$mode" == plan ]]; then
    set_operation_phase nix-preflight
    if [[ -f "$ROOT/setup.sh" ]]; then
      setup_command=(bash "$ROOT/setup.sh")
    else
      setup_command=(nix --extra-experimental-features 'nix-command flakes' run "path:$ROOT#setup" -- --config-url "path:$ROOT")
    fi
    if ! HOME_WEAVE_DATA_ROOT="$ROOT/.state" NIX_CONFIG_DIR="$ROOT/.state/generated" \
      run_logged "${setup_command[@]}" --profile "$PROFILE" --shell "$PRIMARY_SHELL" --generate-only "${setup_args[@]}"; then
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
    if [[ -f "$ROOT/setup.sh" ]]; then
      setup_command=(bash "$ROOT/setup.sh")
    else
      setup_command=(nix --extra-experimental-features 'nix-command flakes' run "path:$ROOT#setup" -- --config-url "path:$ROOT")
    fi
    if HOME_WEAVE_DATA_ROOT="$ROOT/.state" \
      HOME_WEAVE_SKIPPED_DOTFILES_FILE="$ROOT/.state/skipped-dotfiles" \
      NIX_CONFIG_DIR="$ROOT/.state/generated" \
      run_logged "${setup_command[@]}" --profile "$PROFILE" --shell "$PRIMARY_SHELL" "${setup_args[@]}"; then
      set_operation_phase receipt
      record_receipt "$profiles" "$system" || fail "activation succeeded but receipt creation failed"
      rm -f "$ROOT/.state/package-profile-pending.json"
      : >"$ROOT/.state/adoptions"
      if [[ -f "$ROOT/.state/provider-status.pending.json" ]]; then
        mv "$ROOT/.state/provider-status.pending.json" "$ROOT/.state/provider-status.json"
      fi
      date -u +%Y%m%dT%H%M%SZ >"$ROOT/.state/applied"
      write_state
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
      jq -e '.schemaVersion == 2' "$receipt" >/dev/null 2>&1 || continue
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

prune_empty_dotfile_parents() {
  local path="$1" parent
  parent="$(dirname "$path")"
  while [[ "$parent" == "$HOME/"* ]]; do
    case "$parent" in
      "$HOME/.config"|"$HOME/.local"|"$HOME/.local/bin"|"$HOME/Library"|\
      "$HOME/Library/Application Support"|"$HOME/Library/Application Support/nushell")
        break
        ;;
    esac
    rmdir "$parent" 2>/dev/null || break
    parent="$(dirname "$parent")"
  done
}

is_home_weave_artifact_link() {
  local link="$1" raw candidate
  [[ -L "$link" ]] || return 1
  raw="$(readlink "$link")" || return 1
  if [[ "$raw" == /* ]]; then
    candidate="$raw"
  else
    candidate="$(dirname "$link")/$raw"
  fi
  candidate="$(normalize_absolute_path "$candidate")" || return 1
  case "$candidate" in
    "$HOME/"*/.state/dotfiles/current|"$HOME/"*/.state/dotfiles/current/*)
      return 0
      ;;
    /nix/store/*-home-manager-files/.config/shell/conf.d/home-weave-*)
      return 0
      ;;
  esac
  return 1
}

collect_home_weave_artifact_links() {
  local scan_root link
  for scan_root in \
    "$HOME" \
    "$HOME/.config" \
    "$HOME/.local/bin" \
    "$HOME/Library/Application Support/nushell"; do
    [[ -d "$scan_root" ]] || continue
    if [[ "$scan_root" == "$HOME" ]]; then
      while IFS= read -r -d '' link; do
        is_home_weave_artifact_link "$link" && printf '%s\0' "$link"
      done < <(find "$scan_root" -maxdepth 1 -type l -print0 2>/dev/null)
    else
      while IFS= read -r -d '' link; do
        is_home_weave_artifact_link "$link" && printf '%s\0' "$link"
      done < <(find "$scan_root" -type l -print0 2>/dev/null)
    fi
  done
}

cleanup_home_weave_artifact_links() {
  local link existing duplicate
  local links=()
  while IFS= read -r -d '' link; do
    duplicate=false
    for existing in "${links[@]-}"; do
      if [[ "$existing" == "$link" ]]; then
        duplicate=true
        break
      fi
    done
    "$duplicate" || links+=("$link")
  done < <(collect_home_weave_artifact_links)

  if ((${#links[@]} == 0)); then
    printf 'No legacy HomeWeave artifact links were found.\n'
    return 0
  fi
  printf 'Legacy HomeWeave artifact links:\n'
  for link in "${links[@]}"; do
    printf '  %s -> %s\n' "$link" "$(readlink "$link")"
  done
  if "$DRY_RUN"; then
    printf 'Would remove %d legacy HomeWeave artifact link(s).\n' "${#links[@]}"
    return 0
  fi
  for link in "${links[@]}"; do
    if is_home_weave_artifact_link "$link"; then
      rm "$link"
      prune_empty_dotfile_parents "$link"
    else
      warn "link changed during cleanup and was retained: $link"
    fi
  done
  printf 'Removed %d legacy HomeWeave artifact link(s).\n' "${#links[@]}"
}

cleanup_empty_managed_directories() {
  local generation directory relative destination removed=0
  for generation in "$ROOT/.state/dotfiles/current" "$UNINSTALLED_DOTFILE_GENERATION"; do
    [[ -n "$generation" && -d "$generation" ]] || continue
    while IFS= read -r -d '' directory; do
      relative="${directory#"$generation"/}"
      [[ "$relative" != "$directory" ]] || continue
      destination="$HOME/$relative"
      [[ -d "$destination" && ! -L "$destination" ]] || continue
      "$DRY_RUN" && continue
      if rmdir "$destination" 2>/dev/null; then
        ((removed += 1))
      fi
    done < <(find "$generation" -depth -type d -print0)
  done
  "$DRY_RUN" || printf 'Removed %d empty HomeWeave-managed directories.\n' "$removed"
}

cleanup_home_weave_external_state() {
  local path profile_dir entry existing duplicate launcher
  local paths=(
    "${XDG_CONFIG_HOME:-$HOME/.config}/home-weave"
    "${XDG_DATA_HOME:-$HOME/.local/share}/home-weave"
    "${XDG_STATE_HOME:-$HOME/.local/state}/home-weave"
    "${XDG_CACHE_HOME:-$HOME/.cache}/home-weave"
    "$HOME/.config/home-weave"
    "$HOME/.local/share/home-weave"
    "$HOME/.local/state/home-weave"
    "$HOME/.cache/home-weave"
  )
  local unique_paths=()
  for path in "${paths[@]}"; do
    duplicate=false
    for existing in "${unique_paths[@]-}"; do
      [[ "$existing" != "$path" ]] || { duplicate=true; break; }
    done
    "$duplicate" || unique_paths+=("$path")
  done

  for path in "${unique_paths[@]}"; do
    [[ -e "$path" || -L "$path" ]] || continue
    if "$DRY_RUN"; then
      printf 'Would remove HomeWeave external state: %s\n' "$path"
    else
      rm -rf -- "$path"
      printf 'Removed HomeWeave external state: %s\n' "$path"
    fi
  done

  launcher="$(active_root_launcher_path)"
  if [[ -f "$launcher" ]] && grep -Fqx '# HomeWeave active-root launcher' "$launcher"; then
    if "$DRY_RUN"; then
      printf 'Would remove root-aware HomeWeave launcher: %s\n' "$launcher"
    else
      rm -f "$launcher"
      printf 'Removed root-aware HomeWeave launcher: %s\n' "$launcher"
    fi
  fi

  profile_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles"
  [[ -d "$profile_dir" ]] || return 0
  while IFS= read -r -d '' entry; do
    if "$DRY_RUN"; then
      printf 'Would remove HomeWeave package-profile artifact: %s\n' "$entry"
    else
      rm -f -- "$entry"
      printf 'Removed HomeWeave package-profile artifact: %s\n' "$entry"
    fi
  done < <(find "$profile_dir" -maxdepth 1 \
    \( -name home-weave -o -name 'home-weave-*-link' \) -print0)
}

uninstall_package_profile() {
  local profile receipt="" receipt_store receipt_generation actual_store actual_generation profile_dir profile_name
  profile="$(home_weave_package_profile)"
  if [[ ! -e "$profile" && ! -L "$profile" ]]; then
    printf 'No active HomeWeave Nix package profile was found.\n'
    return
  fi
  if [[ -L "$ROOT/.state/receipts/latest" ]]; then
    receipt="$(readlink -f "$ROOT/.state/receipts/latest" 2>/dev/null || true)"
  fi
  [[ -n "$receipt" && -r "$receipt" ]] \
    || fail "the active HomeWeave Nix package profile has no receipt ownership evidence; refusing to remove it"
  jq -e --arg profile "$profile" '
    .schemaVersion == 2
    and .packageProfile.backend == "nix-profile"
    and .packageProfile.profilePath == $profile
    and (.packageProfile.currentGeneration | type == "number")
    and (.packageProfile.currentStorePath | type == "string" and length > 0)
  ' "$receipt" >/dev/null \
    || fail "the latest receipt is not schema v2 ownership evidence for the active HomeWeave Nix package profile"
  receipt_store="$(jq -r '.packageProfile.currentStorePath' "$receipt")"
  receipt_generation="$(jq -r '.packageProfile.currentGeneration | tostring' "$receipt")"
  actual_store="$(readlink -f "$profile" 2>/dev/null || true)"
  actual_generation="$(package_profile_generation "$profile")"
  [[ "$actual_store" == "$receipt_store" && "$actual_generation" == "$receipt_generation" ]] \
    || fail "the latest receipt does not own the current HomeWeave Nix package profile generation; refusing to remove another environment"
  printf 'HomeWeave will remove its receipt-owned Nix package profile: %s\n' "$profile"
  "$DRY_RUN" && return 0
  require_commands nix
  nix --extra-experimental-features 'nix-command flakes' \
    profile remove --profile "$profile" --all
  nix --extra-experimental-features 'nix-command flakes' \
    profile wipe-history --profile "$profile"
  profile_dir="$(dirname "$profile")"
  profile_name="$(basename "$profile")"
  rm -f -- "$profile"
  find "$profile_dir" -maxdepth 1 -type l -name "$profile_name-[0-9]*-link" \
    -exec rm -f -- {} +
  rm -f "$ROOT/.state/applied"
  printf 'HomeWeave Nix package profile removed. Nix itself was not removed.\n'
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
  local retained='{}' retained_ids
  load_builtin_provider
  if [[ -s "$status_file" ]]; then
    while IFS= read -r item; do
      provider_name="$(jq -r '.provider' <<<"$item")"
      id="$(jq -r '.id' <<<"$item")"
      removal_policy="$(jq -r '.removalPolicy // "remove"' <<<"$item")"
      ownership="$(jq -r '.ownership // "provider"' <<<"$item")"
      [[ "$removal_policy" != retain ]] || {
        retained="$(jq -cn --argjson retained "$retained" --arg provider "$provider_name" --arg id "$id" '
          $retained | .[$provider] = (((.[$provider] // []) + [$id]) | unique | sort)
        ')"
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
    while IFS= read -r provider_name; do
      retained_ids="$(jq -r --arg provider "$provider_name" '.[$provider] | join(", ")' <<<"$retained")"
      printf 'Retained %s provider-managed application(s): [%s] %s\n' \
        "$(jq -r --arg provider "$provider_name" '.[$provider] | length' <<<"$retained")" \
        "$provider_name" "$retained_ids"
    done < <(jq -r 'keys[]' <<<"$retained")
    "$DRY_RUN" || rm -f "$status_file" "$ROOT/.state/provider-status.pending.json"
  fi
}

cleanup_recorded_plugin_state() {
  local receipt name contribution lifecycle path expanded seen='[]'
  [[ -d "$ROOT/.state/receipts" ]] || return 0
  while IFS= read -r receipt; do
    jq -e '.schemaVersion == 2' "$receipt" >/dev/null 2>&1 || continue
    while IFS= read -r name; do
      contribution="$(jq -c --arg name "$name" '.plugins[$name]' "$receipt")"
      lifecycle="$(jq -r '.lifecycle.state // "retain"' <<<"$contribution")"
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        expanded="$path"
        [[ "$expanded" != '~/'* ]] || expanded="$HOME/${expanded#\~/}"
        case "$expanded" in
          "$HOME/.local/share/home-weave/"*) ;;
          *)
            warn "plugin $name recorded state outside HomeWeave's managed state root; retained: $path"
            continue
            ;;
        esac
        if jq -e --arg path "$expanded" 'index($path) != null' >/dev/null <<<"$seen"; then
          continue
        fi
        seen="$(jq -cn --argjson seen "$seen" --arg path "$expanded" '$seen + [$path]')"
        if [[ "$lifecycle" == remove ]]; then
          if "$DRY_RUN"; then
            printf 'Would remove plugin state: [%s] %s\n' "$name" "$expanded"
          else
            rm -rf -- "$expanded"
            printf 'Removed plugin state: [%s] %s\n' "$name" "$expanded"
          fi
        else
          printf 'Retained plugin state: [%s] %s\n' "$name" "$expanded"
        fi
      done < <(jq -r '.statePaths[]?' <<<"$contribution")
    done < <(jq -r '(.plugins // {}) | keys[]' "$receipt")
  done < <(find "$ROOT/.state/receipts" -maxdepth 1 -type f -name '*.json' -print | sort)
}

nuke_all_print_scope() {
  local profile xdg_cache
  profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/profile"
  xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}/nix"
  cat <<EOF
DESTRUCTIVE GLOBAL NIX CLEANUP

This command removes:
  HomeWeave root:             $ROOT
  HomeWeave external state:   config, data, state, and cache namespaces
  HomeWeave artifact links:   recognized managed and legacy dotfile links
  HomeWeave package profile:  dedicated profile links and generations
  Default user Nix profile:   $profile
  Default profile history:    all non-current generations
  Nix cache:                  $xdg_cache
  Legacy Nix channels:        $HOME/.nix-channels
  Legacy Nix definitions:     $HOME/.nix-defexpr
  User profile link:          $HOME/.nix-profile
  Unreachable Nix store data: nix-collect-garbage -d

This can remove packages unrelated to HomeWeave and makes deleted generations
unavailable for rollback. The Nix daemon, installer, and /nix infrastructure
are retained.
EOF
  if [[ "$xdg_cache" != "$HOME/.cache/nix" ]]; then
    printf '  Default Nix cache also:     %s\n' "$HOME/.cache/nix"
  fi
}

nuke_all_command() {
  local confirmation profile xdg_cache modern_profile=false legacy_profile=false
  local package
  local -a legacy_packages=()

  (("${#POSITIONAL_ARGS[@]}" == 0)) || fail "nuke-all does not accept positional arguments"
  nuke_all_print_scope

  if "$DRY_RUN"; then
    if [[ -d "$ROOT" && -f "$ROOT/flake.nix" ]]; then
      printf '\nWould first remove every recorded effect owned by the HomeWeave root.\n'
    else
      printf '\nNo HomeWeave repository exists at %s; root cleanup would be skipped.\n' "$ROOT"
    fi
    printf 'Would remove all elements from the current user default Nix profile.\n'
    cleanup_home_weave_artifact_links
    cleanup_home_weave_external_state
    printf 'Would delete its old profile generations and user Nix metadata/cache paths listed above.\n'
    printf 'Would run nix-collect-garbage -d last.\n'
    printf 'Would retain the Nix daemon, installer, and /nix infrastructure.\n'
    return
  fi

  require_commands install nix nix-env nix-collect-garbage
  [[ -t 0 ]] || fail "nuke-all requires an interactive typed confirmation; run with --dry-run first"
  printf '\nType the complete phrase shown below exactly:\n  NUKE ALL USER NIX STATE\nConfirmation: '
  read -r confirmation
  [[ "$confirmation" == "NUKE ALL USER NIX STATE" ]] \
    || fail "nuke-all confirmation did not match; nothing was changed"

  if [[ -d "$ROOT" && -f "$ROOT/flake.nix" ]]; then
    UNINSTALL_ALL=true
    UNINSTALL_NUKE=true
    UNINSTALL_REMOVE_CASKS=true
    ASSUME_YES=true
    NUKE_ALL_CONFIRMED=true
    uninstall_command
  else
    warn "no HomeWeave repository exists at $ROOT; continuing with current-user Nix cleanup"
  fi

  # An adoption backup can contain links created by an older HomeWeave root.
  # Remove only recognizable generated-target layouts, then clear namespaces
  # reserved for HomeWeave state outside the selected repository.
  cleanup_home_weave_artifact_links
  cleanup_home_weave_external_state

  profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/profile"
  xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}/nix"

  if [[ -e "$profile" || -L "$profile" ]]; then
    if nix --extra-experimental-features 'nix-command flakes' \
      profile list --profile "$profile" --json >/dev/null 2>&1; then
      modern_profile=true
    elif nix-env --profile "$profile" --list-generations >/dev/null 2>&1; then
      legacy_profile=true
    else
      warn "default user profile is neither a readable modern nor legacy Nix profile: $profile"
    fi
  fi

  if "$modern_profile"; then
    printf 'Removing all packages from modern user Nix profile: %s\n' "$profile"
    nix --extra-experimental-features 'nix-command flakes' \
      profile remove --profile "$profile" --all
    nix --extra-experimental-features 'nix-command flakes' \
      profile wipe-history --profile "$profile"
  elif "$legacy_profile"; then
    while IFS= read -r package; do
      [[ -z "$package" ]] || legacy_packages+=("$package")
    done < <(nix-env --profile "$profile" --query)
    if (("${#legacy_packages[@]}" > 0)); then
      printf 'Removing all packages from legacy user Nix profile: %s\n' "$profile"
      nix-env --profile "$profile" --uninstall "${legacy_packages[@]}"
    fi
    nix-env --profile "$profile" --delete-generations old
  else
    printf 'No current user default Nix profile was found.\n'
  fi

  rm -rf "$xdg_cache"
  [[ "$xdg_cache" == "$HOME/.cache/nix" ]] || rm -rf "$HOME/.cache/nix"
  rm -rf "$HOME/.nix-channels" "$HOME/.nix-defexpr" "$HOME/.nix-profile"

  printf 'Running Nix garbage collection after removing user roots and history.\n'
  nix-collect-garbage -d
  install -d -m 0700 "$xdg_cache"
  [[ "$xdg_cache" == "$HOME/.cache/nix" ]] \
    || install -d -m 0700 "$HOME/.cache/nix"
  printf 'Nuke-all complete. The Nix daemon, installer, and /nix infrastructure were retained.\n'
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

  # Nuke confirmation must happen before HomeWeave package profile, Stow, provider, state,
  # or repository changes. --yes intentionally cannot bypass this guard.
  if "$UNINSTALL_NUKE" && ! "$DRY_RUN" && [[ "$NUKE_ALL_CONFIRMED" == false ]]; then
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
    confirm "Remove the HomeWeave Nix package profile?" || UNINSTALL_KEEP_PACKAGES=true
    confirm "Unlink HomeWeave-managed dotfiles?" || UNINSTALL_KEEP_DOTFILES=true
    confirm "Restore available pre-adoption dotfiles?" || UNINSTALL_NO_RESTORE=true
    confirm "Remove casks and provider applications recorded as installed by HomeWeave?" && UNINSTALL_REMOVE_CASKS=true
    confirm "Archive the HomeWeave repository after uninstall?" && UNINSTALL_ARCHIVE_ROOT=true
    confirm "Proceed with the displayed uninstall choices?" || fail "uninstall cancelled"
  fi
  "$UNINSTALL_KEEP_PACKAGES" || uninstall_package_profile
  "$UNINSTALL_KEEP_DOTFILES" || uninstall_dotfiles
  "$UNINSTALL_KEEP_DOTFILES" || cleanup_stale_dotfile_links
  "$UNINSTALL_NO_RESTORE" || restore_adopted_backups
  "$UNINSTALL_KEEP_DOTFILES" || cleanup_stale_dotfile_links
  "$UNINSTALL_KEEP_DOTFILES" || cleanup_empty_managed_directories
  "$UNINSTALL_REMOVE_CASKS" && uninstall_recorded_casks
  "$UNINSTALL_REMOVE_CASKS" && uninstall_recorded_providers
  "$UNINSTALL_KEEP_PACKAGES" || cleanup_recorded_plugin_state
  "$DRY_RUN" || rm -f "$ROOT/.state/active-profile" "$ROOT/.state/selected-profile"
  if "$UNINSTALL_NUKE"; then
    if "$DRY_RUN"; then
      printf 'Would delete HomeWeave-owned root, state, receipts, backups, generated configurations, and private clones: %s\n' "$ROOT"
      printf 'Would retain Nix and would not run global garbage collection.\n'
      return
    fi
    remove_active_root_launcher
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

show_setup_summary() {
  local activation remote
  case "$APPLY_NOW" in
    true) activation="generate and apply" ;;
    false) activation="generate only" ;;
    *) activation="ask after generation" ;;
  esac
  remote="${REMOTE_URL:-prompt during setup (optional)}"
  printf '\nHomeWeave setup summary:\n'
  printf '  Parent distribution: %s\n' "$BASE_URL"
  printf '  Inherited profile:   %s\n' "$PROFILE"
  printf '  Personal root:       %s\n' "$ROOT"
  printf '  Git remote:          %s\n' "$remote"
  printf '  Activation:          %s\n' "$activation"
}

show_setup_guide() {
  printf '\nNext steps:\n'
  printf '  1. Enter the generated repository and review its local delta:\n'
  printf '     cd %q\n' "$ROOT"
  printf '     git status --short\n'
  printf '  2. Edit home-weave.json for profile overrides, packages.json for local package\n'
  printf '     definitions, overlay.nix for version/package overrides, and dotfiles/custom\n'
  printf '     for local dotfiles. Nix fetches parent files automatically through flake.lock.\n'
  printf '  3. Validate and inspect the effective profile:\n'
  printf '     ./home-weave config validate\n'
  printf '     ./home-weave config show %q\n' "$PROFILE"
  printf '  4. Preview and activate:\n'
  printf '     ./home-weave plan\n'
  printf '     ./home-weave apply --yes\n'
  printf '  5. Open a fresh shell, then use the installed command:\n'
  printf '     home-weave status\n'
  printf '     home-weave plan\n'
  if [[ -d "$ROOT/.git" ]] && [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    printf '  6. When ready, commit and push your reviewed delta:\n'
    printf '     git add -A\n'
    printf '     git commit -m %q\n' "Configure HomeWeave profile"
    printf '     git push -u origin %q\n' "${REMOTE_BRANCH:-main}"
  fi
  printf '\nDestructive cleanup always requires an exact typed confirmation:\n'
  printf '  home-weave nuke-all --dry-run\n'
  printf '  home-weave nuke-all\n'
}

setup_command() {
  local package group pinned inherited_profile overlay_manifest profile_delta filtered_packages=() group_unfree=()
  require_commands cp date du find git nix realpath sed
  [[ -d "$TEMPLATE" ]] || fail "profile template is unavailable: $TEMPLATE"
  begin_root_replacement
  trap 'rollback_root_replacement; release_operation_lock' EXIT ERR INT TERM
  cp -R "$TEMPLATE/." "$ROOT/"
  chmod -R u+rwX "$ROOT"
  if [[ -n "$PROFILE_OVERLAY" ]]; then
    [[ -d "$PROFILE_OVERLAY" ]] || fail "profile overlay is unavailable: $PROFILE_OVERLAY"
    if [[ -f "$PROFILE_OVERLAY/home-weave.json" ]]; then
      overlay_manifest="$PROFILE_OVERLAY/home-weave.json"
      inherited_profile="${PROFILE:-$(jq -r '.defaults.profile // "base"' "$overlay_manifest")}"
      validate_name "$inherited_profile"
      profile_delta="$(inheritance_profile_delta "$inherited_profile")"
      jq --arg profile "$inherited_profile" --argjson profileDelta "$profile_delta" '
        .distribution = {name: "home-weave-child"}
        | .defaults.profile = $profile
        | .profiles = {($profile): $profileDelta}
      ' "$ROOT/home-weave.json" >"$ROOT/home-weave.json.tmp.$$"
      mv "$ROOT/home-weave.json.tmp.$$" "$ROOT/home-weave.json"
      PROFILE="$inherited_profile"
    fi
    mv "$ROOT/flake-inherited.nix" "$ROOT/flake.nix"
    rm -rf "$ROOT/dotfiles"
    mkdir -p "$ROOT/dotfiles/custom"
    : >"$ROOT/dotfiles/custom/.gitkeep"
    rm -rf "$ROOT/nix" "$ROOT/extensions"
    rm -f "$ROOT/setup.sh" "$ROOT/home.nix"
  else
    rm -f "$ROOT/flake-inherited.nix"
  fi
  chmod -R u+rwX "$ROOT"
  [[ ! -f "$ROOT/home-weave" ]] || chmod u+x "$ROOT/home-weave"
  [[ ! -f "$ROOT/setup.sh" ]] || chmod u+x "$ROOT/setup.sh"
  if [[ "$BASE_URL" != "github:thoughtoinnovate/nix" ]]; then
    [[ "$BASE_URL" != *$'\n'* && "$BASE_URL" != *'|'* && "$BASE_URL" != *'&'* ]] \
      || fail "unsupported distribution URL: $BASE_URL"
    case "$BASE_URL" in
      /nix/store/*|path:/nix/store/*|path:/private/nix/store/*)
        fail "parent distribution URL must be portable; use its Git flake URL instead of $BASE_URL"
        ;;
    esac
    sed "s|github:thoughtoinnovate/nix|$BASE_URL|g" "$ROOT/flake.nix" >"$ROOT/.flake.nix.distribution"
    mv "$ROOT/.flake.nix.distribution" "$ROOT/flake.nix"
  fi
  mkdir -p "$ROOT/.state" "$ROOT/backup"
  [[ -n "$PROFILE_OVERLAY" ]] || choose_profile
  ensure_profile
  render_profile_readme
  choose_shell
  if [[ -z "$PROFILE_OVERLAY" || "$SHELL_EXPLICIT" == true ]]; then
    update_profile_shell
  fi
  show_setup_summary
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
  select_provider_packages
  write_pending_state
  show_profile_packages
  scan_dotfiles
  # Integration tests exercise setup in an intentionally networkless Nix
  # builder. Real setup always writes the child lock before Git handling.
  if [[ "${HOME_WEAVE_TEST_MODE:-false}" != true ]]; then
    nix --extra-experimental-features 'nix-command flakes' \
      flake lock "path:$ROOT"
  fi
  initialize_git
  printf '\nHomeWeave repository created at %s\n' "$ROOT"
  if [[ -z "$APPLY_NOW" && -t 0 ]]; then
    confirm "Build and install HomeWeave now?" && APPLY_NOW=true || APPLY_NOW=false
  fi
  if [[ "$APPLY_NOW" == true ]]; then
    run_profile_setup apply
  fi
  show_setup_guide
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
      for candidate in flake.nix flake.lock home-weave.json packages.json nix dotfiles extensions; do
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
  run_logged nix --extra-experimental-features 'nix-command flakes' --refresh \
    flake update --flake "path:$ROOT" \
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
  jq -e '.schemaVersion == 2' >/dev/null <<<"$provider" || fail "unsupported provider schema"
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
  jq -e '.schemaVersion == 2 and (.capabilities | index("command"))' >/dev/null <<<"$extension" \
    || fail "$name is not a command extension"
  command="$(jq -r '.executable' <<<"$extension")"
  [[ -x "$command" ]] || fail "extension executable is unavailable: $command"
  exec "$command" command "${POSITIONAL_ARGS[@]:1}"
}

plugin_command() {
  local action="${POSITIONAL_ARGS[0]:-list}" name="${POSITIONAL_ARGS[1]:-}" plugin receipt profiles selected
  require_commands jq
  jq -e 'type == "object"' >/dev/null <<<"$PLUGINS_JSON" || fail "invalid plugin manifest"
  case "$action" in
    list)
      jq -r 'to_entries[] | [.key, .value.kind,
        ("packages=" + .value.lifecycle.packages + ",state=" + .value.lifecycle.state),
        (.value.platforms | join(","))] | @tsv' <<<"$PLUGINS_JSON"
      ;;
    show)
      [[ -n "$name" ]] || fail "plugin show requires a plugin name"
      plugin="$(jq -ce --arg name "$name" '.[$name] // empty' <<<"$PLUGINS_JSON")" \
        || fail "unknown plugin: $name"
      jq . <<<"$plugin"
      ;;
    status)
      receipt=""
      [[ ! -L "$ROOT/.state/receipts/latest" ]] || receipt="$(readlink -f "$ROOT/.state/receipts/latest" 2>/dev/null || true)"
      if [[ -n "$receipt" && -r "$receipt" ]]; then
        if [[ -n "$name" ]]; then
          jq -e --arg name "$name" '(.plugins // {}) | has($name)' "$receipt" >/dev/null \
            || fail "plugin is not active in the latest receipt: $name"
          jq --arg name "$name" '.plugins[$name]' "$receipt"
        else
          jq '.plugins // {}' "$receipt"
        fi
      elif [[ -f "$ROOT/flake.nix" ]]; then
        profiles="$(profile_metadata)"
        selected="${PROFILE:-$(jq -r '.defaults.profile' "$ROOT/home-weave.json")}"
        if [[ -n "$name" ]]; then
          jq -e --arg profile "$selected" --arg name "$name" '.[$profile].pluginContributions | has($name)' \
            >/dev/null <<<"$profiles" || fail "plugin is not enabled for profile $selected: $name"
          jq --arg profile "$selected" --arg name "$name" '.[$profile].pluginContributions[$name]' <<<"$profiles"
        else
          jq --arg profile "$selected" '.[$profile].pluginContributions // {}' <<<"$profiles"
        fi
      else
        printf '{}\n'
      fi
      ;;
    *) fail "unknown plugin command: $action (use list, show, or status)" ;;
  esac
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
        || fail "home-weave.json does not satisfy the HomeWeave v4 schema"
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
  setup|plan|apply|update|restore|sync|uninstall|nuke-all|snapshot) show_homeweave_banner ;;
  profile)
    case "${POSITIONAL_ARGS[0]:-list}" in create|switch|delete) show_homeweave_banner ;; esac
    ;;
esac

case "$COMMAND" in
  plan|apply) guard_legacy_home_manager ;;
esac

case "$COMMAND" in
  setup|apply|update|uninstall|nuke-all|snapshot) acquire_operation_lock ;;
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
  nuke-all) nuke_all_command ;;
  profile) profile_command ;;
  status) status_command ;;
  config) config_command ;;
  logs) logs_command ;;
  snapshot) snapshot_command ;;
  provider) provider_command ;;
  plugin) plugin_command ;;
  extension) extension_command ;;
  help|--help|-h) usage ;;
  *) fail "unknown command: $COMMAND (run home-weave help)" ;;
esac
