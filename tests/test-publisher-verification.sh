#!/usr/bin/env bash

set -Eeuo pipefail

filter="$1"
registry="$2"

fixture='{
  "legacyPackages.aarch64-darwin.claude-code": {
    "homepage": "https://github.com/anthropics/claude-code",
    "provenance": ["binaryNativeCode"]
  },
  "legacyPackages.aarch64-darwin.codex": {
    "homepage": "https://github.com/openai/codex",
    "provenance": []
  },
  "legacyPackages.aarch64-darwin.opencode": {
    "homepage": "https://github.com/anomalyco/opencode",
    "provenance": ["binaryNativeCode"]
  },
  "legacyPackages.aarch64-darwin.awscli2": {
    "homepage": "https://aws.amazon.com/cli/",
    "provenance": []
  },
  "legacyPackages.aarch64-darwin.codex-lookalike": {
    "homepage": "https://github.com/openai/codex",
    "provenance": []
  },
  "legacyPackages.aarch64-darwin.opencode-wrong-source": {
    "homepage": "https://github.com/someone/opencode",
    "provenance": ["binaryNativeCode"]
  },
  "legacyPackages.aarch64-darwin.opencode-wrong-provenance": {
    "homepage": "https://github.com/anomalyco/opencode",
    "provenance": ["fromSource"]
  },
  "legacyPackages.aarch64-darwin.claude-code-wrong-provenance": {
    "homepage": "https://github.com/anthropics/claude-code",
    "provenance": ["fromSource"]
  }
}'

result="$(jq --slurpfile registry "$registry" -f "$filter" <<<"$fixture")"

jq -e '
  .["legacyPackages.aarch64-darwin.claude-code"].publisher == "Anthropic" and
  .["legacyPackages.aarch64-darwin.codex"].publisher == "OpenAI" and
  .["legacyPackages.aarch64-darwin.opencode"].publisher == "OpenCode" and
  .["legacyPackages.aarch64-darwin.awscli2"].publisher == "Amazon Web Services" and
  .["legacyPackages.aarch64-darwin.awscli2"].publisherVerified == true and
  .["legacyPackages.aarch64-darwin.codex-lookalike"].publisherVerified == false and
  .["legacyPackages.aarch64-darwin.opencode-wrong-source"].publisherVerified == false and
  .["legacyPackages.aarch64-darwin.opencode-wrong-provenance"].publisherVerified == false and
  .["legacyPackages.aarch64-darwin.claude-code-wrong-provenance"].publisherVerified == false
' >/dev/null <<<"$result"

printf 'Publisher verification tests passed.\n'
