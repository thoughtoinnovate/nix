#!/usr/bin/env bash

set -Eeuo pipefail

ci_workflow="${1:?CI workflow is required}"
full_workflow="${2:?full-build workflow is required}"
container_fixture="${3:?container fixture is required}"
shift 3

grep -Fq 'run: bash tests/ci/install-nix.sh' "$ci_workflow"
grep -Fq 'run: bash tests/ci/native-lifecycle.sh' "$ci_workflow"
grep -Fq 'run: bash tests/containers/run-e2e.sh --distro ${{ matrix.distro }}' "$ci_workflow"
grep -Fq 'run: bash tests/ci/install-nix.sh' "$full_workflow"
grep -Fq 'nix flake check path:. --no-build --no-write-lock-file' "$ci_workflow"
grep -Fq 'readonly NIX_VERSION="2.35.1"' "$container_fixture"
grep -Fq 'source "$daemon_profile"' "$container_fixture"
grep -Fq 'export NIX_REMOTE="$nix_remote"' "$container_fixture"
grep -Fq 'command -v nix >/dev/null 2>&1' "$container_fixture"
grep -Fq '[[ "$(nix --version)" == "nix (Nix) ${NIX_VERSION}" ]]' "$container_fixture"
grep -Fq "nix --extra-experimental-features 'nix-command flakes' store ping" \
  "$container_fixture"
grep -Fq '  initialize_nix_environment' "$container_fixture"
grep -Fq 'local -a skeleton_files=(.bashrc .bash_profile .profile .bash_logout)' "$container_fixture"
grep -Fq '[[ "$fixture_home" == /* && "$fixture_home" != / ]]' "$container_fixture"
grep -Fq '[[ "$(stat -c %u "$fixture_home")" == "$fixture_uid" ]]' "$container_fixture"
grep -Fq '  clear_fixture_shell_skeleton "$fixture_home"' "$container_fixture"
cleanup_line="$(grep -nF '  clear_fixture_shell_skeleton "$fixture_home"' \
  "$container_fixture" | cut -d: -f1)"
sudo_line="$(grep -nF '  sudo -H -u homeweave env' \
  "$container_fixture" | cut -d: -f1)"
[[ -n "$cleanup_line" && -n "$sudo_line" && "$cleanup_line" -lt "$sudo_line" ]] || {
  printf 'fixture skeleton cleanup must run before fixture-user execution\n' >&2
  exit 1
}
if grep -Fq 'nix flake archive' "$ci_workflow"; then
  printf 'obsolete flake archive workaround remains in CI workflow\n' >&2
  exit 1
fi

if grep -En 'run:[[:space:]]+tests/(ci|containers)/[^[:space:]]+\.sh' \
  "$ci_workflow" "$full_workflow"; then
  printf 'workflow invokes a repository script through its executable bit\n' >&2
  exit 1
fi

for dockerfile in "$@"; do
  grep -Fq 'RUN bash /tmp/install-nix.sh \' "$dockerfile"
  if grep -Eq '^RUN /tmp/install-nix\.sh([[:space:]\\]|$)' "$dockerfile"; then
    printf 'Dockerfile invokes the copied installer through its executable bit: %s\n' \
      "$dockerfile" >&2
    exit 1
  fi
done

printf 'CI entrypoints initialize pinned daemon Nix without uploaded executable modes.\n'
