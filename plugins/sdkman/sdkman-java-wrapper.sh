#!/usr/bin/env bash
set -euo pipefail

profile="${HOME_WEAVE_SDKMAN_PROFILE:-default}"
state="${SDKMAN_DIR:-${HOME_WEAVE_SDKMAN_STATE:-${XDG_DATA_HOME:-${HOME}/.local/share}/home-weave/${profile}/plugins/sdkman}}"
version=5.23.0
native_version=0.7.34

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) sdkman_platform=darwinarm64 ;;
  Darwin-x86_64) sdkman_platform=darwinx64 ;;
  Linux-aarch64|Linux-arm64) sdkman_platform=linuxarm64 ;;
  Linux-x86_64) sdkman_platform=linuxx64 ;;
  *) printf 'Unsupported SDKMAN platform: %s-%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 1 ;;
esac

if [[ ! -f "$state/var/version" ]] || [[ "$(cat "$state/var/version")" != "$version" ]]; then
  mkdir -p "$state"
  cp -R @SDKMAN_CLI@/. "$state/"
  cp -R @SDKMAN_NATIVE@/. "$state/"
  chmod -R u+w "$state"
  mkdir -p "$state/etc" "$state/var"
  printf '%s\n' "$version" >"$state/var/version"
  printf '%s\n' "$native_version" >"$state/var/version_native"
  printf '%s\n' "$sdkman_platform" >"$state/var/platform"
fi

mkdir -p "$state/etc" "$state/var" "$state/ext" "$state/tmp" \
  "$state/candidates/java" "$state/candidates/gradle"
printf '%s\n' 'java,gradle' >"$state/var/candidates"
cat >"$state/etc/config" <<'HOME_WEAVE_SDKMAN_CONFIG'
sdkman_auto_answer=false
sdkman_auto_complete=false
sdkman_auto_env=false
sdkman_beta_channel=false
sdkman_checksum_enable=true
sdkman_colour_enable=true
sdkman_debug_mode=false
sdkman_healthcheck_enable=true
sdkman_insecure_ssl=false
sdkman_native_enable=true
sdkman_selfupdate_feature=false
HOME_WEAVE_SDKMAN_CONFIG

remove_managed_candidate() {
  local candidate="$1" candidate_version="$2" candidate_link current_link target
  candidate_link="$state/candidates/$candidate/$candidate_version"
  current_link="$state/candidates/$candidate/current"
  if [[ -L "$candidate_link" ]]; then
    target="$(readlink "$candidate_link")"
    case "$target" in
      /nix/store/*) rm -f "$candidate_link" ;;
    esac
  fi
  if [[ -L "$current_link" ]] \
    && [[ "$(readlink "$current_link")" == "$candidate_version" ]]; then
    rm -f "$current_link"
  fi
  rmdir "$state/candidates/$candidate" 2>/dev/null || true
}

if [[ -f "$state/var/home-weave-managed-candidates" ]]; then
  while read -r managed_candidate managed_version; do
    case "$managed_candidate:$managed_version" in
      java:11.0.31-amzn|java:17.0.19-amzn|java:21.0.11-amzn|java:26.0.1-amzn|gradle:9.6.1) ;;
      *) remove_managed_candidate "$managed_candidate" "$managed_version" ;;
    esac
  done <"$state/var/home-weave-managed-candidates"
else
  # Reconcile state created by the original full wrapper, which predates the
  # managed-candidate manifest. Only fixed HomeWeave Nix-store links qualify.
  remove_managed_candidate coursier 2.1.24
  remove_managed_candidate sbt 2.0.1
  remove_managed_candidate scala 3.8.4
  remove_managed_candidate scalacli 1.15.0
fi

seed_candidate() {
  local candidate="$1" candidate_version="$2" candidate_path="$3" make_current="$4"
  [[ -e "$state/candidates/$candidate/$candidate_version" ]] \
    || ln -s "$candidate_path" "$state/candidates/$candidate/$candidate_version"
  [[ "$make_current" != true ]] || ln -sfn "$candidate_version" "$state/candidates/$candidate/current"
}

seed_candidate java 11.0.31-amzn @JAVA11@ false
seed_candidate java 17.0.19-amzn @JAVA17@ false
seed_candidate java 21.0.11-amzn @JAVA21@ true
seed_candidate java 26.0.1-amzn @JAVA26@ false
seed_candidate gradle 9.6.1 @GRADLE@ true

cat >"$state/var/home-weave-managed-candidates" <<'HOME_WEAVE_MANAGED_CANDIDATES'
java 11.0.31-amzn
java 17.0.19-amzn
java 21.0.11-amzn
java 26.0.1-amzn
gradle 9.6.1
HOME_WEAVE_MANAGED_CANDIDATES

export SDKMAN_DIR="$state"
export JAVA_HOME=@JAVA21@

if [[ "${1:-}" == selfupdate ]]; then
  printf '%s\n' 'SDKMAN self-update is disabled; update the pinned HomeWeave plugin instead.' >&2
  exit 1
fi

if [[ "${1:-}" == install && "${HOME_WEAVE_SDKMAN_ALLOW_RUNTIME_CHANGES:-false}" != true ]]; then
  printf '%s\n' 'SDKMAN runtime changes are disabled by this HomeWeave profile.' >&2
  exit 1
fi

if [[ "${1:-}" == install ]]; then
  printf '%s\n' \
    'Security notice: SDKMAN runtime changes are outside the pinned HomeWeave profile.' \
    'SDKMAN official services remain configured with TLS and checksum verification.' >&2
fi

set +u
# shellcheck disable=SC1090
source "$SDKMAN_DIR/bin/sdkman-init.sh"
sdk "$@"
