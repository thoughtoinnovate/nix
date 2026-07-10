#!/usr/bin/env bash

set -Eeuo pipefail

PROFILE=""
SELECTED_SHELL=""
BASE_URL="${NIX_BASE_URL:-github:thoughtoinnovate/nix}"
CONFIG_URL="${NIX_CONFIG_URL:-}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/thoughtoinnovate-nix"
DOTFILES_URL="${NIX_DOTFILES_URL:-https://github.com/thoughtoinnovate/dotfiles.git}"
DOTFILES_DIR="${NIX_DOTFILES_DIR:-$HOME/.dotfiles}"
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
  --dotfiles-url URL             Dotfiles Git URL
  --dotfiles-dir PATH            Dotfiles checkout (default: ~/.dotfiles)
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
    --dotfiles-url)
      [[ $# -ge 2 ]] || fail "--dotfiles-url requires a value"
      DOTFILES_URL="$2"
      shift 2
      ;;
    --dotfiles-dir)
      [[ $# -ge 2 ]] || fail "--dotfiles-dir requires a value"
      DOTFILES_DIR="$2"
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
[[ -n "$DOTFILES_URL" && "$DOTFILES_URL" != *$'\n'* ]] || fail "invalid --dotfiles-url"
[[ -n "$DOTFILES_DIR" ]] || fail "invalid --dotfiles-dir"
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

if [[ -n "$CONFIG_URL" ]]; then
  command -v jq >/dev/null 2>&1 \
    || fail "profile setup requires the packaged setup app (nix run ...#setup)"
  schema_version="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.schemaVersion")"
  [[ "$schema_version" == "1" ]] || fail "unsupported profile schema: $schema_version"
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

normalize_repository() {
  local repository="$1"
  repository="${repository%.git}"
  repository="${repository#https://github.com/}"
  repository="${repository#ssh://git@github.com/}"
  repository="${repository#git@github.com:}"
  printf '%s' "$repository"
}

sync_dotfiles() {
  local dotfiles_rev origin package
  local -a stow_packages

  command -v git >/dev/null 2>&1 || fail "Git was not found after Home Manager activation"
  command -v stow >/dev/null 2>&1 || fail "Stow was not found after Home Manager activation"

  dotfiles_rev="$(nix "${NIX_FLAGS[@]}" eval --raw "$BASE_URL#lib.dotfiles.rev")"
  [[ "$dotfiles_rev" =~ ^[0-9a-f]{40}$ ]] || fail "base flake returned an invalid dotfiles revision"

  if [[ -e "$DOTFILES_DIR" ]]; then
    [[ -d "$DOTFILES_DIR/.git" ]] || fail "$DOTFILES_DIR exists but is not a Git checkout"
    origin="$(git -C "$DOTFILES_DIR" remote get-url origin)" \
      || fail "$DOTFILES_DIR has no origin remote"
    [[ "$(normalize_repository "$origin")" == "$(normalize_repository "$DOTFILES_URL")" ]] \
      || fail "$DOTFILES_DIR origin does not match $DOTFILES_URL"
    [[ -z "$(git -C "$DOTFILES_DIR" status --porcelain)" ]] \
      || fail "$DOTFILES_DIR has local changes; commit or move them before updating"
    git -C "$DOTFILES_DIR" fetch --quiet origin "$dotfiles_rev"
  else
    mkdir -p "$(dirname "$DOTFILES_DIR")"
    git clone "$DOTFILES_URL" "$DOTFILES_DIR"
  fi

  git -C "$DOTFILES_DIR" checkout --quiet --detach "$dotfiles_rev"

  stow_packages=(common starship "$SELECTED_SHELL" ghostty nvim)
  for package in "${stow_packages[@]}"; do
    [[ -d "$DOTFILES_DIR/$package" ]] \
      || fail "pinned dotfiles do not contain the '$package' Stow package"
  done

  if ! stow --simulate --restow --no-folding --dir="$DOTFILES_DIR" --target="$HOME" "${stow_packages[@]}"; then
    fail "Stow found a conflict; existing files were left unchanged"
  fi

  stow --restow --no-folding --dir="$DOTFILES_DIR" --target="$HOME" "${stow_packages[@]}"
  printf '  Dotfiles: %s at %s\n' "$DOTFILES_DIR" "$dotfiles_rev"
}

compose_profile_dotfiles() {
  local backup_dir current_dir dotfiles_json layer layer_name package package_dir
  local source_dir stow_root temp_dir

  dotfiles_json="$(nix "${NIX_FLAGS[@]}" eval --json "$CONFIG_URL#lib.setup.dotfiles")"
  [[ "$(jq -r '.layers | length' <<<"$dotfiles_json")" -gt 0 ]] \
    || fail "profile must define at least one dotfile layer"

  stow_root="${XDG_DATA_HOME:-$HOME/.local/share}/thoughtoinnovate/dotfiles"
  current_dir="$stow_root/current"
  temp_dir="$stow_root/.current.new.$$"
  backup_dir="$stow_root/.current.previous.$$"
  mkdir -p "$temp_dir"

  while IFS= read -r layer; do
    layer_name="$(jq -r '.name' <<<"$layer")"
    source_dir="$(jq -r '.source' <<<"$layer")"
    [[ -d "$source_dir" ]] || fail "dotfile layer '$layer_name' source is missing: $source_dir"

    while IFS= read -r package; do
      [[ "$package" == "@shell" ]] && package="$SELECTED_SHELL"
      package_dir="$source_dir/$package"
      [[ -d "$package_dir" ]] \
        || fail "dotfile layer '$layer_name' has no '$package' package"
      cp -a "$package_dir/." "$temp_dir/" \
        || fail "could not merge '$layer_name/$package'; check for file/directory conflicts"
    done < <(jq -r '.packages[]' <<<"$layer")
  done < <(jq -c '.layers[]' <<<"$dotfiles_json")

  if [[ -d "$current_dir" ]]; then
    stow --delete --no-folding --dir="$stow_root" --target="$HOME" current
    mv "$current_dir" "$backup_dir"
  fi
  mv "$temp_dir" "$current_dir"

  if stow --simulate --restow --no-folding --dir="$stow_root" --target="$HOME" current \
    && stow --restow --no-folding --dir="$stow_root" --target="$HOME" current; then
    rm -rf "$backup_dir"
  else
    rm -rf "$current_dir"
    if [[ -d "$backup_dir" ]]; then
      mv "$backup_dir" "$current_dir"
      stow --restow --no-folding --dir="$stow_root" --target="$HOME" current \
        || printf 'warning: automatic dotfile rollback could not restore links\n' >&2
    fi
    fail "Stow found a conflict; the previous dotfile generation was restored"
  fi

  printf '  Dotfiles: composed profile at %s\n' "$current_dir"
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
  compose_profile_dotfiles
else
  sync_dotfiles
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
