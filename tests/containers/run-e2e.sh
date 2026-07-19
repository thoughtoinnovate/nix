#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTAINER_REPOSITORY=/workspace/homeweave
readonly NIX_VERSION="2.35.1"
DISTROS=()

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: tests/containers/run-e2e.sh [--distro debian|ubuntu|arch]

Build and run the public HomeWeave end-to-end test in isolated Linux
containers. Repeat --distro to select multiple fixtures; all three run by
default. The repository is mounted read-only and no host user state is used.
EOF
}

assert_link_owned_by_root() {
  local destination="$1" root="$2" resolved
  [[ -L "$destination" ]] || fail "expected a managed symlink: $destination"
  resolved="$(readlink -f "$destination")"
  case "$resolved" in
    "$root/.state/dotfiles/current/"*) ;;
    *) fail "managed link has an unexpected source: $destination -> $resolved" ;;
  esac
}

native_route_test() {
  local distro="$1" output
  output="$(bash "$CONTAINER_REPOSITORY/lib/native-provider.sh" plan --action install jq)"
  case "$distro" in
    debian|ubuntu)
      [[ "$output" == 'sudo apt-get install -- jq' ]] \
        || fail "$distro did not route native packages through APT: $output"
      ;;
    arch)
      [[ "$output" == 'sudo pacman -S -- jq' ]] \
        || fail "Arch did not route native packages through Pacman: $output"
      ;;
    *) fail "unsupported container fixture: $distro" ;;
  esac
}

initialize_nix_environment() {
  local daemon_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  local nix_remote="${NIX_REMOTE:-daemon}"

  [[ -r "$daemon_profile" ]] \
    || fail "Nix daemon environment is missing: $daemon_profile"
  # shellcheck disable=SC1090
  source "$daemon_profile"
  export NIX_REMOTE="$nix_remote"

  command -v nix >/dev/null 2>&1 || fail "Nix is unavailable to the fixture user"
  [[ "$(nix --version)" == "nix (Nix) ${NIX_VERSION}" ]] \
    || fail "fixture requires Nix ${NIX_VERSION}; found $(nix --version)"
  nix --extra-experimental-features 'nix-command flakes' store ping >/dev/null \
    || fail "fixture user cannot reach the Nix daemon"
}

clear_fixture_shell_skeleton() {
  local fixture_home="$1" fixture_uid path
  local -a skeleton_files=(.bashrc .bash_profile .profile .bash_logout)

  fixture_uid="$(id -u homeweave)"
  [[ "$fixture_home" == /* && "$fixture_home" != / ]] \
    || fail "unsafe fixture user home: $fixture_home"
  [[ -d "$fixture_home" && ! -L "$fixture_home" ]] \
    || fail "fixture user home is not a real directory: $fixture_home"
  [[ "$(stat -c %u "$fixture_home")" == "$fixture_uid" ]] \
    || fail "fixture user does not own its home: $fixture_home"

  for path in "${skeleton_files[@]}"; do
    path="$fixture_home/$path"
    if [[ -e "$path" || -L "$path" ]]; then
      [[ ! -d "$path" ]] \
        || fail "fixture skeleton path is unexpectedly a directory: $path"
      rm -f -- "$path"
    fi
  done
}

run_as_fixture_user() {
  local distro="$1" root profile_bin status
  [[ "$(id -u)" -ne 0 ]] || fail "container checks must run as a non-root user"
  [[ -r "$CONTAINER_REPOSITORY/flake.nix" ]] || fail "public repository mount is missing"
  if touch "$CONTAINER_REPOSITORY/.container-write-probe" 2>/dev/null; then
    rm -f "$CONTAINER_REPOSITORY/.container-write-probe"
    fail "public repository mount is writable"
  fi
  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "$distro" ]] || fail "fixture expected $distro but found ${ID:-unknown}"

  export XDG_CACHE_HOME="$HOME/.cache"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state"
  export NIX_REMOTE=daemon
  root="$HOME/.home-weave-e2e"

  initialize_nix_environment
  native_route_test "$distro"
  nix --accept-flake-config --extra-experimental-features 'nix-command flakes' \
    run "path:$CONTAINER_REPOSITORY#home-weave" -- \
    setup --root "$root" --profile base --shell bash --no-git --no-apply --yes

  "$root/home-weave" config validate
  "$root/home-weave" plan --profile base
  "$root/home-weave" apply --profile base --yes

  profile_bin="$XDG_STATE_HOME/nix/profiles/home-weave/bin"
  [[ -x "$profile_bin/home-weave" ]] || fail "activated profile does not expose home-weave"
  status="$("$profile_bin/home-weave" status --root "$root" --json)"
  jq -e --arg profile "$XDG_STATE_HOME/nix/profiles/home-weave" '
    .schemaVersion == 2
    and .activeProfile == "base"
    and .packageProfile.backend == "nix-profile"
    and .packageProfile.profilePath == $profile
  ' >/dev/null <<<"$status" || fail "status did not report the dedicated package profile"

  assert_link_owned_by_root "$HOME/.bashrc" "$root"
  assert_link_owned_by_root "$HOME/.bash_profile" "$root"
  assert_link_owned_by_root "$HOME/.home_weave_profile" "$root"
  assert_link_owned_by_root "$HOME/.config/starship.toml" "$root"
  assert_link_owned_by_root "$HOME/.config/nvim/init.lua" "$root"
  [[ ! -e "$HOME/Library/Application Support/nushell" ]] \
    || fail "Linux activation created the macOS Nushell destination"

  "$root/home-weave" uninstall --all --yes
  [[ ! -e "$XDG_STATE_HOME/nix/profiles/home-weave" ]] \
    || fail "receipt-owned package profile remains after uninstall"
  [[ ! -e "$HOME/.bashrc" && ! -L "$HOME/.bashrc" ]] \
    || fail "managed Bash link remains after uninstall"
  [[ -d "$root" ]] || fail "normal uninstall removed the reusable profile repository"
  printf 'HomeWeave container E2E passed: %s\n' "$distro"
}

run_inside_container() {
  local distro="$1" daemon_pid fixture_home status=0
  [[ "$(id -u)" -eq 0 ]] || fail "container bootstrap must start as root"
  command -v nix-daemon >/dev/null 2>&1 || fail "nix-daemon is missing from the fixture"
  mkdir -p /nix/var/nix/daemon-socket
  nix-daemon --daemon &
  daemon_pid=$!
  trap 'kill "$daemon_pid" 2>/dev/null || true' EXIT
  for _ in {1..100}; do
    [[ -S /nix/var/nix/daemon-socket/socket ]] && break
    sleep 0.1
  done
  [[ -S /nix/var/nix/daemon-socket/socket ]] || fail "nix-daemon did not become ready"
  fixture_home="$(getent passwd homeweave | cut -d: -f6)"
  [[ "$fixture_home" == /* ]] || fail "could not resolve the fixture user home"
  clear_fixture_shell_skeleton "$fixture_home"
  sudo -H -u homeweave env \
    HOME="$fixture_home" USER=homeweave LOGNAME=homeweave NIX_REMOTE=daemon \
    bash "$CONTAINER_REPOSITORY/tests/containers/run-e2e.sh" --fixture-user "$distro" \
    || status=$?
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  trap - EXIT
  return "$status"
}

run_host() {
  local distro image
  command -v docker >/dev/null 2>&1 || fail "Docker is required for container E2E tests"
  docker info >/dev/null 2>&1 || fail "Docker daemon is not available"
  ((${#DISTROS[@]} > 0)) || DISTROS=(debian ubuntu arch)
  for distro in "${DISTROS[@]}"; do
    case "$distro" in debian|ubuntu|arch) ;; *) fail "unsupported distro: $distro" ;; esac
    image="home-weave-e2e-$distro:local"
    printf 'Building HomeWeave fixture: %s\n' "$distro"
    docker build --pull --platform linux/amd64 \
      --file "$SCRIPT_DIR/$distro/Dockerfile" --tag "$image" "$SCRIPT_DIR"
    printf 'Running HomeWeave fixture: %s\n' "$distro"
    docker run --rm --init --privileged --platform linux/amd64 \
      --mount "type=bind,src=$REPOSITORY,dst=$CONTAINER_REPOSITORY,readonly" \
      --env "HOME_WEAVE_CONTAINER_DISTRO=$distro" \
      "$image" bash "$CONTAINER_REPOSITORY/tests/containers/run-e2e.sh" --inside "$distro"
  done
}

case "${1:-}" in
  --inside)
    [[ $# -eq 2 ]] || fail "--inside requires one distro"
    run_inside_container "$2"
    ;;
  --fixture-user)
    [[ $# -eq 2 ]] || fail "--fixture-user requires one distro"
    run_as_fixture_user "$2"
    ;;
  --help|-h)
    usage
    ;;
  *)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --distro)
          [[ $# -ge 2 ]] || fail "--distro requires a value"
          DISTROS+=("$2")
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *) fail "unknown option: $1" ;;
      esac
    done
    run_host
    ;;
esac
