#!/usr/bin/env bash

set -Eeuo pipefail

INPUT=""
OUTPUT=""
SYSTEM="unknown"
UNFREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --unfree) UNFREE="$2"; shift 2 ;;
    *) printf 'error: unknown preflight reporter option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -r "$INPUT" && -n "$OUTPUT" ]] || { printf 'error: --input and --output are required\n' >&2; exit 1; }

download_size="$(sed -nE 's/.*\(([0-9.]+ [KMGT]iB) download.*/\1/p' "$INPUT" | tail -n 1)"
closure_size="$(sed -nE 's/.*download, ([0-9.]+ [KMGT]iB) unpacked.*/\1/p' "$INPUT" | tail -n 1)"
substitutions="$(awk '
  /^these( [0-9]+)? paths will be fetched/ { section=1; next }
  section && /^  \/nix\/store\// { print; next }
  section { exit }
' "$INPUT")"
local_builds="$(awk '
  /^these( [0-9]+)? derivations will be built/ { section=1; next }
  section && /^  \/nix\/store\/.*\.drv$/ { print; next }
  section { exit }
' "$INPUT")"
unsupported="$(sed -nE 's/.*unsupported package: ([a-zA-Z0-9+._-]+).*/\1/p' "$INPUT")"
download_bytes=0
[[ -z "$download_size" ]] || download_bytes="$(awk -v size="$download_size" 'BEGIN {
  split(size, p, " "); multiplier=1;
  if (p[2] == "KiB") multiplier=1024;
  else if (p[2] == "MiB") multiplier=1048576;
  else if (p[2] == "GiB") multiplier=1073741824;
  else if (p[2] == "TiB") multiplier=1099511627776;
  printf "%.0f", p[1] * multiplier
}')"

jq -n \
  --arg downloadSize "${download_size:-0 B}" --arg closureSize "${closure_size:-0 B}" \
  --argjson downloadBytes "$download_bytes" --arg substitutions "$substitutions" \
  --arg localBuilds "$local_builds" --arg unfree "$UNFREE" \
  --arg unsupported "$unsupported" \
  '{schemaVersion: 1, downloadSize: $downloadSize, downloadBytes: $downloadBytes,
    closureSize: $closureSize,
    substitutions: ($substitutions | split("\n") | map(select(length > 0))),
    localBuilds: ($localBuilds | split("\n") | map(select(length > 0))),
    unfreePackages: ([$unfree | scan("\\\"([^\\\"]+)\\\"") | .[0]]),
    unsupportedPackages: ($unsupported | split("\n") | map(select(length > 0)))}' >"$OUTPUT"

if [[ "$SYSTEM" == *-darwin && "$local_builds" == *starship-* ]]; then
  exit 42
fi
