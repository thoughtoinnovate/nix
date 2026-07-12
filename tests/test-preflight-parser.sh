#!/usr/bin/env bash

set -Eeuo pipefail

REPORTER="$1"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

cat >"$TEMP/cached" <<'EOF'
these 1 paths will be fetched (512.5 MiB download, 1.4 GiB unpacked):
  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-cached-package
EOF
bash "$REPORTER" --input "$TEMP/cached" --output "$TEMP/cached.json" --system aarch64-linux --unfree '"vscode"'
jq -e '.downloadBytes == 537395200 and .closureSize == "1.4 GiB" and
  (.substitutions | length) == 1 and (.localBuilds | length) == 0 and
  .unfreePackages == ["vscode"]' "$TEMP/cached.json" >/dev/null

cat >"$TEMP/local" <<'EOF'
these 1 derivations will be built:
  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-starship-1.26.0.drv
EOF
if bash "$REPORTER" --input "$TEMP/local" --output "$TEMP/local.json" --system aarch64-darwin --unfree ''; then
  printf 'expected the known Darwin Starship local build guard to fail\n' >&2
  exit 1
else
  test "$?" -eq 42
fi
jq -e '(.localBuilds | length) == 1 and .downloadBytes == 0' "$TEMP/local.json" >/dev/null

cat >"$TEMP/large" <<'EOF'
these paths will be fetched (1.2 GiB download, 3.0 GiB unpacked):
  /nix/store/cccccccccccccccccccccccccccccccc-large-package
EOF
bash "$REPORTER" --input "$TEMP/large" --output "$TEMP/large.json" --system x86_64-linux --unfree ''
jq -e '.downloadBytes > 1073741824' "$TEMP/large.json" >/dev/null

printf 'unsupported package: legacy-tool\n' >"$TEMP/unsupported"
bash "$REPORTER" --input "$TEMP/unsupported" --output "$TEMP/unsupported.json" --system aarch64-linux --unfree '"terraform"'
jq -e '.unsupportedPackages == ["legacy-tool"] and .unfreePackages == ["terraform"]' "$TEMP/unsupported.json" >/dev/null

printf 'HomeWeave preflight parser tests passed.\n'
