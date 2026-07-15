#!/usr/bin/env bash

set -Eeuo pipefail

CLI="$(realpath "$1")"
TEMPLATE="$(realpath "$2")"
ENV_RENDERER="$(realpath "$3")"
grep -Fq 'last-inventory.json' "$CLI" || {
  printf 'receipt generation does not consume preflight inventory\n' >&2
  exit 1
}
TEST_ROOT="$(realpath "$(mktemp -d)")"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"
trap 'rm -rf "$TEST_ROOT"' EXIT

grep -Fq -- '--refresh flake update --flake "path:$ROOT"' "$TEMPLATE/setup.sh"
if grep -Fq 'find "$HOME" -type l' "$CLI"; then
  printf 'uninstall must not traverse the entire home to find stale links\n' >&2
  exit 1
fi

run_cli() {
  HOME="$TEST_HOME" \
    HOME_WEAVE_PROFILE_TEMPLATE="$TEMPLATE" \
    HOME_WEAVE_BASE_URL="github:thoughtoinnovate/nix" \
    HOME_WEAVE_ENV_RENDERER="$ENV_RENDERER" \
    HOME_WEAVE_EXTENSIONS_JSON="${HOME_WEAVE_EXTENSIONS_JSON:-[]}" \
    PROVIDER_LOG="${PROVIDER_LOG:-}" \
    bash "$CLI" "$@"
}

if run_cli setup --refresh 2>"$TEST_ROOT/misplaced-refresh-error"; then
  printf 'misplaced Nix --refresh option was incorrectly accepted by setup\n' >&2
  exit 1
fi
grep -Fq "place it before 'run'" "$TEST_ROOT/misplaced-refresh-error"

run_cli setup --yes --no-git --no-apply \
  --profile work --extends development \
  --shell fish,zsh --group cloud

ROOT="$TEST_HOME/.home-weave"
test -f "$ROOT/flake.nix"
test -x "$ROOT/home-weave"
test ! -e "$ROOT/.state/active-profile"
test "$(<"$ROOT/.state/selected-profile")" = work
test "$(<"$ROOT/.state/primary-shell")" = fish
jq -e '.schemaVersion == 3
  and .profiles.work.extends == "development"
  and .profiles.work.shells == ["fish", "zsh"]
  and .profiles.work.packageGroups == ["cloud"]
  and .profiles.work.packages.nix == []
  and .profiles.work.allowUnfree == ["terraform"]' "$ROOT/home-weave.json" >/dev/null
run_cli config show base | grep -F 'dotfiles/custom/<home-relative-path> -> ~/<home-relative-path>' >/dev/null

# A new named profile inherits base unless --extends selects another parent.
run_cli setup --yes --no-git --no-apply --profile personal --shell zsh
jq -e '.profiles.personal.extends == "base"' "$ROOT/home-weave.json" >/dev/null

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

# Snapshots preserve declarative HomeWeave state, canonicalize safe exports,
# and include only redacted secret variable names.
cat >"$TEST_HOME/.home_weave_profile" <<'EOF'
WORK_REGION=us-east-1
EOF
cat >"$TEST_HOME/.home_weave_secrets" <<'EOF'
OPEN_AI_API_KEY=must-never-enter-the-snapshot
EOF
chmod 0600 "$TEST_HOME/.home_weave_secrets"
printf 'export VAULT_ADDR=https://vault.example.invalid:8200\n' >"$TEST_HOME/.bash_profile"
export VAULT_ADDR=https://vault.example.invalid:8200
snapshot_bin="$TEST_ROOT/snapshot-bin"
mkdir -p "$snapshot_bin"
cat >"$snapshot_bin/nix" <<'EOF'
#!/usr/bin/env bash
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
grep -Fqx 'WORK_REGION=us-east-1' "$SNAPSHOT/dotfiles/custom/.home_weave_profile"
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
cat >"$provider" <<'EOF'
#!/usr/bin/env bash
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

# Best-effort providers warn for missing and failed items, continue planning
# later items, and leave strict/security validation unchanged.
best_effort_provider="$TEST_ROOT/best-effort-provider"
best_effort_log="$TEST_ROOT/best-effort-provider.log"
cat >"$best_effort_provider" <<'EOF'
#!/usr/bin/env bash
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
cat >"$TEST_ROOT/best-effort-bin/nix" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *lib.setup.profiles* ]]; then
  printf '%s\n' '{"work":{"extends":"development","primaryShell":"fish","providerPackages":{"optional":["missing","bad-plan","good"]},"nativePackages":{}}}'
else
  exit 1
fi
EOF
chmod +x "$TEST_ROOT/best-effort-bin/nix"
cp "$ROOT/setup.sh" "$TEST_ROOT/setup.sh.before-best-effort"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/setup.sh"
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
jq -e --arg platform "$snapshot_platform" '.profiles.base.platforms[$platform].packages.providers.fake == ["managed"]' \
  "$PROVIDER_SNAPSHOT/home-weave.json" >/dev/null
test -f "$PROVIDER_SNAPSHOT/metadata/provider-fake.json"

# Git is optional. Update must address the HomeWeave root as an explicit path
# flake so untracked or ignored files are not filtered by Nix's Git fetcher.
mkdir -p "$TEST_ROOT/update-bin"
cat >"$TEST_ROOT/update-bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UPDATE_NIX_LOG"
EOF
chmod +x "$TEST_ROOT/update-bin/nix"
export UPDATE_NIX_LOG="$TEST_ROOT/update-nix.log"
PATH="$TEST_ROOT/update-bin:$PATH" run_cli update >/dev/null
grep -Fq -- "--refresh flake update --flake path:$ROOT" "$UPDATE_NIX_LOG"

# Uninstall removes only the active Stow generation, restores missing adopted
# files, keeps the repository, and skips Home Manager without an apply marker.
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
uninstall_output="$(run_cli uninstall --yes)"
grep -Fq 'Retained provider-managed application: [fake] managed' <<<"$uninstall_output"
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
touch "$ROOT/.state/home-manager-pending"
pending_uninstall_output="$(run_cli uninstall --all --dry-run --yes)"
grep -Fq 'Home Manager will remove its managed packages' <<<"$pending_uninstall_output"
grep -Fq 'Would remove 2 dangling HomeWeave-owned link(s).' <<<"$pending_uninstall_output"
test -L "$TEST_HOME/.config/stale-absolute"
rm -f "$ROOT/.state/home-manager-pending"

# Generated runtime state is intentionally ignored by Git. Uninstall must use
# an explicit path flake so it remains visible when the HomeWeave root is a Git
# repository. A matching successful receipt is sufficient ownership evidence
# when an older activation omitted the applied marker.
mkdir -p "$ROOT/.state/generated" "$TEST_ROOT/uninstall-bin"
printf '{ outputs = _: { }; }\n' >"$ROOT/.state/generated/flake.nix"
owned_generation="$TEST_ROOT/home-manager-owned-generation"
mkdir -p "$owned_generation" "$TEST_HOME/.local/state/nix/profiles"
ln -sfn "$owned_generation" "$TEST_HOME/.local/state/nix/profiles/home-manager"
jq --arg generation "$owned_generation" \
  '.rollback.currentHomeManagerGeneration = $generation' \
  "$ROOT/.state/receipts/fixture.json" >"$ROOT/.state/receipts/fixture.json.tmp"
mv "$ROOT/.state/receipts/fixture.json.tmp" "$ROOT/.state/receipts/fixture.json"
cat >"$TEST_ROOT/uninstall-bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UNINSTALL_NIX_LOG"
EOF
chmod +x "$TEST_ROOT/uninstall-bin/nix"
export UNINSTALL_NIX_LOG="$TEST_ROOT/uninstall-nix.log"
receipt_uninstall_output="$(PATH="$TEST_ROOT/uninstall-bin:$PATH" run_cli uninstall --all --yes)"
grep -Fq 'recovering the missing uninstall marker' <<<"$receipt_uninstall_output"
grep -Fq "run path:$ROOT/.state/generated#home-manager -- uninstall" "$UNINSTALL_NIX_LOG"
test ! -e "$ROOT/.state/home-manager-pending"
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
other_generation="$TEST_ROOT/home-manager-other-generation"
mkdir -p "$other_generation"
ln -sfn "$other_generation" "$TEST_HOME/.local/state/nix/profiles/home-manager"
if run_cli uninstall --all --dry-run --yes 2>"$TEST_ROOT/generation-mismatch-error"; then
  printf 'expected a receipt generation mismatch to stop uninstall\n' >&2
  exit 1
fi
grep -Fq 'does not own the current Home Manager generation' "$TEST_ROOT/generation-mismatch-error"
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
