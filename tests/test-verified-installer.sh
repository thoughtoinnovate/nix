#!/usr/bin/env bash

set -Eeuo pipefail

VERIFIER="$(realpath "$1")"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home"

cat > "$ROOT/installer.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'verified\n' > "$HOME/verified-installer-result"
EOF
hash="$(sha256sum "$ROOT/installer.sh" | awk '{print $1}')"
jq -n --arg url "file://$ROOT/installer.sh" --arg hash "$hash" '{
  schemaVersion: 1,
  installers: [{
    id: "fixture", name: "Fixture", version: "1.0.0", kind: "script",
    url: $url, sha256: $hash, interpreter: "sh", arguments: [],
    publisher: "Fixture Publisher", publisherVerified: true,
    repositoryTrust: "official upstream distribution",
    immutableSource: true, reviewedAt: "2026-07-13",
    officialHosts: ["local-test"]
  }]
}' > "$ROOT/catalog.json"

export HOME_WEAVE_VERIFIED_INSTALLER_TESTING=1
bash "$VERIFIER" validate "$ROOT/catalog.json" >/dev/null
bash "$VERIFIER" plan "$ROOT/catalog.json" fixture | grep -Fq 'Shell pipe:   never'
bash "$VERIFIER" inspect "$ROOT/catalog.json" fixture | grep -Fq 'printf'

if HOME="$ROOT/home" bash "$VERIFIER" apply "$ROOT/catalog.json" fixture 2>"$ROOT/no-approval"; then
  printf 'expected unapproved installer execution to fail\n' >&2
  exit 1
fi
grep -Fq 'requires explicit provider approval' "$ROOT/no-approval"

HOME="$ROOT/home" HOME_WEAVE_VERIFIED_INSTALLER_APPROVED=1 \
  bash "$VERIFIER" apply "$ROOT/catalog.json" fixture >/dev/null
grep -Fqx verified "$ROOT/home/verified-installer-result"

printf 'tampered\n' >> "$ROOT/installer.sh"
if bash "$VERIFIER" inspect "$ROOT/catalog.json" fixture 2>"$ROOT/tampered"; then
  printf 'expected a tampered installer to fail\n' >&2
  exit 1
fi
grep -Fq 'installer checksum mismatch' "$ROOT/tampered"

jq '.installers[0].url = "http://example.invalid/install.sh"' \
  "$ROOT/catalog.json" > "$ROOT/insecure.json"
if bash "$VERIFIER" validate "$ROOT/insecure.json" 2>"$ROOT/insecure"; then
  printf 'expected an insecure URL to fail\n' >&2
  exit 1
fi
grep -Fq 'must use HTTPS' "$ROOT/insecure"
