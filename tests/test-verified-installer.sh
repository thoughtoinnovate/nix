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
    publisherEvidence: "Reviewed fixture publisher",
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

# Generic managed-artifact provider fixture. Product-specific values belong in
# the catalog; the provider implementation stays unchanged.
mkdir -p "$ROOT/bin" "$ROOT/source/Fixture CLI.app/Contents/MacOS" "$ROOT/home/Applications" "$ROOT/home/.local/bin"
cat > "$ROOT/source/Fixture CLI.app/Contents/MacOS/fixture-cli" <<'EOF'
#!/bin/sh
test "${1:-}" = --version && printf 'fixture-cli 2.0\n'
EOF
chmod +x "$ROOT/source/Fixture CLI.app/Contents/MacOS/fixture-cli"
printf 'fixture dmg\n' > "$ROOT/fixture.dmg"
cat > "$ROOT/manifest.json" <<'EOF'
{"version":"2.0","packages":[{"os":"macos","fileType":"dmg","channel":"stable","download":"2.0/Fixture CLI.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1048576}]}
EOF
cat > "$ROOT/bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *manifest.json) cat "$FIXTURE_MANIFEST" ;;
  *Fixture%20CLI.dmg) cp "$FIXTURE_DMG" "$output" ;;
  *) exit 2 ;;
esac
EOF
cat > "$ROOT/bin/sha256sum" <<'EOF'
#!/bin/sh
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  %s\n' "$1"
EOF
cat > "$ROOT/bin/hdiutil" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = attach ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -mountpoint ]; then cp -R "$FIXTURE_APP" "$2/Fixture CLI.app"; exit; fi
    shift
  done
fi
test "$1" = detach
EOF
cat > "$ROOT/bin/ditto" <<'EOF'
#!/bin/sh
cp -R "$1" "$2"
EOF
cat > "$ROOT/bin/codesign" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --verify ]; then exit 0; fi
printf 'TeamIdentifier=ABCDEFGHIJ\n' >&2
EOF
chmod +x "$ROOT/bin/"*
jq -n '{schemaVersion:1,installers:[{
  id:"fixture-cli",name:"Fixture CLI",kind:"macos-dmg-app",
  publisher:"Fixture Publisher",publisherVerified:true,
  repositoryTrust:"official fixture stable channel",
  publisherEvidence:"Fixture checksum manifest and Apple Team ID",
  reviewedAt:"2026-07-14",officialHosts:["fixture.invalid"],
  release:{manifestUrl:"https://fixture.invalid/stable/manifest.json",
    downloadBaseUrl:"https://fixture.invalid/stable",versionField:"version",
    itemsField:"packages",match:{os:"macos",fileType:"dmg",channel:"stable"},
    downloadField:"download",sha256Field:"sha256",sizeField:"size"},
  install:{bundle:"Fixture CLI.app",destination:"Applications/Fixture CLI.app",
    executable:"Contents/MacOS/fixture-cli",link:".local/bin/fixture-cli",
    appleTeamId:"ABCDEFGHIJ",versionArguments:["--version"]}
}]}' > "$ROOT/artifacts.json"

export FIXTURE_MANIFEST="$ROOT/manifest.json" FIXTURE_DMG="$ROOT/fixture.dmg"
export FIXTURE_APP="$ROOT/source/Fixture CLI.app"
export HOME_WEAVE_VERIFIED_CURL_BIN="$ROOT/bin/curl"
export HOME_WEAVE_VERIFIED_CODESIGN_BIN="$ROOT/bin/codesign"
export HOME_WEAVE_VERIFIED_HDIUTIL_BIN="$ROOT/bin/hdiutil"
export HOME_WEAVE_VERIFIED_DITTO_BIN="$ROOT/bin/ditto"
export HOME_WEAVE_VERIFIED_INSTALLER_ALLOW_NON_DARWIN=1
PATH="$ROOT/bin:$PATH" HOME="$ROOT/home" bash "$VERIFIER" provider "$ROOT/artifacts.json" plan --action install fixture-cli 2>&1 | grep -Fq 'Shell pipe:  never'
PATH="$ROOT/bin:$PATH" HOME="$ROOT/home" bash "$VERIFIER" provider "$ROOT/artifacts.json" apply --action install fixture-cli >/dev/null
PATH="$ROOT/bin:$PATH" HOME="$ROOT/home" bash "$VERIFIER" provider "$ROOT/artifacts.json" inventory | jq -e '.items[0].installed == true and .items[0].publisherVerified == true' >/dev/null
PATH="$ROOT/bin:$PATH" HOME="$ROOT/home" bash "$VERIFIER" provider "$ROOT/artifacts.json" apply --action remove fixture-cli
test ! -e "$ROOT/home/Applications/Fixture CLI.app"
