#!/usr/bin/env bash

set -Eeuo pipefail

PROFILE=""
SELECTED_SHELL=""
BASE_URL="${NIX_BASE_URL:-github:thoughtoinnovate/nix}"
CONFIG_URL="${NIX_CONFIG_URL:-}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/thoughtoinnovate-nix"
ASSUME_YES=false
ALLOW_NIX_INSTALL=true
GENERATE_ONLY=false
TEMP_INSTALL_DIR=""

cleanup() {
  if [[ -n "$TEMP_INSTALL_DIR" && -d "$TEMP_INSTALL_DIR" ]]; then
    rm -rf "$TEMP_INSTALL_DIR"
  fi
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --shell bash|zsh|fish|nushell   Shell to install and configure
  --profile base|development     Overlay/profile to activate
  --base-url URL                 Base flake URL (default: github:thoughtoinnovate/nix)
  --config-url URL               User profile flake URL or local path
  --config-dir PATH              Generated Home Manager flake directory
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
    [[ "$OS" == "linux" ]] || fail "current Nixpkgs unstable does not support Intel macOS"
    SYSTEM="x86_64-linux"
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

initialize_profile_interactive() {
  local answer profile_dir remote_url origin

  [[ -z "$CONFIG_URL" && -t 0 ]] || return
  printf 'Create or connect a personal profile repository? [y/N] '
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || return
  command -v git >/dev/null 2>&1 || fail "Git is required to create a personal profile repository"

  printf 'Profile directory [%s]: ' "$HOME/.config/thoughtoinnovate-profile"
  read -r profile_dir
  profile_dir="${profile_dir:-$HOME/.config/thoughtoinnovate-profile}"
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
  [[ "$schema_version" == "1" || "$schema_version" == "2" ]] \
    || fail "unsupported profile schema: $schema_version"
  if [[ -z "$SELECTED_SHELL" ]]; then
    SELECTED_SHELL="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.defaults.shell")"
  fi
  if [[ -z "$PROFILE" ]]; then
    PROFILE="$(nix "${NIX_FLAGS[@]}" eval --raw "$CONFIG_URL#lib.setup.defaults.profile")"
  fi
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

case "$PROFILE" in
  base|development) ;;
  *) fail "unsupported profile: $PROFILE" ;;
esac

MARKER="# Generated by thoughtoinnovate/nix install.sh"
TARGET_FLAKE="$CONFIG_DIR/flake.nix"

if [[ -e "$TARGET_FLAKE" ]] && ! grep -Fq "$MARKER" "$TARGET_FLAKE"; then
  fail "$TARGET_FLAKE already exists and was not generated by this installer"
fi

mkdir -p "$CONFIG_DIR"
TEMP_FLAKE="$CONFIG_DIR/.flake.nix.tmp"
DEVELOPMENT_ENABLED=false
[[ "$PROFILE" == "development" ]] && DEVELOPMENT_ENABLED=true

if [[ -n "$CONFIG_URL" ]]; then
  INPUT_DECLARATIONS="profile.url = \"$CONFIG_URL\";
    nix-base.follows = \"profile/nix-base\";"
  CUSTOM_OVERLAY="++ [ inputs.profile.overlays.default ]"
  CUSTOM_MODULE="inputs.profile.homeModules.default"
else
  INPUT_DECLARATIONS="nix-base.url = \"$BASE_URL\";"
  CUSTOM_OVERLAY=""
  CUSTOM_MODULE=""
fi

cat >"$TEMP_FLAKE" <<EOF
$MARKER
{
  description = "Local Home Manager consumer of thoughtoinnovate/nix";

  inputs = {
    $INPUT_DECLARATIONS
    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs = inputs@{ nix-base, nixpkgs, ... }:
    let
      system = "$SYSTEM";
      username = "$USER";
      home-manager = nix-base.inputs.home-manager;
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nix-base.overlays.base ]
          ++ nixpkgs.lib.optionals $DEVELOPMENT_ENABLED [ nix-base.overlays.development ]
          $CUSTOM_OVERLAY;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "vscode" ];
      };
    in
    {
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

            thoughtoinnovate = {
              base = {
                enable = true;
                shells = [ "$SELECTED_SHELL" ];
              };
              development.enable = $DEVELOPMENT_ENABLED;
            };
          }
        ];
      };
    };
}
EOF

mv "$TEMP_FLAKE" "$TARGET_FLAKE"

nix "${NIX_FLAGS[@]}" flake lock "$CONFIG_DIR"

if "$GENERATE_ONLY"; then
  printf 'Generated %s for %s/%s (%s).\n' \
    "$CONFIG_DIR" "$PROFILE" "$SELECTED_SHELL" "$SYSTEM"
  exit 0
fi

nix "${NIX_FLAGS[@]}" run "$CONFIG_DIR#home-manager" -- \
  switch --flake "$CONFIG_DIR#$USER"

export PATH="$HOME/.nix-profile/bin:$PATH"

compose_profile_components() {
  local composer
  composer="${THOUGHTOINNOVATE_DOTFILE_COMPOSER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compose-dotfiles.sh}"
  [[ -r "$composer" ]] || fail "dotfile composer is missing: $composer"

  nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.dotfiles" \
    | bash "$composer" --shell "$SELECTED_SHELL"
}

compose_bundled_dotfiles() {
  local composer dotfiles_path
  composer="${THOUGHTOINNOVATE_DOTFILE_COMPOSER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compose-dotfiles.sh}"
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
  }' | bash "$composer" --shell "$SELECTED_SHELL"
}

install_macos_ghostty() {
  [[ "$OS" == "darwin" ]] || return
  [[ -d "/Applications/Ghostty.app" || -d "$HOME/Applications/Ghostty.app" ]] && return

  if command -v brew >/dev/null 2>&1; then
    brew install --cask ghostty
  else
    printf 'warning: Homebrew is unavailable; Ghostty was not installed.\n' >&2
    printf '         Install Homebrew or use the exported nix-darwin module.\n' >&2
  fi
}

if [[ -n "$CONFIG_URL" ]]; then
  compose_profile_components
else
  compose_bundled_dotfiles
fi
install_macos_ghostty

case "$SELECTED_SHELL" in
  nushell) SHELL_PROGRAM="nu" ;;
  *) SHELL_PROGRAM="$SELECTED_SHELL" ;;
esac

printf '\nSetup complete.\n'
printf '  System:  %s\n' "$SYSTEM"
printf '  Profile: %s\n' "$PROFILE"
printf '  Shell:   %s\n' "$SELECTED_SHELL"
printf '  Config:  %s\n' "$CONFIG_DIR"
printf '\nOpen a new terminal or run: %s/.nix-profile/bin/%s\n' "$HOME" "$SHELL_PROGRAM"
printf 'The login shell was not changed automatically.\n'
