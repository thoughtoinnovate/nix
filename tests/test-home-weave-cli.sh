#!/usr/bin/env bash

set -Eeuo pipefail
trap 'printf "test-home-weave-cli failed at line %s\n" "$LINENO" >&2' ERR

CLI="$(realpath "$1")"
TEMPLATE="$(realpath "$2")"
ENV_RENDERER="$(realpath "$3")"
NATIVE_PROVIDER="$(realpath "$4")"
NATIVE_PROVIDER_SOURCE="$(realpath "$5")"
test -x "$NATIVE_PROVIDER"
grep -Fq 'for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew' "$NATIVE_PROVIDER_SOURCE" || {
  printf 'native provider does not discover Homebrew outside the controlled Nix PATH\n' >&2
  exit 1
}
grep -Fq 'last-inventory.json' "$CLI" || {
  printf 'receipt generation does not consume preflight inventory\n' >&2
  exit 1
}
grep -Fq '{schemaVersion: 2, timestamp: $timestamp' "$CLI" || {
  printf 'activation receipts are not schema v2\n' >&2
  exit 1
}
grep -Fq 'packageProfile: $packageProfile' "$CLI" || {
  printf 'activation receipts do not record the dedicated package profile\n' >&2
  exit 1
}
if grep -Fq -- '--keep-home-manager' "$CLI"; then
  printf 'legacy Home Manager uninstall option remains exposed\n' >&2
  exit 1
fi
grep -Fq 'install -d -m 0700 "$xdg_cache"' "$CLI" || {
  printf 'nuke-all does not recreate the cleared Nix cache directory\n' >&2
  exit 1
}
grep -Fq 'profile wipe-history --profile "$profile"' "$CLI" || {
  printf 'nuke-all does not wipe non-current generations from the selected user Nix profile\n' >&2
  exit 1
}
if grep -Fq -- '--older-than 0d' "$CLI"; then
  printf 'nuke-all still uses the invalid Nix wipe-history duration 0d\n' >&2
  exit 1
fi
grep -Fq '[[ "$parent" != "$cursor" ]] || break' "$CLI" || {
  printf 'receipt inheritance traversal does not stop at a self-parent profile sentinel\n' >&2
  exit 1
}
grep -Fq 'profile inheritance cycle detected at $parent' "$CLI" || {
  printf 'receipt inheritance traversal does not reject multi-profile cycles\n' >&2
  exit 1
}
if grep -Fq 'Nushell configuration conflict: both ~/.config/nushell' "$CLI"; then
  printf 'setup still rejects a recoverable Darwin Nushell migration state\n' >&2
  exit 1
fi
grep -Fq 'macOS setup will reconcile the native Nushell path' "$CLI" || {
  printf 'setup does not retain the legacy Darwin Nushell path during guided reconciliation\n' >&2
  exit 1
}
grep -Fq "rsync --archive --exclude='history.*'" "$CLI" || {
  printf 'Nushell adoption can copy mutable shell history into the profile repository\n' >&2
  exit 1
}
publication_flow="$(sed -n '/^initialize_git() {/,/^}/p' "$CLI")"
grep -Fq -- '--branch)' "$CLI" || {
  printf 'Git publication does not parse the --branch option\n' >&2
  exit 1
}
grep -Fq 'git ls-remote "$REMOTE_URL"' <<<"$publication_flow" || {
  printf 'Git publication does not verify that the remote repository exists and is accessible\n' >&2
  exit 1
}
grep -Fq '[[ "$confirmation" == "REPLACE $REMOTE_URL $branch" ]]' <<<"$publication_flow" || {
  printf 'Git publication does not require the exact replacement confirmation phrase\n' >&2
  exit 1
}
grep -Fq 'git clone --quiet --single-branch --branch "$branch" "$REMOTE_URL" "$staging"' <<<"$publication_flow" || {
  printf 'Git publication does not clone an existing branch into staging\n' >&2
  exit 1
}
grep -Fq 'scan_secrets "$staging"' <<<"$publication_flow" || {
  printf 'Git publication does not scan staged repository content for secrets\n' >&2
  exit 1
}
grep -Fq 'git -C "$staging" push -u origin "HEAD:refs/heads/$branch"' <<<"$publication_flow" || {
  printf 'Git publication does not use a normal branch push\n' >&2
  exit 1
}
if grep -Eq 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push.*(--force|--force-with-lease)' <<<"$publication_flow"; then
  printf 'Git publication must never force-push generated configuration\n' >&2
  exit 1
fi
grep -Fq 'AKIA[0-9A-Z]{16}' "$CLI" || {
  printf 'secret scan does not detect AWS access-key identifiers\n' >&2
  exit 1
}
grep -Fq 'glpat-[A-Za-z0-9_-]{20,}' "$CLI" || {
  printf 'secret scan does not detect GitLab personal access tokens\n' >&2
  exit 1
}
TEST_ROOT="$(realpath "$(mktemp -d)")"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"
trap 'rm -rf "$TEST_ROOT"' EXIT

write_bash_script() {
  local destination="$1"
  printf '#!%s\n' "$(command -v bash)" >"$destination"
}

grep -Fq -- '--refresh flake update --flake "path:$ROOT"' "$TEMPLATE/setup.sh"
if grep -Fq 'find "$HOME" -type l' "$CLI"; then
  printf 'uninstall must not traverse the entire home to find stale links\n' >&2
  exit 1
fi

run_cli() {
  HOME="$TEST_HOME" \
    HOME_WEAVE_PROFILE_TEMPLATE="$TEMPLATE" \
    HOME_WEAVE_BASE_URL="github:thoughtoinnovate/nix" \
    HOME_WEAVE_TEST_MODE=true \
    HOME_WEAVE_ENV_RENDERER="$ENV_RENDERER" \
    HOME_WEAVE_EXTENSIONS_JSON="${HOME_WEAVE_EXTENSIONS_JSON:-[]}" \
    PROVIDER_LOG="${PROVIDER_LOG:-}" \
    bash "$CLI" "$@"
}

HOME_WEAVE_NATIVE_PROVIDER="$NATIVE_PROVIDER" run_cli provider list \
  | grep -F $'native-official\tinventory,search,install,update,remove,status' >/dev/null

plugin_manifest='{"sdkman":{"schemaVersion":1,"name":"sdkman","kind":"packages","platforms":["aarch64-darwin"],"lifecycle":{"packages":"remove","state":"remove"}}}'
HOME_WEAVE_PLUGINS_JSON="$plugin_manifest" run_cli plugin list \
  | grep -F $'sdkman\tpackages\tpackages=remove,state=remove' >/dev/null
HOME_WEAVE_PLUGINS_JSON="$plugin_manifest" run_cli plugin show sdkman \
  | jq -e '.name == "sdkman" and .lifecycle.state == "remove"' >/dev/null

if run_cli setup --refresh 2>"$TEST_ROOT/misplaced-refresh-error"; then
  printf 'misplaced Nix --refresh option was incorrectly accepted by setup\n' >&2
  exit 1
fi
grep -Fq "place it before 'run'" "$TEST_ROOT/misplaced-refresh-error"

setup_output="$(HOME_WEAVE_FORCE_BANNER=1 run_cli setup --yes --no-git --no-apply \
  --profile work --extends development \
  --shell fish,zsh --group cloud)"
grep -Fq '██╗  ██╗ ██████╗' <<<"$setup_output"
grep -Fq '/\/\  reproducible homes, layered cleanly' <<<"$setup_output"


ROOT="$TEST_HOME/.home-weave"
test -f "$ROOT/flake.nix"
test -f "$ROOT/packages.json"
grep -Fq 'packageDefinitions = ./packages.json;' "$ROOT/flake.nix"
grep -Fq 'localOverlays = [ (import ./overlay.nix) ];' "$ROOT/flake.nix"
jq -e '.schemaVersion == 1 and .packages == {}' "$ROOT/packages.json" >/dev/null
test -x "$ROOT/home-weave"
test ! -e "$ROOT/.state/active-profile"
test "$(<"$ROOT/.state/selected-profile")" = work
test "$(<"$ROOT/.state/primary-shell")" = fish
test -f "$ROOT/README.md"
grep -Fqx '# HomeWeave profile: `work`' "$ROOT/README.md"
grep -Fq 'Generated from the selected `work` profile.' "$ROOT/README.md"
if grep -Fq '@PROFILE@' "$ROOT/README.md"; then
  printf 'generated README retains an unresolved profile placeholder\n' >&2
  exit 1
fi
jq -e '.schemaVersion == 4
  and .profiles.work.extends == "development"
  and .profiles.work.shells == ["fish", "zsh"]
  and .profiles.work.packageGroups == ["cloud"]
  and .profiles.work.packages.nix == []
  and .profiles.work.allowUnfree == ["terraform"]' "$ROOT/home-weave.json" >/dev/null
run_cli config show base | grep -F 'dotfiles/custom/<home-relative-path> -> ~/<home-relative-path>' >/dev/null


# profile create writes only a guide delta unless --shell is explicit.
profile_bin="$TEST_ROOT/profile-create-bin"
mkdir -p "$profile_bin"
write_bash_script "$profile_bin/nix"
cat >>"$profile_bin/nix" <<'EOF'
if [[ "$*" == *lib.setup.profilesBySystem* ]]; then
  printf '%s\n' '{"work":{"extends":"development","shells":["fish","zsh"],"primaryShell":"fish"}}'
else
  exit 1
fi
EOF
chmod +x "$profile_bin/nix"
profile_create_output="$(PATH="$profile_bin:$PATH" run_cli profile create work-child --extends work)"
grep -Fq "  cd $ROOT" <<<"$profile_create_output"
grep -Fq '  vi home-weave.json' <<<"$profile_create_output"
grep -Fq '  ./home-weave config validate' <<<"$profile_create_output"
grep -Fq '  ./home-weave profile diff work-child' <<<"$profile_create_output"
grep -Fq '  ./home-weave profile switch work-child' <<<"$profile_create_output"
jq -e '.profiles["work-child"] ==
  {extends:"work",exclude:{},packageGroups:[],dotfiles:["custom"],packages:{nix:[]}}' \
  "$ROOT/home-weave.json" >/dev/null
PATH="$profile_bin:$PATH" run_cli profile create work-fish --extends work --shell fish
jq -e '.profiles["work-fish"] ==
  {extends:"work",shells:["fish"],primaryShell:"fish",exclude:{},packageGroups:[],dotfiles:["custom"],packages:{nix:[]}}' \
  "$ROOT/home-weave.json" >/dev/null

# A distribution setup creates an inheritance-only child. Parent assets stay
# in the pinned flake input and are never copied into the generated repository.
OVERLAY="$TEST_ROOT/distribution-overlay"
MINIMAL_ROOT="$TEST_HOME/minimal-child"
mkdir -p "$OVERLAY/dotfiles/private-parent"
printf 'must not be copied\n' >"$OVERLAY/dotfiles/private-parent/sentinel"
jq '.defaults.profile = "work-parent"
  | .profiles = {"work-parent": {extends: "development", dotfiles: ["private-parent"], packages: {nix: ["jq"]}}}' \
  "$TEMPLATE/home-weave.json" >"$OVERLAY/home-weave.json"
HOME="$TEST_HOME" HOME_WEAVE_PROFILE_TEMPLATE="$TEMPLATE" \
  HOME_WEAVE_PROFILE_OVERLAY="$OVERLAY" HOME_WEAVE_BASE_URL="github:thoughtoinnovate/nix" \
  HOME_WEAVE_TEST_MODE=true \
  HOME_WEAVE_ENV_RENDERER="$ENV_RENDERER" HOME_WEAVE_EXTENSIONS_JSON='[]' \
  bash "$CLI" setup --root "$MINIMAL_ROOT" --yes --no-git --no-apply \
    --profile work-parent --shell zsh
jq -e '.defaults.profile == "work-parent"
  and (.profiles | keys) == ["work-parent"]
  and .profiles["work-parent"] == {extends:"work-parent",shells:["zsh"],primaryShell:"zsh",exclude:{},packageGroups:[],dotfiles:["custom"],packages:{nix:[]}}' \
  "$MINIMAL_ROOT/home-weave.json" >/dev/null
test -f "$MINIMAL_ROOT/flake.nix"
test -f "$MINIMAL_ROOT/.gitignore"
test -f "$MINIMAL_ROOT/README.md"
test -f "$MINIMAL_ROOT/SECURITY.md"
grep -Fq 'flake lock "path:$ROOT"' "$CLI"
test -f "$MINIMAL_ROOT/dotfiles/custom/.gitkeep"
test -f "$MINIMAL_ROOT/packages.json"
test -f "$MINIMAL_ROOT/overlay.nix"
test ! -e "$MINIMAL_ROOT/home.nix"
test -x "$MINIMAL_ROOT/home-weave"
test ! -e "$MINIMAL_ROOT/setup.sh"
test ! -e "$MINIMAL_ROOT/sentinel"
grep -Fq 'parent = nix-base;' "$MINIMAL_ROOT/flake.nix"
grep -Fq 'packageDefinitions = ./packages.json;' "$MINIMAL_ROOT/flake.nix"
grep -Fq 'localOverlays = [ (import ./overlay.nix) ];' "$MINIMAL_ROOT/flake.nix"
jq -e '.schemaVersion == 1 and .packages == {}' "$MINIMAL_ROOT/packages.json" >/dev/null


# Without an explicit shell, a distribution child inherits the parent's shell
# fields and records only the empty package/dotfile guide deltas.
INHERITED_SHELL_ROOT="$TEST_HOME/minimal-child-inherited-shell"
HOME="$TEST_HOME" HOME_WEAVE_PROFILE_TEMPLATE="$TEMPLATE" \
  HOME_WEAVE_PROFILE_OVERLAY="$OVERLAY" HOME_WEAVE_BASE_URL="github:thoughtoinnovate/nix" \
  HOME_WEAVE_TEST_MODE=true HOME_WEAVE_ACTIVE_SHELL=fish \
  HOME_WEAVE_ENV_RENDERER="$ENV_RENDERER" HOME_WEAVE_EXTENSIONS_JSON='[]' \
  bash "$CLI" setup --root "$INHERITED_SHELL_ROOT" --yes --no-git --no-apply \
    --profile work-parent
jq -e '.profiles["work-parent"] ==
  {extends:"work-parent",exclude:{},packageGroups:[],dotfiles:["custom"],packages:{nix:[]}}
  and (.profiles["work-parent"] | has("shells") | not)
  and (.profiles["work-parent"] | has("primaryShell") | not)' \
  "$INHERITED_SHELL_ROOT/home-weave.json" >/dev/null
grep -Fq 'Nix downloads the parent distribution automatically' \
  "$INHERITED_SHELL_ROOT/README.md"
grep -Fq 'Omitting `shells`' "$INHERITED_SHELL_ROOT/README.md"

# Without --shell, HomeWeave makes the detected invoking shell primary while
# retaining the profile's other configured shells.
AUTO_ROOT="$TEST_HOME/.home-weave-auto-shell"
HOME_WEAVE_ACTIVE_SHELL=fish run_cli setup --root "$AUTO_ROOT" \
  --yes --no-git --no-apply --profile base
test "$(<"$AUTO_ROOT/.state/primary-shell")" = fish
jq -e '.profiles.base.primaryShell == "fish"
  and .profiles.base.shells == ["fish", "zsh"]' \
  "$AUTO_ROOT/home-weave.json" >/dev/null

# Standalone first-run setup still records the detected shell for a new local
# profile because there is no external parent from which to inherit it.
HOME_WEAVE_ACTIVE_SHELL=fish run_cli setup --yes --no-git --no-apply --profile personal
jq -e '.profiles.personal ==
  {extends:"base",shells:["fish"],primaryShell:"fish",exclude:{},packageGroups:[],dotfiles:["custom"],packages:{nix:[]}}' \
  "$ROOT/home-weave.json" >/dev/null

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
cat >"$ROOT/.state/receipts/legacy.json" <<'EOF_LEGACY'
{"schemaVersion":1,"activeProfile":"base"}
EOF_LEGACY
ln -s legacy.json "$ROOT/.state/receipts/latest"
run_cli status --json | jq -e '.installed == false' >/dev/null
jq -n --arg pluginState "$TEST_HOME/.local/share/home-weave/base/plugins/sdkman" \
  --arg legacyNvm '~/.nvm' \
  --arg profile "$TEST_HOME/.local/state/nix/profiles/home-weave" \
  '{schemaVersion: 2, timestamp: "2026-07-12T00:00:00Z", activeProfile: "base",
  parentChain: [], system: "aarch64-darwin", shell: "zsh", nixpkgsRevision: "fixture",
  plugins: {
    sdkman: {lifecycle: {packages: "remove", state: "remove"}, statePaths: [$pluginState]},
    nvm: {lifecycle: {packages: "remove", state: "remove"}, statePaths: [$legacyNvm]}
  },
  packages: [], applications: {homebrew: [], native: [], providers: []}, dotfiles: [],
  changes: {added: [], removed: [], changed: [], retained: []},
  packageProfile: {backend: "nix-profile", profilePath: $profile, currentGeneration: 1,
    currentStorePath: "/nix/store/fixture", previousGeneration: null, previousStorePath: null},
  rollback: {previousPackageGeneration: null, previousPackageStorePath: null,
    previousStowGeneration: "dotfiles/current.previous"}}' \
  >"$ROOT/.state/receipts/fixture.json"
ln -sfn fixture.json "$ROOT/.state/receipts/latest"
run_cli status --json | jq -e '.schemaVersion == 2 and .activeProfile == "base" and .nixpkgsRevision == "fixture"' >/dev/null
# Snapshots preserve declarative HomeWeave state, canonicalize safe exports,
# and include only redacted secret variable names.
cat >"$TEST_HOME/.home_weave_profile" <<'EOF'
EXAMPLE_REGION=us-east-1
EOF
cat >"$TEST_HOME/.home_weave_secrets" <<'EOF'
OPEN_AI_API_KEY=must-never-enter-the-snapshot
EOF
chmod 0600 "$TEST_HOME/.home_weave_secrets"
printf 'export VAULT_ADDR=https://vault.example.invalid:8200\n' >"$TEST_HOME/.bash_profile"
export VAULT_ADDR=https://vault.example.invalid:8200
snapshot_bin="$TEST_ROOT/snapshot-bin"
mkdir -p "$snapshot_bin"
write_bash_script "$snapshot_bin/nix"
cat >>"$snapshot_bin/nix" <<'EOF'
if [[ "${1:-} ${2:-}" == "profile list" ]]; then
  printf '%s\n' '{"packages":{"storePaths":["/nix/store/example"],"originalUrl":"nixpkgs#example"}}'
elif [[ "$*" == *lib.setup.profiles* ]]; then
  printf '%s\n' '{"base":{"extends":null,"shells":["zsh"],"primaryShell":"zsh"}}'
else
  exit 1
fi
EOF
chmod +x "$snapshot_bin/nix"
SNAPSHOT="$TEST_HOME/portable-snapshot"
PATH="$snapshot_bin:$PATH" run_cli snapshot create "$SNAPSHOT"
test -f "$SNAPSHOT/snapshot.json"
grep -Fqx 'EXAMPLE_REGION=us-east-1' "$SNAPSHOT/dotfiles/custom/.home_weave_profile"
grep -Fqx 'VAULT_ADDR=https://vault.example.invalid:8200' "$SNAPSHOT/dotfiles/custom/.home_weave_profile"
grep -Fqx 'OPEN_AI_API_KEY=' "$SNAPSHOT/metadata/home_weave_secrets.example"
if rg -n 'must-never-enter-the-snapshot' "$SNAPSHOT"; then
  printf 'snapshot leaked a secret value\n' >&2
  exit 1
fi
test -z "$(find "$SNAPSHOT" -name .home_weave_secrets -print -quit)"
jq -e '.portability.secretValuesIncluded == false and
  .observedExternalNixProfile[0].name == "packages"' "$SNAPSHOT/snapshot.json" >/dev/null

RESTORED="$TEST_HOME/restored-home-weave"
run_cli snapshot restore "$SNAPSHOT" --root "$RESTORED"
test -f "$RESTORED/flake.nix"
test -f "$RESTORED/snapshot.json"
test ! -e "$RESTORED/metadata"
test ! -e "$RESTORED/.state/active-profile"
test "$(<"$RESTORED/.state/selected-profile")" = base
test "$(<"$RESTORED/.state/primary-shell")" = zsh

# A backend failure must not advance the active profile, dotfile generation,
# applied marker, or latest receipt.
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
write_bash_script "$fake_bin/nix"
cat >>"$fake_bin/nix" <<'EOF'
case "$*" in
  *lib.setup.profiles*)
    printf '%s\n' '{"base":{"extends":null,"primaryShell":"zsh"},"development":{"extends":"base","primaryShell":"zsh"}}'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/nix"
cp "$ROOT/setup.sh" "$TEST_ROOT/setup.sh.saved"
write_bash_script "$ROOT/setup.sh"
printf 'exit 23\n' >>"$ROOT/setup.sh"
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
jq -e '.command == "apply" and .status == "failed" and .phase == "activation"' \
  "$ROOT/.state/last-operation.json" >/dev/null || {
    cat "$ROOT/.state/last-operation.json" >&2
    cat "$(readlink -f "$ROOT/.state/logs/latest")" >&2
    exit 1
  }
latest_log="$(readlink -f "$ROOT/.state/logs/latest")"
test -n "$(find "$latest_log" -prune -perm 600 -print)"
run_cli logs | grep -Fq '.log'
latest_log_output="$(run_cli logs --latest --tail 20)"
grep -Fq 'activation failed; adopted configurations were restored' <<<"$latest_log_output"
run_cli status --json | jq -e '.lastOperation.status == "failed" and .lastOperation.logPath != null' >/dev/null
cp "$TEST_ROOT/setup.sh.saved" "$ROOT/setup.sh"

provider="$TEST_ROOT/fake-provider"
provider_log="$TEST_ROOT/provider.log"
write_bash_script "$provider"
cat >>"$provider" <<'EOF'
set -eu
case "$1" in
  catalog) printf '%s\n' '{"schemaVersion":1,"groups":[{"id":"tools","name":"Tools"}],"items":[{"id":"managed","name":"Managed App","group":"tools"}]}' ;;
  inventory) printf '%s\n' '{"schemaVersion":1,"items":[{"id":"managed","name":"Managed App","installed":true}]}' ;;
  snapshot) printf '%s\n' '{"schemaVersion":1,"selectedPackages":["managed"],"inventory":{"schemaVersion":1,"items":[{"id":"managed","installed":true}]}}' ;;
  search) printf '%s\n' '{"schemaVersion":1,"items":[]}' ;;
  plan) printf 'plan %s\n' "$*" >>"$PROVIDER_LOG" ;;
  apply) printf 'apply %s\n' "$*" >>"$PROVIDER_LOG" ;;
  command) printf 'command %s\n' "$*" ;;
esac
EOF
chmod +x "$provider"
manifest="$(jq -cn --arg executable "$provider" '[{
  schemaVersion: 2,
  name: "fake",
  executable: $executable,
  removalPolicy: "remove",
  platforms: ["aarch64-darwin", "x86_64-darwin", "aarch64-linux", "x86_64-linux"],
  capabilities: ["catalog", "inventory", "search", "install", "update", "remove", "snapshot", "command"]
}]')"

HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli provider list | grep -Fq $'fake\tcatalog,inventory,search,install,update,remove,snapshot,command'
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli provider catalog fake | jq -e '.groups[0].id == "tools"' >/dev/null
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli provider inventory fake | grep -Fq 'Managed App'
PROVIDER_LOG="$provider_log" HOME_WEAVE_EXTENSIONS_JSON="$manifest" \
  run_cli provider install fake managed --yes
grep -Fq 'plan plan --action install managed' "$provider_log"
grep -Fq 'apply apply --action install managed' "$provider_log"
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli extension list | grep -Fxq fake
HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli extension fake status | grep -Fq 'command command status'

# Native package-manager inventories list installed packages only. A selected
# package absent from that inventory must be planned as an installation, not
# rejected as a missing catalog record.
installed_only_provider="$TEST_ROOT/installed-only-provider"
installed_only_log="$TEST_ROOT/installed-only-provider.log"
write_bash_script "$installed_only_provider"
cat >>"$installed_only_provider" <<'EOF'
set -eu
case "$1" in
  inventory)
    if [[ "${INSTALLED_ONLY_PRESENT:-0}" == 1 ]]; then
      printf '%s\n' '{"schemaVersion":1,"items":[{"id":"glab","name":"glab","installed":true}]}'
    else
      printf '%s\n' '{"schemaVersion":1,"items":[]}'
    fi
    ;;
  plan) printf '%s\n' "$*" >>"$INSTALLED_ONLY_LOG" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$installed_only_provider"
installed_only_manifest="$(jq -cn --arg executable "$installed_only_provider" '[{
  schemaVersion: 2,
  name: "native-test",
  executable: $executable,
  removalPolicy: "remove",
  inventoryMode: "installed-only",
  platforms: ["aarch64-darwin", "x86_64-darwin", "aarch64-linux", "x86_64-linux"],
  capabilities: ["inventory", "install"]
}]')"
mkdir -p "$TEST_ROOT/installed-only-bin"
write_bash_script "$TEST_ROOT/installed-only-bin/nix"
cat >>"$TEST_ROOT/installed-only-bin/nix" <<'EOF'
if [[ "$*" == *lib.setup.profiles* ]]; then
  printf '%s\n' '{"work":{"extends":"development","primaryShell":"fish","providerPackages":{"native-test":["glab"]},"nativePackages":{}}}'
else
  exit 1
fi
EOF
chmod +x "$TEST_ROOT/installed-only-bin/nix"
cp "$ROOT/setup.sh" "$TEST_ROOT/setup.sh.before-installed-only"
write_bash_script "$ROOT/setup.sh"
printf 'exit 0\n' >>"$ROOT/setup.sh"
chmod +x "$ROOT/setup.sh"
installed_only_output="$(PATH="$TEST_ROOT/installed-only-bin:$PATH" \
  INSTALLED_ONLY_LOG="$installed_only_log" HOME_WEAVE_EXTENSIONS_JSON="$installed_only_manifest" \
  run_cli plan --profile work --yes 2>&1)"
grep -Fq 'plan --action install glab' "$installed_only_log"
if grep -Fq 'must expose exactly one inventory item for glab' <<<"$installed_only_output"; then
  printf 'installed-only provider incorrectly required a complete catalog record\n' >&2
  exit 1
fi
mkdir -p "$ROOT/.state"
cat >"$ROOT/.state/provider-status.pending.json" <<'JSON'
{"schemaVersion":1,"profile":"work","complete":true,"degraded":false,"items":[
  {"provider":"native-test","id":"glab","requested":true,"state":"installed",
   "ownership":"home-weave","removalPolicy":"remove"}
]}
JSON
installed_only_owned_output="$(PATH="$TEST_ROOT/installed-only-bin:$PATH" \
  INSTALLED_ONLY_PRESENT=1 INSTALLED_ONLY_LOG="$installed_only_log" \
  HOME_WEAVE_EXTENSIONS_JSON="$installed_only_manifest" \
  run_cli plan --profile work --yes 2>&1)"
grep -Fq 'glab' <<<"$installed_only_owned_output"
grep -Fq 'already installed (HomeWeave-owned)' <<<"$installed_only_owned_output"
rm -f "$ROOT/.state/provider-status.pending.json"
cp "$TEST_ROOT/setup.sh.before-installed-only" "$ROOT/setup.sh"

# Best-effort providers warn for missing and failed items, continue planning
# later items, and leave strict/security validation unchanged.
best_effort_provider="$TEST_ROOT/best-effort-provider"
best_effort_log="$TEST_ROOT/best-effort-provider.log"
write_bash_script "$best_effort_provider"
cat >>"$best_effort_provider" <<'EOF'
set -eu
case "$1" in
  inventory)
    if [[ "${BEST_EFFORT_UNVERIFIED:-0}" == 1 ]]; then
      printf '%s\n' '{"schemaVersion":1,"items":[{"id":"good","name":"Good App","installed":true,"publisherVerified":false}]}'
    else
      printf '%s\n' '{"schemaVersion":1,"items":[
        {"id":"bad-plan","name":"Bad Plan","installed":false,"publisherVerified":true},
        {"id":"good","name":"Good App","installed":false,"publisherVerified":true}]}'
    fi
    ;;
  plan)
    printf '%s\n' "$*" >>"$BEST_EFFORT_LOG"
    [[ "$*" != *'bad-plan'* ]]
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$best_effort_provider"
best_effort_manifest="$(jq -cn --arg executable "$best_effort_provider" '[{
  schemaVersion: 2,
  name: "optional",
  executable: $executable,
  removalPolicy: "retain",
  failurePolicy: "best-effort",
  requirePublisherVerification: true,
  platforms: ["aarch64-darwin", "x86_64-darwin", "aarch64-linux", "x86_64-linux"],
  capabilities: ["inventory", "install"]
}]')"
mkdir -p "$TEST_ROOT/best-effort-bin"
write_bash_script "$TEST_ROOT/best-effort-bin/nix"
cat >>"$TEST_ROOT/best-effort-bin/nix" <<'EOF'
if [[ "$*" == *lib.setup.profiles* ]]; then
  printf '%s\n' '{"work":{"extends":"development","primaryShell":"fish","providerPackages":{"optional":["missing","bad-plan","good"]},"nativePackages":{}}}'
else
  exit 1
fi
EOF
chmod +x "$TEST_ROOT/best-effort-bin/nix"
cp "$ROOT/setup.sh" "$TEST_ROOT/setup.sh.before-best-effort"
write_bash_script "$ROOT/setup.sh"
printf 'exit 0\n' >>"$ROOT/setup.sh"
chmod +x "$ROOT/setup.sh"
best_effort_output="$(PATH="$TEST_ROOT/best-effort-bin:$PATH" \
  BEST_EFFORT_LOG="$best_effort_log" HOME_WEAVE_EXTENSIONS_JSON="$best_effort_manifest" \
  run_cli plan --profile work --yes 2>&1)"
grep -Fq 'does not expose missing; skipped it' <<<"$best_effort_output"
grep -Fq 'could not plan installation of bad-plan; skipped it' <<<"$best_effort_output"
grep -Fq 'provider reconciliation is degraded' <<<"$best_effort_output"
grep -Fq 'plan --action install good' "$best_effort_log"
if PATH="$TEST_ROOT/best-effort-bin:$PATH" BEST_EFFORT_UNVERIFIED=1 \
  BEST_EFFORT_LOG="$best_effort_log" HOME_WEAVE_EXTENSIONS_JSON="$best_effort_manifest" \
  run_cli plan --profile work --yes >/dev/null 2>&1; then
  printf 'best-effort provider incorrectly ignored required publisher verification\n' >&2
  exit 1
fi
cp "$TEST_ROOT/setup.sh.before-best-effort" "$ROOT/setup.sh"

PROVIDER_SNAPSHOT="$TEST_HOME/provider-snapshot"
PATH="$snapshot_bin:$PATH" HOME_WEAVE_EXTENSIONS_JSON="$manifest" run_cli snapshot create "$PROVIDER_SNAPSHOT"
jq -e '.providerSnapshots.fake.selectedPackages == ["managed"]' "$PROVIDER_SNAPSHOT/snapshot.json" >/dev/null
snapshot_platform=linux
[[ "$(uname -s)" != Darwin ]] || snapshot_platform=macos
jq -e --arg platform "$snapshot_platform" '.profiles.base.platforms[$platform].plugins.fake == {enabled:true,groups:[],items:["managed"]}' \
  "$PROVIDER_SNAPSHOT/home-weave.json" >/dev/null
test -f "$PROVIDER_SNAPSHOT/metadata/provider-fake.json"

# Git is optional. Update must address the HomeWeave root as an explicit path
# flake so untracked or ignored files are not filtered by Nix's Git fetcher.
mkdir -p "$TEST_ROOT/update-bin"
write_bash_script "$TEST_ROOT/update-bin/nix"
cat >>"$TEST_ROOT/update-bin/nix" <<'EOF'
printf '%s\n' "$*" >>"$UPDATE_NIX_LOG"
EOF
chmod +x "$TEST_ROOT/update-bin/nix"
export UPDATE_NIX_LOG="$TEST_ROOT/update-nix.log"
PATH="$TEST_ROOT/update-bin:$PATH" run_cli update >/dev/null
grep -Fq -- "--refresh flake update --flake path:$ROOT" "$UPDATE_NIX_LOG"

# Uninstall removes only the active Stow generation, restores missing adopted
# files, keeps the repository, and skips package removal when no dedicated profile is active.
mkdir -p "$ROOT/.state/dotfiles/current" "$ROOT/backup/restore-test/home"
printf 'managed\n' >"$ROOT/.state/dotfiles/current/.home-weave-managed"
printf 'restored\n' >"$ROOT/backup/restore-test/home/.home-weave-restored"
stow --restow --no-folding --dir="$ROOT/.state/dotfiles" --target="$TEST_HOME" current
test -L "$TEST_HOME/.home-weave-managed"
cat >"$ROOT/.state/provider-status.json" <<'JSON'
{"schemaVersion":1,"profile":"work","complete":true,"degraded":false,"items":[
  {"provider":"fake","id":"managed","requested":true,"state":"installed",
   "ownership":"home-weave","removalPolicy":"retain"}
]}
JSON
mkdir -p "$TEST_HOME/.local/share/home-weave/base/plugins/sdkman"
printf 'mutable\n' >"$TEST_HOME/.local/share/home-weave/base/plugins/sdkman/state"
mkdir -p "$TEST_HOME/.nvm"
printf 'retain me\n' >"$TEST_HOME/.nvm/alias"
uninstall_output="$(run_cli uninstall --yes 2>&1)"
grep -Fq 'Retained 1 provider-managed application(s): [fake] managed' <<<"$uninstall_output"
grep -Fq 'Removed plugin state: [sdkman]' <<<"$uninstall_output"
grep -Fq "plugin nvm recorded state outside HomeWeave's managed state root; retained: ~/.nvm" \
  <<<"$uninstall_output"
test ! -e "$TEST_HOME/.local/share/home-weave/base/plugins/sdkman"
grep -Fqx 'retain me' "$TEST_HOME/.nvm/alias"
test ! -e "$TEST_HOME/.home-weave-managed"
grep -Fq restored "$TEST_HOME/.home-weave-restored"
test -d "$ROOT"

# Uninstall automatically removes dangling links whose normalized targets
# belong to this HomeWeave root. It supports both absolute and relative Stow
# links and retains unrelated broken links.
mkdir -p "$TEST_HOME/.config"
ln -s "$ROOT/.state/dotfiles/current/.config/stale-absolute" \
  "$TEST_HOME/.config/stale-absolute"
ln -s "../.home-weave/.state/dotfiles/current/.config/stale-relative" \
  "$TEST_HOME/.config/stale-relative"
ln -s "/missing/not-homeweave" "$TEST_HOME/.config/unrelated-broken"
jq --arg absolute "$TEST_HOME/.config/stale-absolute" \
  --arg relative "$TEST_HOME/.config/stale-relative" \
  '.dotfiles = [
    {destination: $absolute, source: "fixture", layer: "fixture"},
    {destination: $relative, source: "fixture", layer: "fixture"}
  ]' "$ROOT/.state/receipts/fixture.json" >"$ROOT/.state/receipts/fixture.json.tmp"
mv "$ROOT/.state/receipts/fixture.json.tmp" "$ROOT/.state/receipts/fixture.json"

run_cli uninstall --profile development --dry-run | grep -Fq 'inactive'
pending_uninstall_output="$(run_cli uninstall --all --dry-run --yes)"
grep -Fq 'No active HomeWeave Nix package profile was found.' <<<"$pending_uninstall_output"
grep -Fq 'Would remove 2 dangling HomeWeave-owned link(s).' <<<"$pending_uninstall_output"
test -L "$TEST_HOME/.config/stale-absolute"

# Only a schema-v2 receipt matching the exact dedicated profile generation and
# store target authorizes package-profile removal.
mkdir -p "$TEST_ROOT/uninstall-bin" "$TEST_HOME/.local/state/nix/profiles"
profile_dir="$TEST_HOME/.local/state/nix/profiles"
owned_store="$TEST_ROOT/home-weave-owned-store"
mkdir -p "$owned_store"
ln -sfn "$owned_store" "$profile_dir/home-weave-7-link"
ln -sfn home-weave-7-link "$profile_dir/home-weave"
jq --arg profile "$profile_dir/home-weave" --arg store "$owned_store" \
  '.packageProfile = {backend:"nix-profile", profilePath:$profile, currentGeneration:7,
    currentStorePath:$store, previousGeneration:6, previousStorePath:"/nix/store/previous"}
   | .rollback = {previousPackageGeneration:6, previousPackageStorePath:"/nix/store/previous",
      previousStowGeneration:"dotfiles/current.previous"}' \
  "$ROOT/.state/receipts/fixture.json" >"$ROOT/.state/receipts/fixture.json.tmp"
mv "$ROOT/.state/receipts/fixture.json.tmp" "$ROOT/.state/receipts/fixture.json"
write_bash_script "$TEST_ROOT/uninstall-bin/nix"
cat >>"$TEST_ROOT/uninstall-bin/nix" <<'EOF_NIX'
printf '%s\n' "$*" >>"$UNINSTALL_NIX_LOG"
EOF_NIX
chmod +x "$TEST_ROOT/uninstall-bin/nix"
export UNINSTALL_NIX_LOG="$TEST_ROOT/uninstall-nix.log"
receipt_uninstall_output="$(PATH="$TEST_ROOT/uninstall-bin:$PATH" run_cli uninstall --all --yes)"
grep -Fq 'receipt-owned Nix package profile' <<<"$receipt_uninstall_output"
grep -Fq "profile remove --profile $profile_dir/home-weave --all" "$UNINSTALL_NIX_LOG"
grep -Fq "profile wipe-history --profile $profile_dir/home-weave" "$UNINSTALL_NIX_LOG"
test ! -L "$profile_dir/home-weave"
test ! -L "$profile_dir/home-weave-7-link"
test ! -L "$TEST_HOME/.config/stale-absolute"
test ! -L "$TEST_HOME/.config/stale-relative"
test -L "$TEST_HOME/.config/unrelated-broken"
dry_run_output="$(run_cli uninstall --all --dry-run --yes)"
grep -Fq 'Repository retained' <<<"$dry_run_output"
dry_run_output="$(run_cli uninstall --nuke --dry-run --yes)"
grep -Fq 'Would delete HomeWeave-owned root' <<<"$dry_run_output"
dry_run_output="$(run_cli uninstall nuke --dry-run --yes)"
grep -Fq 'Would delete HomeWeave-owned root' <<<"$dry_run_output"
dry_run_output="$(run_cli uninstall all --dry-run --yes)"
grep -Fq 'Repository retained' <<<"$dry_run_output"

# Global Nix cleanup is a separate, visibly destructive command. Dry-run must
# not touch either HomeWeave or user Nix state, and --yes must never bypass its
# exact typed confirmation.
mkdir -p "$TEST_HOME/.cache/nix"
printf 'retain during dry run\n' >"$TEST_HOME/.cache/nix/marker"
dry_run_output="$(run_cli nuke-all --dry-run --yes)"
grep -Fq 'DESTRUCTIVE GLOBAL NIX CLEANUP' <<<"$dry_run_output"
grep -Fq 'Would remove all elements from the current user default Nix profile.' <<<"$dry_run_output"
grep -Fq 'Would run nix-collect-garbage -d last.' <<<"$dry_run_output"
grep -Fq 'Would retain the Nix daemon, installer, and /nix infrastructure.' <<<"$dry_run_output"
test -f "$TEST_HOME/.cache/nix/marker"
test -d "$ROOT"
if run_cli nuke-all --yes 2>"$TEST_ROOT/nuke-all-confirmation-error"; then
  printf 'expected non-interactive nuke-all to require typed confirmation\n' >&2
  exit 1
fi
grep -Fq 'requires an interactive typed confirmation' "$TEST_ROOT/nuke-all-confirmation-error"
test -f "$TEST_HOME/.cache/nix/marker"
test -d "$ROOT"

other_store="$TEST_ROOT/home-weave-other-store"
mkdir -p "$other_store"
ln -sfn "$other_store" "$profile_dir/home-weave-8-link"
ln -sfn home-weave-8-link "$profile_dir/home-weave"
if run_cli uninstall --all --dry-run --yes 2>"$TEST_ROOT/generation-mismatch-error"; then
  printf 'expected a receipt generation mismatch to stop uninstall\n' >&2
  exit 1
fi
grep -Fq 'does not own the current HomeWeave Nix package profile generation' "$TEST_ROOT/generation-mismatch-error"
rm -f "$profile_dir/home-weave" "$profile_dir/home-weave-8-link"
legacy_store="$TEST_ROOT/legacy-home-manager-store"
mkdir -p "$legacy_store"
ln -sfn "$legacy_store" "$profile_dir/home-manager"
if run_cli plan --profile base 2>"$TEST_ROOT/legacy-home-manager-error"; then
  printf 'expected an active legacy Home Manager profile to block plan\n' >&2
  exit 1
fi
grep -Fq 'active legacy Home Manager profile' "$TEST_ROOT/legacy-home-manager-error"
rm -f "$profile_dir/home-manager"
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
