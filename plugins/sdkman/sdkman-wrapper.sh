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

# This wrapper runs SDKMAN in a non-interactive Bash process so it can be
# invoked from every HomeWeave-supported shell. Bash completion requires an
# interactive shell; enabling it here makes SDKMAN call the unavailable
# `complete` builtin and abort before processing the requested command.
# Reconcile this managed configuration on every invocation so existing state
# created by an older profile is repaired as soon as the updated wrapper runs.
mkdir -p "$state/etc" "$state/var"
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

mkdir -p "$state/ext" "$state/tmp" \
  "$state/candidates/java" "$state/candidates/gradle" "$state/candidates/coursier" \
  "$state/candidates/sbt" "$state/candidates/scala" "$state/candidates/scalacli"
printf '%s\n' 'java,gradle,coursier,sbt,scala,scalacli' >"$state/var/candidates"

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
seed_candidate coursier 2.1.24 @COURSIER@ true
seed_candidate sbt 2.0.1 @SBT@ true
seed_candidate scala 3.8.4 @SCALA@ true
seed_candidate scalacli 1.15.0 @SCALA_CLI@ true

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
