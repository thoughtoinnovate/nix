#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_URL=""
CONFIG_REF=""
CONFIG_DIR=""
NAMESPACE="${HOME_WEAVE_NAMESPACE:-home-weave}"
NAMESPACE_EXPLICIT=false
SETUP_ARGS=()

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bootstrap.sh --config-url GIT_URL [options] [-- SETUP_OPTIONS]

Options:
  --config-url URL   GitHub, GitLab, self-hosted Git, or local Git URL
  --config-ref REF   Optional branch, tag, or commit
  --config-dir PATH  Checkout directory
  --namespace NAME   Runtime namespace (default: home-weave)
  --help             Show this help

Example:
  ./bootstrap.sh --config-url https://example.org/owner/home-weave-profile.git -- --shell fish
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-url)
      [[ $# -ge 2 ]] || fail "--config-url requires a value"
      CONFIG_URL="$2"
      shift 2
      ;;
    --config-ref)
      [[ $# -ge 2 ]] || fail "--config-ref requires a value"
      CONFIG_REF="$2"
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
      NAMESPACE_EXPLICIT=true
      shift 2
      ;;
    --)
      shift
      SETUP_ARGS=("$@")
      break
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ -n "$CONFIG_URL" ]] || fail "--config-url is required"
[[ "$NAMESPACE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$NAMESPACE" != "." && "$NAMESPACE" != ".." ]] \
  || fail "unsafe namespace: $NAMESPACE"
command -v git >/dev/null 2>&1 || fail "Git is required for central bootstrap"

if [[ -z "$CONFIG_DIR" ]]; then
  repository_name="${CONFIG_URL%/}"
  repository_name="${repository_name##*/}"
  repository_name="${repository_name%.git}"
  [[ "$repository_name" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "could not derive a safe repository name"
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$NAMESPACE/profiles/$repository_name"
fi

if [[ -e "$CONFIG_DIR" ]]; then
  [[ -d "$CONFIG_DIR/.git" ]] || fail "$CONFIG_DIR exists but is not a Git checkout"
  [[ -z "$(git -C "$CONFIG_DIR" status --porcelain)" ]] \
    || fail "$CONFIG_DIR has local changes; commit or move them before updating"
  origin="$(git -C "$CONFIG_DIR" remote get-url origin)" || fail "$CONFIG_DIR has no origin"
  [[ "${origin%.git}" == "${CONFIG_URL%.git}" ]] \
    || fail "$CONFIG_DIR origin does not match $CONFIG_URL"
  git -C "$CONFIG_DIR" fetch --quiet origin
else
  mkdir -p "$(dirname "$CONFIG_DIR")"
  git clone "$CONFIG_URL" "$CONFIG_DIR"
fi

if [[ -n "$CONFIG_REF" ]]; then
  git -C "$CONFIG_DIR" fetch --quiet origin "$CONFIG_REF"
  git -C "$CONFIG_DIR" checkout --quiet --detach FETCH_HEAD
else
  git -C "$CONFIG_DIR" pull --ff-only --quiet
fi

[[ -x "$CONFIG_DIR/setup.sh" ]] || fail "$CONFIG_DIR/setup.sh is missing or not executable"
if "$NAMESPACE_EXPLICIT"; then
  SETUP_ARGS=(--namespace "$NAMESPACE" "${SETUP_ARGS[@]}")
fi
exec "$CONFIG_DIR/setup.sh" "${SETUP_ARGS[@]}"
