#!/usr/bin/env bash

set -Eeuo pipefail

CLI="$(realpath "$1")"
TEMPLATE="$(realpath "$2")"
TEST_ROOT="$(realpath "$(mktemp -d)")"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"
trap 'rm -rf "$TEST_ROOT"' EXIT

run_cli() {
  HOME="$TEST_HOME" \
    HOME_WEAVE_PROFILE_TEMPLATE="$TEMPLATE" \
    HOME_WEAVE_BASE_URL="github:thoughtoinnovate/nix" \
    HOME_WEAVE_EXTENSIONS_JSON="${HOME_WEAVE_EXTENSIONS_JSON:-[]}" \
    PROVIDER_LOG="${PROVIDER_LOG:-}" \
    bash "$CLI" "$@"
}

run_cli setup --yes --no-git --no-apply \
  --profile work --extends development \
  --shell fish,zsh --package awscli2 --package terraform

ROOT="$TEST_HOME/.home-weave"
test -f "$ROOT/flake.nix"
test "$(<"$ROOT/.state/active-profile")" = work
test "$(<"$ROOT/.state/primary-shell")" = fish
grep -Fq 'extends = "development";' "$ROOT/nix/work/profile.nix"
grep -Fq 'shells = [ "fish" "zsh" ];' "$ROOT/nix/work/profile.nix"
grep -Fq 'nixPackages = [ "awscli2" "terraform" ];' "$ROOT/nix/work/profile.nix"

printf 'old setup\n' >"$ROOT/old-marker"
run_cli setup --yes --no-git --no-apply --profile base --shell zsh
backup_marker="$(find "$ROOT/backup" -name old-marker -print -quit)"
test -n "$backup_marker"
test "$(<"$backup_marker")" = "old setup"

printf 'rollback setup\n' >"$ROOT/current-marker"
if run_cli setup --yes --no-git --no-apply --profile broken --extends missing --shell zsh; then
  printf 'expected invalid profile setup to fail\n' >&2
  exit 1
fi
test "$(<"$ROOT/current-marker")" = "rollback setup"

provider="$TEST_ROOT/fake-provider"
provider_log="$TEST_ROOT/provider.log"
cat >"$provider" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1" in
  inventory) printf '%s\n' '{"schemaVersion":1,"items":[{"id":"managed","name":"Managed App","installed":true}]}' ;;
  search) printf '%s\n' '{"schemaVersion":1,"items":[]}' ;;
  plan) printf 'plan %s\n' "$*" >>"$PROVIDER_LOG" ;;
  apply) printf 'apply %s\n' "$*" >>"$PROVIDER_LOG" ;;
  command) printf 'command %s\n' "$*" ;;
esac
EOF
chmod +x "$provider"
manifest="$(jq -cn --arg executable "$provider" '[{
  schemaVersion: 1,
  name: "fake",
  executable: $executable,
  capabilities: ["inventory", "search", "install", "update", "remove", "command"]
}]')"

HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli provider list | grep -Fq $'fake\tinventory,search,install,update,remove,command'
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli provider inventory fake | grep -Fq 'Managed App'
PROVIDER_LOG="$provider_log" HOME_WEAVE_EXTENSIONS_JSON="$manifest" \
  run_cli provider install fake managed --yes
grep -Fq 'plan plan --action install managed' "$provider_log"
grep -Fq 'apply apply --action install managed' "$provider_log"
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli extension list | grep -Fxq fake
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli extension fake status | grep -Fq 'command command status'

printf 'HomeWeave CLI tests passed.\n'
