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
  --shell fish,zsh --group cloud

ROOT="$TEST_HOME/.home-weave"
test -f "$ROOT/flake.nix"
test -x "$ROOT/home-weave"
test ! -e "$ROOT/.state/active-profile"
test "$(<"$ROOT/.state/selected-profile")" = work
test "$(<"$ROOT/.state/primary-shell")" = fish
grep -Fq 'extends = "development";' "$ROOT/nix/work/profile.nix"
grep -Fq 'shells = [ "fish" "zsh" ];' "$ROOT/nix/work/profile.nix"
grep -Fq 'packageGroups = [ "cloud" ];' "$ROOT/nix/work/profile.nix"
grep -Fq 'nixPackages = [ ];' "$ROOT/nix/work/profile.nix"

# A new named profile inherits base unless --extends selects another parent.
run_cli setup --yes --no-git --no-apply --profile personal --shell zsh
grep -Fq 'extends = "base";' "$ROOT/nix/personal/profile.nix"

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

NEW_FAILED_ROOT="$TEST_HOME/.home-weave-new-failure"
if run_cli setup --root "$NEW_FAILED_ROOT" --yes --no-git --no-apply \
  --profile broken --extends missing --shell zsh; then
  printf 'expected new invalid profile setup to fail\n' >&2
  exit 1
fi
test ! -e "$NEW_FAILED_ROOT"

# Mutating operations are serialized per repository, while status remains
# available for diagnostics.
mkdir "${ROOT}.operation-lock"
printf '%s\n' "$$" >"${ROOT}.operation-lock/pid"
if run_cli apply --yes 2>"$TEST_ROOT/lock-error"; then
  printf 'expected concurrent apply to fail\n' >&2
  exit 1
fi
grep -Fq 'another HomeWeave operation' "$TEST_ROOT/lock-error"
rm -rf "${ROOT}.operation-lock"

run_cli status --json | jq -e '.installed == false' >/dev/null
mkdir -p "$ROOT/.state/receipts"
jq -n '{schemaVersion: 1, timestamp: "2026-07-12T00:00:00Z", activeProfile: "base",
  parentChain: [], system: "aarch64-darwin", shell: "zsh", nixpkgsRevision: "fixture",
  packages: [], applications: {homebrew: [], native: [], providers: []}, dotfiles: [],
  changes: {added: [], removed: [], changed: [], retained: []},
  rollback: {previousHomeManagerGeneration: "fixture-generation"}}' \
  >"$ROOT/.state/receipts/fixture.json"
ln -s fixture.json "$ROOT/.state/receipts/latest"
run_cli status --json | jq -e '.activeProfile == "base" and .nixpkgsRevision == "fixture"' >/dev/null

# A backend failure must not advance the active profile, dotfile generation,
# applied marker, or latest receipt.
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/nix" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *lib.setup.profiles*)
    printf '%s\n' '{"base":{"extends":null,"primaryShell":"zsh"},"development":{"extends":"base","primaryShell":"zsh"}}'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/nix"
cp "$ROOT/setup.sh" "$TEST_ROOT/setup.sh.saved"
printf '#!/usr/bin/env bash\nexit 23\n' >"$ROOT/setup.sh"
chmod +x "$ROOT/setup.sh"
printf 'base\n' >"$ROOT/.state/active-profile"
mkdir -p "$ROOT/.state/dotfiles/current"
printf 'unchanged\n' >"$ROOT/.state/dotfiles/current/failure-marker"
if PATH="$fake_bin:$PATH" run_cli apply --profile development --yes 2>"$TEST_ROOT/apply-error"; then
  printf 'expected simulated activation failure\n' >&2
  exit 1
fi
test "$(<"$ROOT/.state/active-profile")" = base
test "$(<"$ROOT/.state/dotfiles/current/failure-marker")" = unchanged
test "$(readlink "$ROOT/.state/receipts/latest")" = fixture.json
test ! -e "$ROOT/.state/applied"
cp "$TEST_ROOT/setup.sh.saved" "$ROOT/setup.sh"

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

# Uninstall removes only the active Stow generation, restores missing adopted
# files, keeps the repository, and skips Home Manager without an apply marker.
mkdir -p "$ROOT/.state/dotfiles/current" "$ROOT/backup/restore-test/home"
printf 'managed\n' >"$ROOT/.state/dotfiles/current/.home-weave-managed"
printf 'restored\n' >"$ROOT/backup/restore-test/home/.home-weave-restored"
stow --restow --no-folding --dir="$ROOT/.state/dotfiles" --target="$TEST_HOME" current
test -L "$TEST_HOME/.home-weave-managed"
run_cli uninstall --yes
test ! -e "$TEST_HOME/.home-weave-managed"
grep -Fq restored "$TEST_HOME/.home-weave-restored"
test -d "$ROOT"

run_cli uninstall --profile development --dry-run | grep -Fq 'inactive'
touch "$ROOT/.state/home-manager-pending"
pending_uninstall_output="$(run_cli uninstall --all --dry-run --yes)"
grep -Fq 'Home Manager will remove its managed packages' <<<"$pending_uninstall_output"
rm -f "$ROOT/.state/home-manager-pending"
run_cli uninstall --all --dry-run --yes | grep -Fq 'Repository retained'
run_cli uninstall --nuke --dry-run --yes | grep -Fq 'Would delete HomeWeave-owned root'
run_cli uninstall nuke --dry-run --yes | grep -Fq 'Would delete HomeWeave-owned root'
run_cli uninstall all --dry-run --yes | grep -Fq 'Repository retained'
printf 'must-remain\n' >"$ROOT/.state/active-profile"
if run_cli uninstall nuke --yes 2>"$TEST_ROOT/nuke-confirmation-error"; then
  printf 'expected non-interactive nuke to fail before making changes\n' >&2
  exit 1
fi
grep -Fq 'requires an interactive typed confirmation' "$TEST_ROOT/nuke-confirmation-error"
test "$(<"$ROOT/.state/active-profile")" = must-remain
if run_cli uninstall unexpected --dry-run --yes 2>"$TEST_ROOT/uninstall-mode-error"; then
  printf 'expected an unknown uninstall mode to fail\n' >&2
  exit 1
fi
grep -Fq 'unknown uninstall mode: unexpected' "$TEST_ROOT/uninstall-mode-error"
test -d "$ROOT"

printf 'HomeWeave CLI tests passed.\n'
