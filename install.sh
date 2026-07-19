#!/usr/bin/env bash

set -Eeuo pipefail

PROFILE=""
SELECTED_SHELL=""
BASE_URL="${NIX_BASE_URL:-github:thoughtoinnovate/nix}"
CONFIG_URL="${NIX_CONFIG_URL:-}"
CONFIG_DIR="${NIX_CONFIG_DIR:-}"
CONFIG_FLAKE=""
NAMESPACE="${HOME_WEAVE_NAMESPACE:-}"
ASSUME_YES=false
ALLOW_NIX_INSTALL=true
GENERATE_ONLY=false
TEMP_INSTALL_DIR=""
PACKAGE_PROFILE_PATH="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave"
PREVIOUS_PACKAGE_GENERATION=""
PACKAGE_PROFILE_SWITCHED=false
ACTIVATION_STARTED=false
ACTIVATION_COMMITTED=false
DOTFILES_CHANGED=false
DOTFILE_SNAPSHOT_ROOT=""
INSTALLED_CASKS_THIS_RUN=()

cleanup() {
  local pending_marker rollback_succeeded=false current_profile_link profile_dir
  if "$ACTIVATION_STARTED" && ! "$ACTIVATION_COMMITTED"; then
    pending_marker="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/package-profile-pending.json"
    if "$DOTFILES_CHANGED"; then
      stow_root="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/dotfiles"
      stow --delete --no-folding --dir="$stow_root" --target="$HOME" current >/dev/null 2>&1 || true
      rm -rf "$stow_root/current"
      if [[ -d "$DOTFILE_SNAPSHOT_ROOT/current" ]]; then
        mv "$DOTFILE_SNAPSHOT_ROOT/current" "$stow_root/current"
        stow --restow --no-folding --dir="$stow_root" --target="$HOME" current >/dev/null 2>&1 || \
          printf 'warning: automatic Stow rollback failed\n' >&2
      fi
    fi
    for cask in "${INSTALLED_CASKS_THIS_RUN[@]-}"; do
      [[ -n "$cask" ]] || continue
      brew uninstall --cask "$cask" >/dev/null 2>&1 || \
        printf 'warning: could not roll back Homebrew cask %s\n' "$cask" >&2
      cask_record="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/installed-casks"
      if [[ -f "$cask_record" ]]; then
        grep -Fvx "$cask" "$cask_record" >"$cask_record.rollback" || true
        mv "$cask_record.rollback" "$cask_record"
      fi
    done
    if ! "$PACKAGE_PROFILE_SWITCHED"; then
      rollback_succeeded=true
    elif [[ -n "$PREVIOUS_PACKAGE_GENERATION" ]]; then
      printf 'warning: restoring the previous HomeWeave package generation after activation failure\n' >&2
      if nix-env --profile "$PACKAGE_PROFILE_PATH" --switch-generation "$PREVIOUS_PACKAGE_GENERATION" >/dev/null 2>&1; then
        rollback_succeeded=true
      else
        printf 'warning: automatic package-profile rollback failed; run nix-env --profile %s --switch-generation %s\n' \
          "$PACKAGE_PROFILE_PATH" "$PREVIOUS_PACKAGE_GENERATION" >&2
      fi
    else
      printf 'warning: removing the first HomeWeave package generation after activation failure\n' >&2
      current_profile_link="$(readlink "$PACKAGE_PROFILE_PATH" 2>/dev/null || true)"
      profile_dir="$(dirname "$PACKAGE_PROFILE_PATH")"
      rm -f "$PACKAGE_PROFILE_PATH"
      if [[ "$current_profile_link" =~ ^home-weave-[0-9]+-link$ ]]; then
        rm -f "$profile_dir/$current_profile_link"
      fi
      [[ ! -e "$PACKAGE_PROFILE_PATH" && ! -L "$PACKAGE_PROFILE_PATH" ]] && rollback_succeeded=true
    fi
    "$rollback_succeeded" && rm -f "$pending_marker"
  fi
  if [[ -n "$TEMP_INSTALL_DIR" && -d "$TEMP_INSTALL_DIR" ]]; then
    rm -rf "$TEMP_INSTALL_DIR"
  fi
  [[ -z "$DOTFILE_SNAPSHOT_ROOT" ]] || rm -rf "$DOTFILE_SNAPSHOT_ROOT"
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --shell bash|zsh|fish|nushell   Shell to install and configure
  --profile NAME                 Built-in or custom profile to activate
  --base-url URL                 Base flake URL (default: github:thoughtoinnovate/nix)
  --config-url URL               User profile flake URL or local path
  --config-dir PATH              Generated activation flake directory
  --namespace NAME              Runtime namespace (default: home-weave)
  --yes                          Accept the Nix installation prompt
  --no-install-nix               Fail instead of installing Nix when it is missing
  --generate-only                Write and lock the local flake without activating it
  --help                         Show this help

Examples:
  ./install.sh --shell fish --profile development
  ./install.sh --shell zsh --profile base
  ./install.sh --base-url path:$PWD --shell fish --profile development
  nix run github:thoughtoinnovate/nix#setup -- --config-url gitlab:group/profile
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

validate_namespace() {
  [[ "$NAMESPACE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$NAMESPACE" != "." && "$NAMESPACE" != ".." ]] \
    || fail "namespace must contain only letters, numbers, dots, underscores, or hyphens: $NAMESPACE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      [[ $# -ge 2 ]] || fail "--shell requires a value"
      SELECTED_SHELL="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a value"
      PROFILE="$2"
      shift 2
      ;;
    --base-url)
      [[ $# -ge 2 ]] || fail "--base-url requires a value"
      BASE_URL="$2"
      shift 2
      ;;
    --config-url)
      [[ $# -ge 2 ]] || fail "--config-url requires a value"
      CONFIG_URL="$2"
      shift 2
      ;;
    --config-dir)
      [[ $# -ge 2 ]] || fail "--config-dir requires a value"
      CONFIG_DIR="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || fail "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --no-install-nix)
      ALLOW_NIX_INSTALL=false
      shift
      ;;
    --generate-only)
      GENERATE_ONLY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "$(uname -s)" in
  Linux) OS="linux" ;;
  Darwin) OS="darwin" ;;
  *) fail "only Linux and macOS are supported" ;;
esac

case "$(uname -m)" in
  x86_64)
    SYSTEM="x86_64-$OS"
    ;;
  arm64|aarch64)
    SYSTEM="aarch64-$OS"
    ;;
  *) fail "unsupported CPU architecture: $(uname -m)" ;;
esac

choose_shell() {
  printf 'Choose a shell:\n'
  select choice in bash zsh fish nushell; do
    case "$choice" in
      bash|zsh|fish|nushell)
        SELECTED_SHELL="$choice"
        return
        ;;
    esac
    printf 'Choose a number from 1 to 4.\n' >&2
  done
}

choose_profile() {
  printf 'Choose a package profile:\n'
  select choice in base development; do
    case "$choice" in
      base|development)
        PROFILE="$choice"
        return
        ;;
    esac
    printf 'Choose 1 or 2.\n' >&2
  done
}

[[ "$BASE_URL" != *'"'* && "$BASE_URL" != *$'\n'* ]] || fail "invalid --base-url"
[[ "$CONFIG_URL" != *'"'* && "$CONFIG_URL" != *$'\n'* ]] || fail "invalid --config-url"
[[ "$USER" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "unsupported username: $USER"
[[ "$(id -u)" -ne 0 ]] || fail "run this installer as your normal user, not root"

LEGACY_HOME_MANAGER_PROFILE="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
if [[ -e "$LEGACY_HOME_MANAGER_PROFILE" || -L "$LEGACY_HOME_MANAGER_PROFILE" ]]; then
  fail "an active legacy Home Manager profile exists at $LEGACY_HOME_MANAGER_PROFILE; uninstall the previous HomeWeave release before using this breaking release"
fi

load_nix_environment() {
  local candidate
  for candidate in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    if [[ -r "$candidate" ]]; then
      # shellcheck disable=SC1090
      source "$candidate"
      break
    fi
  done
}

install_nix() {
  local answer installer

  "$ALLOW_NIX_INSTALL" || fail "Nix is missing and --no-install-nix was supplied"
  command -v curl >/dev/null 2>&1 || fail "curl is required to install Nix"

  if ! "$ASSUME_YES"; then
    printf 'Nix is not installed. Run the official installer from nixos.org? [y/N] '
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || fail "Nix installation declined"
  fi

  TEMP_INSTALL_DIR="$(mktemp -d)"
  installer="$TEMP_INSTALL_DIR/install-nix"

  curl --proto '=https' --tlsv1.2 --fail --location \
    https://nixos.org/nix/install --output "$installer"

  if [[ "$OS" == "darwin" ]]; then
    sh "$installer"
  elif command -v systemctl >/dev/null 2>&1 \
    && { ! command -v getenforce >/dev/null 2>&1 || [[ "$(getenforce)" != "Enforcing" ]]; }; then
    sh "$installer" --daemon
  else
    sh "$installer" --no-daemon
  fi

  load_nix_environment
  command -v nix >/dev/null 2>&1 || fail "Nix was installed; open a new terminal and rerun this script"
  rm -rf "$TEMP_INSTALL_DIR"
  TEMP_INSTALL_DIR=""
}

if ! command -v nix >/dev/null 2>&1; then
  load_nix_environment
fi

if ! command -v nix >/dev/null 2>&1; then
  install_nix
fi

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}extra-experimental-features = nix-command flakes
substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
require-sigs = true
sandbox = true"

initialize_profile_interactive() {
  local answer profile_dir remote_url origin namespace_answer

  [[ -z "$CONFIG_URL" && -t 0 ]] || return 0
  printf 'Create or connect a personal profile repository? [y/N] '
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || return 0
  command -v git >/dev/null 2>&1 || fail "Git is required to create a personal profile repository"

  if [[ -z "$NAMESPACE" ]]; then
    printf 'HomeWeave namespace [home-weave]: '
    read -r namespace_answer
    NAMESPACE="${namespace_answer:-home-weave}"
  fi
  validate_namespace

  printf 'Profile directory [%s]: ' "${XDG_CONFIG_HOME:-$HOME/.config}/$NAMESPACE/profiles/default"
  read -r profile_dir
  profile_dir="${profile_dir:-${XDG_CONFIG_HOME:-$HOME/.config}/$NAMESPACE/profiles/default}"
  case "$profile_dir" in
    \~/*) profile_dir="$HOME/${profile_dir#\~/}" ;;
    /*) ;;
    *) profile_dir="$PWD/$profile_dir" ;;
  esac
  [[ "$profile_dir" != *$'\n'* ]] || fail "invalid profile directory"

  printf 'GitHub/GitLab SSH remote URL (optional): '
  read -r remote_url
  [[ "$remote_url" != *$'\n'* ]] || fail "invalid profile remote"

  if [[ -e "$profile_dir" && ! -d "$profile_dir" ]]; then
    fail "$profile_dir exists but is not a directory"
  fi
  mkdir -p "$profile_dir"

  if [[ -d "$profile_dir/.git" ]]; then
    [[ -z "$(git -C "$profile_dir" status --porcelain)" ]] \
      || fail "$profile_dir has uncommitted changes"
    if [[ -n "$remote_url" ]]; then
      origin="$(git -C "$profile_dir" remote get-url origin 2>/dev/null || true)"
      [[ -z "$origin" || "${origin%.git}" == "${remote_url%.git}" ]] \
        || fail "$profile_dir origin does not match $remote_url"
      [[ -n "$origin" ]] || git -C "$profile_dir" remote add origin "$remote_url"
    fi
  else
    if find "$profile_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      fail "$profile_dir is not empty and is not a Git repository"
    fi
    git -C "$profile_dir" init --quiet --initial-branch=main
    [[ -z "$remote_url" ]] || git -C "$profile_dir" remote add origin "$remote_url"
  fi

  if [[ ! -e "$profile_dir/flake.nix" ]]; then
    (cd "$profile_dir" && nix "${NIX_FLAGS[@]}" flake init -t "$BASE_URL#profile")
    if [[ "$NAMESPACE" != "home-weave" ]]; then
      sed "s/namespace = \"home-weave\";/namespace = \"$NAMESPACE\";/" \
        "$profile_dir/flake.nix" >"$profile_dir/.flake.nix.namespace"
      mv "$profile_dir/.flake.nix.namespace" "$profile_dir/flake.nix"
    fi
  fi
  [[ -x "$profile_dir/setup.sh" ]] || fail "$profile_dir/setup.sh is missing or not executable"

  CONFIG_URL="path:$profile_dir"
  printf 'Created personal profile at %s.\n' "$profile_dir"
  printf 'Review its files before running git add, commit, or push.\n'
}

initialize_profile_interactive

[[ -n "$CONFIG_URL" ]] \
  || fail "a schema-v3 profile is required; run home-weave setup or pass --config-url"

stage_local_profile_source() {
  local source target pending previous
  [[ "$CONFIG_URL" == path:* ]] || return 0
  source="${CONFIG_URL#path:}"
  [[ "$source" != *'?'* && -d "$source" ]] \
    || fail "local profile source is unavailable: $source"
  source="$(realpath "$source")"
  target="$CONFIG_DIR/profile-source"
  [[ "$source" != "$target" ]] || return 0
  pending="$CONFIG_DIR/.profile-source.pending.$$"
  previous="$CONFIG_DIR/.profile-source.previous.$$"
  rm -rf "$pending" "$previous"
  mkdir -p "$pending"
  rsync -a \
    --exclude='/.git/' \
    --exclude='/.state/' \
    --exclude='/backup/' \
    --exclude='/result' \
    --exclude='/result-*' \
    "$source/" "$pending/"
  if [[ -e "$target" ]]; then
    mv "$target" "$previous"
  fi
  if ! mv "$pending" "$target"; then
    [[ ! -e "$previous" ]] || mv "$previous" "$target"
    fail "could not stage the local profile source"
  fi
  rm -rf "$previous"
  CONFIG_URL="path:$target"
}

if [[ -n "$CONFIG_URL" ]]; then
  if ! command -v jq >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    fail "profile setup requires the packaged setup app (nix run ...#setup)"
  fi
  schema_version="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.schemaVersion")"
  [[ "$schema_version" == "5" ]] \
    || fail "unsupported setup API: $schema_version (this HomeWeave release requires setup API 5)"
  if [[ -z "$NAMESPACE" ]]; then
    if profile_namespace="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.namespace" 2>/dev/null)"; then
      NAMESPACE="$profile_namespace"
    fi
  fi
fi

NAMESPACE="${NAMESPACE:-home-weave}"
validate_namespace
CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/$NAMESPACE/generated}"
mkdir -p "$CONFIG_DIR"
stage_local_profile_source
CONFIG_FLAKE="path:$CONFIG_DIR"

if [[ -n "$CONFIG_URL" ]]; then
  schema_version="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.schemaVersion")"
  [[ "$schema_version" == "5" ]] \
    || fail "unsupported staged setup API: $schema_version (this HomeWeave release requires setup API 5)"
  if [[ -z "$PROFILE" ]]; then
    PROFILE="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.defaults.profile")"
  fi
  profiles_json="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.profilesBySystem.\"$SYSTEM\"")" \
    || fail "profile configuration could not be evaluated for $SYSTEM"
  profile_json="$(jq -ce --arg profile "$PROFILE" '.[$profile] // empty' <<<"$profiles_json")"
  [[ -n "$profile_json" ]] || fail "profile is not exported by $CONFIG_URL: $PROFILE"
  if [[ -z "$SELECTED_SHELL" ]]; then
    SELECTED_SHELL="$(jq -r '.primaryShell' <<<"$profile_json")"
  fi
  PROFILE_SHELLS="$(jq -r '.shells | join(",")' <<<"$profile_json")"
  PROFILE_CASKS="$(jq -r '.homebrewCasks | join(",")' <<<"$profile_json")"
fi

if [[ -z "$SELECTED_SHELL" ]]; then
  [[ -t 0 ]] || fail "use --shell when running non-interactively"
  choose_shell
fi

if [[ -z "$PROFILE" ]]; then
  [[ -t 0 ]] || fail "use --profile when running non-interactively"
  choose_profile
fi

case "$SELECTED_SHELL" in
  bash|zsh|fish|nushell) ;;
  *) fail "unsupported shell: $SELECTED_SHELL" ;;
esac

[[ "$PROFILE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$PROFILE" != "." && "$PROFILE" != ".." ]] \
  || fail "unsafe profile name: $PROFILE"

MARKER="# Generated by HomeWeave install.sh"
TARGET_FLAKE="$CONFIG_DIR/flake.nix"

if [[ -e "$TARGET_FLAKE" ]] \
  && ! grep -Fq "$MARKER" "$TARGET_FLAKE"; then
  fail "$TARGET_FLAKE already exists and was not generated by HomeWeave"
fi

TEMP_FLAKE="$CONFIG_DIR/.flake.nix.tmp"
UNFREE_PACKAGES="$(jq -r '.allowUnfree | map(@json) | join(" ")' <<<"$profile_json")"
PROFILE_PACKAGE_NAMES_JSON="$(jq -c '.nixPackages' <<<"$profile_json")"
PROFILE_SHELLS_JSON="$(jq -c '.shells' <<<"$profile_json")"
PACKAGE_ORIGINS_JSON="$(jq -c '.packageOrigins' <<<"$profile_json")"

INPUT_DECLARATIONS="profile.url = \"$CONFIG_URL\";
    nix-base.follows = \"profile/nix-base\";"
CUSTOM_OVERLAY="++ [ inputs.profile.overlays.default ]"

cat >"$TEMP_FLAKE" <<EOF
$MARKER
{
  description = "Local HomeWeave package environment";

  inputs = {
    $INPUT_DECLARATIONS
    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs = inputs@{ nix-base, nixpkgs, ... }:
    let
      system = "$SYSTEM";
      packageSource = nix-base.lib.homeWeave.sourcesBySystem.\${system}.nixpkgs or
        (throw "HomeWeave distribution does not expose a package source for \${system}");
      packageLib = packageSource.lib;
      pkgs = import packageSource {
        inherit system;
        overlays = [
          nix-base.overlays.darwin-cache
          nix-base.overlays.base
          nix-base.overlays.development
        ]
          $CUSTOM_OVERLAY;
        config.allowUnfreePredicate = pkg:
          builtins.elem (packageLib.getName pkg) [ $UNFREE_PACKAGES ];
        config.allowUnsupportedSystem = true;
      };
      declaredPackageNames = builtins.fromJSON ''$PROFILE_PACKAGE_NAMES_JSON'';
      declaredShells = builtins.fromJSON ''$PROFILE_SHELLS_JSON'';
      packageOrigins = builtins.fromJSON ''$PACKAGE_ORIGINS_JSON'';
      packageFor = attribute:
        packageLib.attrByPath (packageLib.splitString "." attribute)
          (throw "HomeWeave package is unavailable: \${attribute}") pkgs;
      declaredPackageMetadata = map (attribute: {
        inherit attribute;
        package = packageFor attribute;
        origins = packageOrigins.\${attribute} or [ ];
      }) declaredPackageNames;
      activationPackages =
        map (metadata: metadata.package) declaredPackageMetadata
        ++ map (shell: pkgs.shellPackages.\${shell}) declaredShells;
      metadataFor = package:
        packageLib.findFirst
          (candidate: toString candidate.package == toString package)
          null
          declaredPackageMetadata;
      originDetailsFor = metadata:
        let
          origins = if metadata == null then [ ] else metadata.origins;
          groupOrigins = builtins.filter (packageLib.hasPrefix "group:") origins;
          profileOrigins = builtins.filter (packageLib.hasPrefix "profile:") origins;
          sourceProfile = if profileOrigins == [ ] then null
            else packageLib.removePrefix "profile:" (builtins.head profileOrigins);
          group = if groupOrigins != [ ]
            then packageLib.removePrefix "group:" (builtins.head groupOrigins)
            else if sourceProfile != null then sourceProfile
            else "shell";
        in {
          inherit origins sourceProfile group;
          inheritedFrom = if sourceProfile != null && sourceProfile != "$PROFILE"
            then sourceProfile else null;
        };
    in {
      packages."$SYSTEM".home-weave-environment = pkgs.buildEnv {
        name = "home-weave-environment";
        paths = activationPackages;
      };

      homeWeaveInventory."$SYSTEM" = map
        (package:
          let
            metadata = metadataFor package;
            details = originDetailsFor metadata;
          in {
            name = packageLib.getName package;
            version = packageLib.getVersion package;
            storePath = toString package;
            source = "pinned Nix package set";
            attribute = if metadata == null then null else metadata.attribute;
            inherit (details) group inheritedFrom sourceProfile origins;
          })
        activationPackages;
    };
}
EOF

mv "$TEMP_FLAKE" "$TARGET_FLAKE"

# This lock is derived state, not a user-maintained pin. Recreate it so a
# freshly updated profile lock cannot be shadowed by transitive revisions from
# the previous plan/apply run. Removing it first is also required for --no-git
# profiles: otherwise the path input hashes this generated lock while the lock
# itself records the path hash, producing a self-referential NAR mismatch.
rm -f "$CONFIG_DIR/flake.lock"
nix "${NIX_FLAGS[@]}" flake update --flake "$CONFIG_FLAKE"

preflight_activation() {
  local output_file data_root output download_size closure_size local_builds substitutions reporter reporter_status=0 local_build_count=0 substitution_count=0 unfree_name=""
  local download_bytes=0 large_build=false inventory_file inventory_temp
  output_file="$(mktemp)"
  data_root="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}"
  mkdir -p "$data_root"
  if ! nix "${NIX_FLAGS[@]}" build --dry-run --no-link \
    "$CONFIG_FLAKE#home-weave-environment" >"$output_file" 2>&1; then
    cat "$output_file" >&2
    if grep -Eqi 'unfree|license' "$output_file"; then
      unfree_name="$(sed -nE "s/.*Refusing to evaluate package '([^']+)'.*/\1/p" "$output_file" | head -n 1)"
      unfree_name="${unfree_name%-[0-9]*}"
      fail "preflight found unfree package ${unfree_name:-unknown}; set allowUnfree=true for that package in home-weave.json after reviewing the upstream license"
    elif grep -Eqi 'unsupported|not supported on' "$output_file"; then
      fail "preflight found a package unsupported on $SYSTEM; remove it or choose another group"
    fi
    fail "Nix activation preflight failed; no active state was changed"
  fi
  output="$(<"$output_file")"
  printf '%s\n' "$output"
  grep -Eqi 'database is busy|SQLITE_BUSY' "$output_file" \
    && printf 'warning: Nix reported transient SQLite contention but continued successfully.\n' >&2
  reporter="${HOME_WEAVE_PREFLIGHT_REPORTER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/preflight-report.sh}"
  bash "$reporter" --input "$output_file" --output "$data_root/last-preflight.json" \
    --system "$SYSTEM" --unfree "${UNFREE_PACKAGES:-}" || reporter_status=$?
  if ((reporter_status == 42)); then
    fail "Starship has no binary substitute for this Darwin lock and its local link is known to fail; update the public lock"
  elif ((reporter_status != 0)); then
    fail "could not parse the Nix activation preflight"
  fi
  download_size="$(jq -r '.downloadSize' "$data_root/last-preflight.json")"
  closure_size="$(jq -r '.closureSize' "$data_root/last-preflight.json")"
  download_bytes="$(jq -r '.downloadBytes' "$data_root/last-preflight.json")"
  substitutions="$(jq -r '.substitutions[]' "$data_root/last-preflight.json")"
  local_builds="$(jq -r '.localBuilds[]' "$data_root/last-preflight.json")"
  # `grep -c` exits 1 for an empty list. With `set -e -o pipefail` that made a
  # fully cached activation abort without an error even though Nix succeeded.
  local_build_count="$(jq -r '.localBuilds | length' "$data_root/last-preflight.json")"
  substitution_count="$(jq -r '.substitutions | length' "$data_root/last-preflight.json")"
  if ((local_build_count > 20)) || grep -Eqi '(rustc|cargo|golang|go-[0-9]|jdk|gradle|jupyter|vscode|minikube|terraform|llvm|clang).*\.drv' <<<"$local_builds"; then
    large_build=true
  fi
  printf '\nHomeWeave preflight:\n'
  printf '  Compressed download: %s\n' "${download_size:-0 B (cached)}"
  printf '  Expanded closure:   %s\n' "${closure_size:-0 B (cached)}"
  printf '  Cache substitutions: %s\n' "$substitution_count"
  printf '  Required local builds: %s\n' "$local_build_count"
  printf '  Unfree packages: %s\n' "$(jq -r '.unfreePackages | if length == 0 then "none" else join(", ") end' "$data_root/last-preflight.json")"
  printf '  Unsupported packages: %s\n' "$(jq -r '.unsupportedPackages | if length == 0 then "none" else join(", ") end' "$data_root/last-preflight.json")"
  if [[ "$SYSTEM" == *-darwin && "$local_builds" == *starship-* ]]; then
    fail "Starship has no binary substitute for this Darwin lock and its local link is known to fail; update the public nixpkgs-unstable lock"
  fi
  if ! "$GENERATE_ONLY" && { ((download_bytes > 1073741824)) || "$large_build"; }; then
    if ! "$ASSUME_YES"; then
      [[ -t 0 ]] || fail "large download or local compilation requires interactive confirmation or --yes"
      printf 'Continue with the large download/local build? [y/N] '
      read -r answer
      [[ "$answer" == y || "$answer" == Y ]] || fail "activation cancelled after preflight"
    fi
  fi
  inventory_file="$data_root/last-inventory.json"
  inventory_temp="$inventory_file.tmp.$$"
  if ! nix "${NIX_FLAGS[@]}" eval --json \
    "$CONFIG_FLAKE#homeWeaveInventory.$SYSTEM" >"$inventory_temp"; then
    rm -f "$inventory_temp"
    fail "could not evaluate activation inventory; no active state was changed"
  fi
  jq -e 'type == "array"' "$inventory_temp" >/dev/null \
    || fail "activation inventory is invalid; no active state was changed"
  mv "$inventory_temp" "$inventory_file"
  rm -f "$output_file"
}

mkdir -p "${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}"
printf '%s\n' nix-preflight >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
preflight_activation

if "$GENERATE_ONLY"; then
  rm -f "${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
  printf 'Generated %s for %s/%s (%s).\n' \
    "$CONFIG_DIR" "$PROFILE" "$SELECTED_SHELL" "$SYSTEM"
  exit 0
fi

profile_generation() {
  local link
  link="$(readlink "$PACKAGE_PROFILE_PATH" 2>/dev/null || true)"
  if [[ "$link" =~ ^home-weave-([0-9]+)-link$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

PREVIOUS_PACKAGE_GENERATION="$(profile_generation)"
PREVIOUS_PACKAGE_STORE_PATH="$(readlink -f "$PACKAGE_PROFILE_PATH" 2>/dev/null || true)"

printf '%s\n' package-build >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
ENVIRONMENT_STORE_PATH="$(nix "${NIX_FLAGS[@]}" build --no-link --print-out-paths \
  "$CONFIG_FLAKE#home-weave-environment")"
[[ -n "$ENVIRONMENT_STORE_PATH" && "$ENVIRONMENT_STORE_PATH" != *$'\n'* \
  && "$ENVIRONMENT_STORE_PATH" == /nix/store/* ]] \
  || fail "package environment build returned an invalid store path"

printf '%s\n' package-profile >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
mkdir -p "$(dirname "$PACKAGE_PROFILE_PATH")"
nix-env --profile "$PACKAGE_PROFILE_PATH" --set "$ENVIRONMENT_STORE_PATH"
ACTIVATION_STARTED=true
PACKAGE_PROFILE_SWITCHED=true

CURRENT_PACKAGE_GENERATION="$(profile_generation)"
CURRENT_PACKAGE_STORE_PATH="$(readlink -f "$PACKAGE_PROFILE_PATH" 2>/dev/null || true)"
if [[ "$CURRENT_PACKAGE_GENERATION" != "$PREVIOUS_PACKAGE_GENERATION" \
  || "$CURRENT_PACKAGE_STORE_PATH" != "$PREVIOUS_PACKAGE_STORE_PATH" ]]; then
  PACKAGE_PROFILE_SWITCHED=true
else
  PACKAGE_PROFILE_SWITCHED=false
fi
[[ -n "$CURRENT_PACKAGE_GENERATION" && "$CURRENT_PACKAGE_STORE_PATH" == "$ENVIRONMENT_STORE_PATH" ]] \
  || fail "dedicated package profile did not switch to the built environment"

PACKAGE_PENDING="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/package-profile-pending.json"
PACKAGE_PENDING_TEMP="$PACKAGE_PENDING.tmp.$$"
if [[ -n "$PREVIOUS_PACKAGE_GENERATION" ]]; then
  PREVIOUS_GENERATION_JSON="$PREVIOUS_PACKAGE_GENERATION"
  PREVIOUS_STORE_PATH_JSON="$PREVIOUS_PACKAGE_STORE_PATH"
else
  PREVIOUS_GENERATION_JSON=null
  PREVIOUS_STORE_PATH_JSON=""
fi
jq -n \
  --arg profilePath "$PACKAGE_PROFILE_PATH" \
  --argjson previousGeneration "$PREVIOUS_GENERATION_JSON" \
  --arg previousStorePath "$PREVIOUS_STORE_PATH_JSON" \
  --argjson currentGeneration "$CURRENT_PACKAGE_GENERATION" \
  --arg currentStorePath "$CURRENT_PACKAGE_STORE_PATH" \
  '{
    schemaVersion: 1,
    profilePath: $profilePath,
    previousGeneration: $previousGeneration,
    previousStorePath: (if $previousGeneration == null then null else $previousStorePath end),
    currentGeneration: $currentGeneration,
    currentStorePath: $currentStorePath
  }' >"$PACKAGE_PENDING_TEMP"
mv "$PACKAGE_PENDING_TEMP" "$PACKAGE_PENDING"

case ":$PATH:" in
  *":$PACKAGE_PROFILE_PATH/bin:"*) ;;
  *) export PATH="$PACKAGE_PROFILE_PATH/bin:$PATH" ;;
esac

compose_profile_components() {
  local composer
  composer="${HOME_WEAVE_DOTFILE_COMPOSER:-${THOUGHTOINNOVATE_DOTFILE_COMPOSER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compose-dotfiles.sh}}"
  [[ -r "$composer" ]] || fail "dotfile composer is missing: $composer"

  nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.dotfilesBySystem.\"$SYSTEM\".profiles.\"$PROFILE\"" \
    | bash "$composer" --shell "$SELECTED_SHELL" \
      --shells "${PROFILE_SHELLS:-$SELECTED_SHELL}" --system "$SYSTEM" --namespace "$NAMESPACE"
}

install_macos_apps() {
  local cask cask_record
  [[ "$OS" == "darwin" ]] || return 0
  PROFILE_CASKS="${PROFILE_CASKS:-}"
  [[ -n "$PROFILE_CASKS" ]] || return 0
  if ! command -v brew >/dev/null 2>&1; then
    printf 'warning: Homebrew is unavailable; declared macOS casks were not installed.\n' >&2
    printf '         Install Homebrew or use the exported nix-darwin module.\n' >&2
    return
  fi
  cask_record="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/installed-casks"
  while IFS= read -r cask; do
    [[ "$cask" =~ ^[a-zA-Z0-9@+._-]+$ ]] || fail "unsafe Homebrew cask name: $cask"
    if ! brew list --cask "$cask" >/dev/null 2>&1; then
      brew install --cask "$cask"
      INSTALLED_CASKS_THIS_RUN+=("$cask")
      mkdir -p "$(dirname "$cask_record")"
      touch "$cask_record"
      grep -Fxq "$cask" "$cask_record" || printf '%s\n' "$cask" >>"$cask_record"
    fi
  done < <(tr ',' '\n' <<<"$PROFILE_CASKS")
}

DOTFILE_SNAPSHOT_ROOT="$(mktemp -d)"
if [[ -d "${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/dotfiles/current" ]]; then
  cp -R "${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/dotfiles/current" "$DOTFILE_SNAPSHOT_ROOT/current"
fi
printf '%s\n' applications >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
install_macos_apps
printf '%s\n' dotfiles >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
compose_profile_components
DOTFILES_CHANGED=true
ACTIVATION_COMMITTED=true
rm -f "${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"

case "$SELECTED_SHELL" in
  nushell) SHELL_PROGRAM="nu" ;;
  *) SHELL_PROGRAM="$SELECTED_SHELL" ;;
esac

printf '\nSetup complete.\n'
printf '  System:  %s\n' "$SYSTEM"
printf '  Profile: %s\n' "$PROFILE"
printf '  Shell:   %s\n' "$SELECTED_SHELL"
printf '  Config:  %s\n' "$CONFIG_DIR"
printf '  Namespace: %s\n' "$NAMESPACE"
printf '\nOpen a new terminal or run: %s/bin/%s\n' "$PACKAGE_PROFILE_PATH" "$SHELL_PROGRAM"
printf 'The login shell was not changed automatically.\n'
