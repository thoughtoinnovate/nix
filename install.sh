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
PREVIOUS_HOME_GENERATION=""
HOME_MANAGER_SWITCHED=false
ACTIVATION_COMMITTED=false
DOTFILES_CHANGED=false
DOTFILE_SNAPSHOT_ROOT=""
INSTALLED_CASKS_THIS_RUN=()

cleanup() {
  local home_manager_profile pending_marker rollback_succeeded=false
  if "$HOME_MANAGER_SWITCHED" && ! "$ACTIVATION_COMMITTED"; then
    home_manager_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
    pending_marker="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/home-manager-pending"
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
    if [[ -x "$PREVIOUS_HOME_GENERATION/activate" ]]; then
      printf 'warning: restoring the previous Home Manager generation after activation failure\n' >&2
      if nix-env --profile "$home_manager_profile" --rollback >/dev/null 2>&1 \
        && "$PREVIOUS_HOME_GENERATION/activate" >/dev/null; then
        rollback_succeeded=true
      else
        printf 'warning: automatic Home Manager rollback failed; run %s/activate\n' "$PREVIOUS_HOME_GENERATION" >&2
      fi
    else
      printf 'warning: removing the first Home Manager generation after activation failure\n' >&2
      if printf 'y\n' | nix "${NIX_FLAGS[@]}" run "$CONFIG_FLAKE#home-manager" -- uninstall >/dev/null 2>&1; then
        rollback_succeeded=true
      else
        printf 'warning: automatic removal of the failed first generation did not complete\n' >&2
      fi
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
  --config-dir PATH              Generated Home Manager flake directory
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
substituters = https://cache.nixos.org/"

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

if [[ -n "$CONFIG_URL" ]]; then
  if ! command -v jq >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    fail "profile setup requires the packaged setup app (nix run ...#setup)"
  fi
  schema_version="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.schemaVersion")"
  [[ "$schema_version" == "3" ]] \
    || fail "unsupported profile schema: $schema_version (this HomeWeave release requires schema 3)"
  if [[ -z "$NAMESPACE" ]]; then
    if profile_namespace="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.namespace" 2>/dev/null)"; then
      NAMESPACE="$profile_namespace"
    fi
  fi
  if [[ -z "$PROFILE" ]]; then
    PROFILE="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.defaults.profile")"
  fi
  profiles_json="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.profiles" 2>/dev/null || true)"
  if [[ -n "$profiles_json" ]]; then
    profile_json="$(jq -ce --arg profile "$PROFILE" '.[$profile] // empty' <<<"$profiles_json")"
    [[ -n "$profile_json" ]] || fail "profile is not exported by $CONFIG_URL: $PROFILE"
    if [[ -z "$SELECTED_SHELL" ]]; then
      SELECTED_SHELL="$(jq -r '.primaryShell' <<<"$profile_json")"
    fi
    PROFILE_SHELLS="$(jq -r '.shells | join(",")' <<<"$profile_json")"
    PROFILE_CASKS="$(jq -r '.homebrewCasks | join(",")' <<<"$profile_json")"
  elif [[ -z "$SELECTED_SHELL" ]]; then
    SELECTED_SHELL="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.defaults.shell")"
  fi
fi

NAMESPACE="${NAMESPACE:-home-weave}"
validate_namespace
CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/$NAMESPACE/generated}"
CONFIG_FLAKE="path:$CONFIG_DIR"

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
  && ! grep -Fq "$MARKER" "$TARGET_FLAKE" \
  && ! grep -Fq '# Generated by thoughtoinnovate/nix install.sh' "$TARGET_FLAKE"; then
  fail "$TARGET_FLAKE already exists and was not generated by HomeWeave"
fi

mkdir -p "$CONFIG_DIR"
TEMP_FLAKE="$CONFIG_DIR/.flake.nix.tmp"
DEVELOPMENT_ENABLED=false
if [[ -n "${profile_json:-}" ]]; then
  [[ "$(jq -r '.development // false' <<<"$profile_json")" == true ]] && DEVELOPMENT_ENABLED=true
  UNFREE_PACKAGES="$(jq -r '.allowUnfree | map(@json) | join(" ")' <<<"$profile_json")"
elif [[ "$PROFILE" == "development" ]]; then
  DEVELOPMENT_ENABLED=true
  UNFREE_PACKAGES='"vscode"'
else
  UNFREE_PACKAGES='"vscode"'
fi

if [[ -n "$CONFIG_URL" ]]; then
  INPUT_DECLARATIONS="profile.url = \"$CONFIG_URL\";
    nix-base.follows = \"profile/nix-base\";"
  CUSTOM_OVERLAY="++ [ inputs.profile.overlays.default ]"
  if [[ -n "${profile_json:-}" ]]; then
    CUSTOM_MODULE="inputs.profile.homeModules.profiles.\"$PROFILE\""
  else
    CUSTOM_MODULE="inputs.profile.homeModules.default"
  fi
else
  INPUT_DECLARATIONS="nix-base.url = \"$BASE_URL\";"
  CUSTOM_OVERLAY=""
  CUSTOM_MODULE=""
fi

cat >"$TEMP_FLAKE" <<EOF
$MARKER
{
  description = "Local Home Manager consumer generated by HomeWeave";

  inputs = {
    $INPUT_DECLARATIONS
    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs = inputs@{ nix-base, nixpkgs, ... }:
    let
      system = "$SYSTEM";
      username = "$USER";
      packageSource = if system == "x86_64-darwin" then nix-base.inputs.nixpkgs-x86-darwin else nixpkgs;
      home-manager = if system == "x86_64-darwin"
        then nix-base.inputs.home-manager-x86-darwin
        else nix-base.inputs.home-manager;
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
      packageGroupNames = builtins.attrNames pkgs.homeWeavePackageGroups;
      groupFor = package:
        let matches = builtins.filter
          (group: builtins.elem (toString package) (map toString pkgs.homeWeavePackageGroups.\${group}))
          packageGroupNames;
        in if matches != [] then builtins.head matches
          else if builtins.elem (toString package) (map toString pkgs.leanDevelopmentPackages) then "development"
          else "base";
      inheritedFor = group:
        if group == "base" && "$PROFILE" != "base" then "base"
        else if group == "development" && "$PROFILE" != "development" then "development"
        else if group != "base" && group != "development" then "$PROFILE"
        else null;
    in
    rec {
      packages."$SYSTEM".home-manager = home-manager.packages."$SYSTEM".home-manager;

      homeConfigurations."$USER" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          nix-base.homeModules.default
          $CUSTOM_MODULE
          {
            home = {
              inherit username;
              homeDirectory = "$HOME";
              stateVersion = "26.05";
            };

            programs.home-manager.enable = true;

            homeWeave = {
              base = {
                enable = true;
                shells = [ "$SELECTED_SHELL" ];
              };
              development.enable = $DEVELOPMENT_ENABLED;
            };
          }
        ];
      };

      homeWeaveInventory."$SYSTEM" = map
        (package: let group = groupFor package; in {
          name = packageLib.getName package;
          version = packageLib.getVersion package;
          storePath = toString package;
          source = "official NixOS package repository";
          inherit group;
          inheritedFrom = inheritedFor group;
        })
        homeConfigurations."$USER".config.home.packages;
    };
}
EOF

mv "$TEMP_FLAKE" "$TARGET_FLAKE"

nix "${NIX_FLAGS[@]}" flake lock "$CONFIG_FLAKE"

preflight_activation() {
  local output_file data_root output download_size closure_size local_builds substitutions reporter reporter_status=0 local_build_count=0 unfree_name=""
  local download_bytes=0 large_build=false
  output_file="$(mktemp)"
  data_root="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}"
  mkdir -p "$data_root"
  if ! nix "${NIX_FLAGS[@]}" build --dry-run --no-link \
    "$CONFIG_FLAKE#homeConfigurations.\"$USER\".activationPackage" >"$output_file" 2>&1; then
    cat "$output_file" >&2
    if grep -Eqi 'unfree|license' "$output_file"; then
      unfree_name="$(sed -nE "s/.*Refusing to evaluate package '([^']+)'.*/\1/p" "$output_file" | head -n 1)"
      unfree_name="${unfree_name%-[0-9]*}"
      fail "preflight found unfree package ${unfree_name:-unknown}; add its package name to allowUnfree in nix/$PROFILE/profile.nix after reviewing the upstream license"
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
  local_build_count="$(grep -c . <<<"$local_builds" | tr -d ' ')"
  if ((local_build_count > 20)) || grep -Eqi '(rustc|cargo|golang|go-[0-9]|jdk|gradle|jupyter|vscode|minikube|terraform|llvm|clang).*\.drv' <<<"$local_builds"; then
    large_build=true
  fi
  printf '\nHomeWeave preflight:\n'
  printf '  Compressed download: %s\n' "${download_size:-0 B (cached)}"
  printf '  Expanded closure:   %s\n' "${closure_size:-0 B (cached)}"
  printf '  Cache substitutions: %s\n' "$(grep -c . <<<"$substitutions" | tr -d ' ')"
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

PREVIOUS_HOME_GENERATION="$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" 2>/dev/null || true)"
printf '%s\n' home-manager >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/operation-phase"
nix "${NIX_FLAGS[@]}" run "$CONFIG_FLAKE#home-manager" -- \
  switch --flake "$CONFIG_FLAKE#$USER"
HOME_MANAGER_SWITCHED=true
mkdir -p "${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}"
printf '%s\n' "$(readlink -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" 2>/dev/null || true)" \
  >"${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}/home-manager-pending"

export PATH="$HOME/.nix-profile/bin:$PATH"

compose_profile_components() {
  local composer
  composer="${HOME_WEAVE_DOTFILE_COMPOSER:-${THOUGHTOINNOVATE_DOTFILE_COMPOSER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compose-dotfiles.sh}}"
  [[ -r "$composer" ]] || fail "dotfile composer is missing: $composer"

  nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.dotfiles" \
    | bash "$composer" --shell "$SELECTED_SHELL" \
      --shells "${PROFILE_SHELLS:-$SELECTED_SHELL}" --namespace "$NAMESPACE"
}

compose_bundled_dotfiles() {
  local composer dotfiles_path
  composer="${HOME_WEAVE_DOTFILE_COMPOSER:-${THOUGHTOINNOVATE_DOTFILE_COMPOSER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compose-dotfiles.sh}}"
  [[ -r "$composer" ]] || fail "dotfile composer is missing: $composer"
  dotfiles_path="$(nix "${NIX_FLAGS[@]}" eval --raw "$BASE_URL#lib.dotfiles.path")"
  [[ -d "$dotfiles_path" ]] || fail "bundled dotfiles are missing: $dotfiles_path"

  jq -n --arg path "$dotfiles_path" '{
    layers: [{
      name: "base",
      source: { kind: "nix", path: $path },
      entries: ["common", "starship", "@shell", "ghostty", "nvim"]
        | map({ from: ., to: ".", mode: "merge" })
    }]
  }' | bash "$composer" --shell "$SELECTED_SHELL" \
    --shells "$SELECTED_SHELL" --namespace "$NAMESPACE"
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
if [[ -n "$CONFIG_URL" ]]; then
  compose_profile_components
else
  compose_bundled_dotfiles
fi
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
printf '\nOpen a new terminal or run: %s/.nix-profile/bin/%s\n' "$HOME" "$SHELL_PROGRAM"
printf 'The login shell was not changed automatically.\n'
