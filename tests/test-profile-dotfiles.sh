#!/usr/bin/env bash

set -Eeuo pipefail

BASE_DOTFILES="${1:?usage: test-profile-dotfiles.sh BASE_DOTFILES [COMPOSER]}"
COMPOSER="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/compose-dotfiles.sh}"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
TEST_DATA="$TEST_ROOT/data"
JSON_FILE="$TEST_ROOT/layers.json"
WORK="$TEST_ROOT/work"
WORK_GIT="$TEST_ROOT/work-git"
PRIVATE_NVIM="$TEST_ROOT/private-nvim"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$WORK/custom/.config/shell/conf.d" "$WORK_GIT" "$PRIVATE_NVIM"
printf 'export PROFILE_LAYER=true\n' >"$WORK/custom/.config/shell/conf.d/profile.sh"
printf '# work zsh override\n' >"$WORK/custom/.zshrc"
touch "$WORK/custom/.gitkeep"
printf 'work git setting\n' >"$WORK_GIT/work.conf"
printf 'vim.g.private_work_nvim = true\n' >"$PRIVATE_NVIM/init.lua"

make_git_repo() {
  local repository="$1"
  git -C "$repository" init --quiet
  git -C "$repository" add .
  git -C "$repository" -c user.name=Test -c user.email=test@example.invalid \
    commit --quiet -m "test component"
  git -C "$repository" rev-parse HEAD
}

work_rev="$(make_git_repo "$WORK_GIT")"
nvim_rev="$(make_git_repo "$PRIVATE_NVIM")"

run_composer() {
  HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" \
    bash "$COMPOSER" --shell "${1:-zsh}" --json "$JSON_FILE"
}

expect_failure() {
  local expected="$1"
  shift
  if output="$("$@" 2>&1)"; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  grep -Eq "$expected" <<<"$output" || {
    printf 'failure did not contain %q:\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

write_public_json() {
  jq -n \
    --arg base "$BASE_DOTFILES" \
    '{layers: [
      {
        name: "base",
        source: {kind: "path", path: $base},
        entries: ["common", "starship", "@shell", "ghostty", "nvim"]
          | map({from: ., to: ".", mode: "merge"})
      }
    ]}' >"$JSON_FILE"
}

# Public base and its Neovim Stow package work for every supported shell.
for shell in bash zsh fish nushell; do
  write_public_json
  run_composer "$shell"
done
[[ -L "$TEST_HOME/.config/nvim/init.lua" ]]
[[ -L "$TEST_HOME/.config/starship.toml" ]]
[[ -L "$TEST_HOME/.config/ghostty/config" ]]
[[ -L "$TEST_HOME/.config/nushell/config.nu" ]]
[[ ! -e "$TEST_HOME/.zshrc" ]]

# Aggregate work settings and multiple exact-commit Git components merge in order.
jq -n \
  --arg base "$BASE_DOTFILES" \
  --arg work "$WORK" \
  --arg work_git "file://$WORK_GIT" \
  --arg work_rev "$work_rev" \
  '{layers: [
    {name: "base", source: {kind: "path", path: $base}, entries:
      (["common", "starship", "@shell", "ghostty", "nvim"] | map({from: ., to: ".", mode: "merge"}))},
    {name: "work", source: {kind: "path", path: $work}, entries:
      [{from: "custom", to: ".", mode: "merge"}]},
    {name: "work-one", source: {kind: "git", url: $work_git, rev: $work_rev}, entries:
      [{from: "work.conf", to: ".config/company/work.conf", mode: "merge"}]},
    {name: "work-two", source: {kind: "git", url: $work_git, rev: $work_rev}, entries:
      [{from: "work.conf", to: ".config/company/second.conf", mode: "merge"}]}
  ]}' >"$JSON_FILE"
run_composer zsh
grep -Fq 'work zsh override' "$TEST_HOME/.zshrc"
grep -Fq 'PROFILE_LAYER' "$TEST_HOME/.config/shell/conf.d/profile.sh"
[[ ! -e "$TEST_HOME/.gitkeep" ]]
[[ ! -e "$TEST_DATA/thoughtoinnovate/dotfiles/current/.gitkeep" ]]
grep -Fq 'work git setting' "$TEST_HOME/.config/company/work.conf"
[[ "$(git -C "$TEST_DATA/thoughtoinnovate/sources/work-one" rev-parse HEAD)" == "$work_rev" ]]
[[ "$(git -C "$TEST_DATA/thoughtoinnovate/sources/work-one" symbolic-ref -q HEAD || true)" == "" ]]

# A partial Neovim merge preserves public files and overrides matches.
mkdir -p "$WORK/partial-nvim/lua"
printf 'vim.g.partial_work_nvim = true\n' >"$WORK/partial-nvim/init.lua"
printf 'return true\n' >"$WORK/partial-nvim/lua/work.lua"
jq --arg work "$WORK" '.layers += [{
  name: "partial-nvim",
  source: {kind: "path", path: $work},
  entries: [{from: "partial-nvim", to: ".config/nvim", mode: "merge"}]
}]' "$JSON_FILE" >"$JSON_FILE.tmp"
mv "$JSON_FILE.tmp" "$JSON_FILE"
run_composer zsh
[[ -e "$TEST_HOME/.config/nvim/lazy-lock.json" ]]
grep -Fq 'partial_work_nvim' "$TEST_HOME/.config/nvim/init.lua"
[[ -e "$TEST_HOME/.config/nvim/lua/work.lua" ]]

# A private Neovim replace removes the complete public subtree only.
jq --arg url "file://$PRIVATE_NVIM" --arg rev "$nvim_rev" '.layers += [{
  name: "work-nvim",
  source: {kind: "git", url: $url, rev: $rev},
  entries: [{from: ".", to: ".config/nvim", mode: "replace"}]
}]' "$JSON_FILE" >"$JSON_FILE.tmp"
mv "$JSON_FILE.tmp" "$JSON_FILE"
run_composer zsh
[[ ! -e "$TEST_HOME/.config/nvim/lazy-lock.json" ]]
[[ ! -e "$TEST_HOME/.config/nvim/lua/work.lua" ]]
grep -Fq 'private_work_nvim' "$TEST_HOME/.config/nvim/init.lua"
[[ -e "$TEST_HOME/.config/starship.toml" ]]

# Removing layers removes their stale managed links.
write_public_json
run_composer zsh
[[ ! -e "$TEST_HOME/.config/company/work.conf" ]]
[[ ! -e "$TEST_HOME/.config/shell/conf.d/profile.sh" ]]
[[ -e "$TEST_HOME/.config/nvim/lazy-lock.json" ]]

# Invalid paths, root replacement, absent sources, hashes, and type conflicts fail early.
cp "$JSON_FILE" "$TEST_ROOT/valid.json"
for path in ../escape a/../escape /absolute ./relative a//b; do
  jq --arg path "$path" '.layers[0].entries[0].to = $path' "$TEST_ROOT/valid.json" >"$JSON_FILE"
  expect_failure "may not contain traversal|must be a relative" run_composer zsh
done
jq '.layers[0].entries[0] = {from: "common", to: ".", mode: "replace"}' \
  "$TEST_ROOT/valid.json" >"$JSON_FILE"
expect_failure "may not replace the generated root" run_composer zsh
jq '.layers[0].entries[0].from = "missing"' "$TEST_ROOT/valid.json" >"$JSON_FILE"
expect_failure "source is missing" run_composer zsh
jq '.layers += [{name: "bad-rev", source: {kind: "git", url: "file:///missing", rev: "abc"}, entries: [{from: ".", to: ".x", mode: "merge"}]}]' \
  "$TEST_ROOT/valid.json" >"$JSON_FILE"
expect_failure "full lowercase Git commit SHA" run_composer zsh

mkdir -p "$WORK/type-dir"
printf 'file\n' >"$WORK/type-dir/collision"
mkdir -p "$WORK/type-file"
mkdir -p "$WORK/type-file/collision"
jq -n --arg work "$WORK" '{layers: [
  {name: "file", source: {kind: "path", path: $work}, entries: [{from: "type-dir", to: ".", mode: "merge"}]},
  {name: "dir", source: {kind: "path", path: $work}, entries: [{from: "type-file", to: ".", mode: "merge"}]}
]}' >"$JSON_FILE"
expect_failure "file/directory conflict" run_composer zsh

# Existing destinations are rejected before the active generation is unlinked.
write_public_json
run_composer zsh
old_target="$(readlink "$TEST_HOME/.zshrc")"
printf 'unmanaged\n' >"$TEST_HOME/.config/new-conflict"
jq --arg work "$WORK" '.layers += [{name: "conflict", source: {kind: "path", path: $work}, entries: [{from: "custom/.zshrc", to: ".config/new-conflict", mode: "merge"}]}]' \
  "$JSON_FILE" >"$JSON_FILE.tmp"
mv "$JSON_FILE.tmp" "$JSON_FILE"
expect_failure "destination conflict" run_composer zsh
[[ "$(readlink "$TEST_HOME/.zshrc")" == "$old_target" ]]
rm "$TEST_HOME/.config/new-conflict"

# Cached private repositories reject wrong origins and dirty worktrees.
jq -n --arg url "file://$WORK_GIT" --arg rev "$work_rev" '{layers: [{
  name: "work-one", source: {kind: "git", url: $url, rev: $rev},
  entries: [{from: "work.conf", to: ".config/work.conf", mode: "merge"}]
}]}' >"$JSON_FILE"
git -C "$TEST_DATA/thoughtoinnovate/sources/work-one" remote set-url origin file:///wrong-origin
expect_failure "origin does not match" run_composer zsh
git -C "$TEST_DATA/thoughtoinnovate/sources/work-one" remote set-url origin "file://$WORK_GIT"
printf 'dirty\n' >"$TEST_DATA/thoughtoinnovate/sources/work-one/dirty"
expect_failure "has local changes" run_composer zsh
rm "$TEST_DATA/thoughtoinnovate/sources/work-one/dirty"

# Authentication/clone failure is actionable and leaves the current generation intact.
jq '.layers[0].name = "unavailable" | .layers[0].source.url = "file:///repository-that-does-not-exist"' \
  "$JSON_FILE" >"$JSON_FILE.tmp"
mv "$JSON_FILE.tmp" "$JSON_FILE"
expect_failure "verify repository access and authentication" run_composer zsh
[[ "$(readlink "$TEST_HOME/.zshrc")" == "$old_target" ]]

# A link-time failure restores the prior generation.
write_public_json
run_composer zsh
old_target="$(readlink "$TEST_HOME/.zshrc")"
real_stow="$(command -v stow)"
mkdir -p "$TEST_ROOT/fake-bin"
sed "s|@REAL_STOW@|$real_stow|" >"$TEST_ROOT/fake-bin/stow" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == "--simulate" ]]; then
    exit 1
  fi
done
exec @REAL_STOW@ "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/stow"
if HOME="$TEST_HOME" XDG_DATA_HOME="$TEST_DATA" PATH="$TEST_ROOT/fake-bin:$PATH" \
  bash "$COMPOSER" --shell zsh --json "$JSON_FILE" >/dev/null 2>&1; then
  printf 'expected injected Stow failure\n' >&2
  exit 1
fi
[[ "$(readlink "$TEST_HOME/.zshrc")" == "$old_target" ]]
[[ -e "$TEST_HOME/.config/nvim/lazy-lock.json" ]]

printf 'Profile component, Git, conflict, stale-link, and rollback tests passed.\n'
