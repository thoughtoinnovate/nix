#!/usr/bin/env bash

set -Eeuo pipefail

SELECTED_SHELL=""
SELECTED_SHELLS=""
DOTFILES_JSON_FILE=""
NAMESPACE="${HOME_WEAVE_NAMESPACE:-home-weave}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: compose-dotfiles.sh --shell bash|zsh|fish|nushell [--shells CSV] [--namespace NAME] [--json FILE]

Reads lib.setup.dotfiles JSON from standard input unless --json is supplied.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      [[ $# -ge 2 ]] || fail "--shell requires a value"
      SELECTED_SHELL="$2"
      shift 2
      ;;
    --shells)
      [[ $# -ge 2 ]] || fail "--shells requires a comma-separated value"
      SELECTED_SHELLS="$2"
      shift 2
      ;;
    --json)
      [[ $# -ge 2 ]] || fail "--json requires a file"
      DOTFILES_JSON_FILE="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || fail "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

case "$SELECTED_SHELL" in
  bash|zsh|fish|nushell) ;;
  *) fail "unsupported shell: $SELECTED_SHELL" ;;
esac
SELECTED_SHELLS="${SELECTED_SHELLS:-$SELECTED_SHELL}"
while IFS= read -r selected_shell; do
  case "$selected_shell" in bash|zsh|fish|nushell) ;; *) fail "unsupported shell: $selected_shell" ;; esac
done < <(tr ',' '\n' <<<"$SELECTED_SHELLS")
[[ "$NAMESPACE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$NAMESPACE" != "." && "$NAMESPACE" != ".." ]] \
  || fail "unsafe namespace: $NAMESPACE"

for command in git jq realpath rsync stow; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required to compose dotfiles"
done

if [[ -n "$DOTFILES_JSON_FILE" ]]; then
  [[ -f "$DOTFILES_JSON_FILE" ]] || fail "dotfiles JSON is missing: $DOTFILES_JSON_FILE"
  dotfiles_json="$(<"$DOTFILES_JSON_FILE")"
else
  dotfiles_json="$(cat)"
fi

jq -e '
  type == "object" and
  (.layers | type == "array" and length > 0) and
  all(.layers[];
    type == "object" and
    (.name | type == "string" and length > 0) and
    ((.source | type == "string" and length > 0) or
      (.source | type == "object" and (.kind | type == "string"))) and
    (((.entries? | type) == "array" and (.entries | length > 0)) or
      ((.packages? | type) == "array" and (.packages | length > 0)))
  )
' >/dev/null <<<"$dotfiles_json" || fail "invalid dotfile component schema"

data_root="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}"
stow_root="$data_root/dotfiles"
sources_root="$data_root/sources"
current_dir="$stow_root/current"
temp_dir="$stow_root/.current.new.$$"
backup_dir="$stow_root/.current.previous.$$"
transaction_started=false

cleanup() {
  rm -rf "$temp_dir"
  if [[ -d "$backup_dir" && "$transaction_started" == false ]]; then
    rm -rf "$backup_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$temp_dir" "$sources_root"

validate_relative_path() {
  local path="$1" label="$2"
  [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* ]] \
    || fail "$label must be a relative path: $path"
  [[ "$path" == "." || ( "$path" != */. && "$path" != ./* && "$path" != *//* \
    && "/$path/" != *"/../"* && "/$path/" != *"/./"* ) ]] \
    || fail "$label may not contain traversal or empty segments: $path"
}

normalize_repository() {
  local repository="$1"
  repository="${repository%/}"
  repository="${repository%.git}"
  printf '%s' "$repository"
}

resolve_git_source() {
  local name="$1" url="$2" commit="$3" checkout origin

  [[ -n "$url" && "$url" != *$'\n'* ]] || fail "invalid Git URL for layer '$name'"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "layer '$name' requires a full lowercase Git commit SHA"
  checkout="$sources_root/$name"

  if [[ -e "$checkout" ]]; then
    [[ -d "$checkout/.git" ]] || fail "$checkout exists but is not a Git checkout"
    [[ -z "$(git -C "$checkout" status --porcelain --untracked-files=normal)" ]] \
      || fail "$checkout has local changes; commit or move them before setup"
    origin="$(git -C "$checkout" remote get-url origin)" || fail "$checkout has no origin"
    [[ "$(normalize_repository "$origin")" == "$(normalize_repository "$url")" ]] \
      || fail "$checkout origin does not match $url"
  else
    if ! git clone --quiet --no-checkout "$url" "$checkout"; then
      rm -rf "$checkout"
      fail "could not clone Git layer '$name'; verify repository access and authentication"
    fi
  fi

  git -C "$checkout" fetch --quiet origin "$commit" \
    || fail "could not fetch commit $commit for layer '$name'"
  git -C "$checkout" cat-file -e "$commit^{commit}" \
    || fail "layer '$name' revision is not a Git commit: $commit"
  git -C "$checkout" checkout --quiet --detach "$commit" \
    || fail "could not check out commit $commit for layer '$name'"
  [[ "$(git -C "$checkout" rev-parse HEAD)" == "$commit" ]] \
    || fail "layer '$name' did not resolve to the declared commit"
  printf '%s' "$checkout"
}

check_merge_conflicts() {
  local source="$1" destination="$2" relative existing

  while IFS= read -r -d '' source_path; do
    relative="${source_path#"$source"/}"
    existing="$destination/$relative"
    if [[ -e "$existing" || -L "$existing" ]]; then
      [[ -d "$existing" && ! -L "$existing" ]] \
        || fail "file/directory conflict while merging '$relative'"
    fi
  done < <(find "$source" -mindepth 1 -type d -print0)

  while IFS= read -r -d '' source_path; do
    relative="${source_path#"$source"/}"
    existing="$destination/$relative"
    [[ ! -d "$existing" || -L "$existing" ]] \
      || fail "file/directory conflict while merging '$relative'"
  done < <(find "$source" -mindepth 1 \( -type f -o -type l \) -print0)
}

apply_entry() {
  local component_source="$1" component_name="$2" component_entry="$3"
  local from target mode source_dir target_dir

  jq -e '
    type == "object" and
    (.from | type == "string" and length > 0) and
    (.to | type == "string" and length > 0) and
    (.mode == "merge" or .mode == "replace")
  ' >/dev/null <<<"$component_entry" \
    || fail "layer '$component_name' contains an invalid entry"

  from="$(jq -r '.from' <<<"$component_entry")"
  target="$(jq -r '.to' <<<"$component_entry")"
  mode="$(jq -r '.mode' <<<"$component_entry")"
  [[ "$from" == "@shell" ]] && from="$SELECTED_SHELL"
  if [[ "$from" == "@shells" ]]; then
    while IFS= read -r selected_shell; do
      apply_entry "$component_source" "$component_name" \
        "$(jq -c --arg from "$selected_shell" '.from = $from' <<<"$component_entry")"
    done < <(tr ',' '\n' <<<"$SELECTED_SHELLS")
    return
  fi
  validate_relative_path "$from" "layer '$component_name' source path"
  validate_relative_path "$target" "layer '$component_name' target path"
  [[ "$mode" != "replace" || "$target" != "." ]] \
    || fail "layer '$component_name' may not replace the generated root"

  source_dir="$component_source/$from"
  target_dir="$temp_dir/$target"
  [[ -e "$source_dir" || -L "$source_dir" ]] \
    || fail "layer '$component_name' source is missing: $from"

  if [[ "$mode" == "replace" ]]; then
    rm -rf "$target_dir"
  fi

  if [[ -d "$source_dir" && ! -L "$source_dir" ]]; then
    mkdir -p "$target_dir"
    check_merge_conflicts "$source_dir" "$target_dir"
    rsync --archive --no-perms --no-owner --no-group \
      --exclude='.git/' --exclude='.gitkeep' --exclude='.DS_Store' \
      "$source_dir/" "$target_dir/" \
      || fail "could not apply '$component_name:$from' to '$target'"
    find "$temp_dir" -type d -exec chmod u+rwx {} +
    find "$temp_dir" -type f -exec chmod u+rw {} +
  else
    mkdir -p "$(dirname "$target_dir")"
    [[ ! -d "$target_dir" || -L "$target_dir" ]] \
      || fail "file/directory conflict at '$target'"
    cp -a "$source_dir" "$target_dir"
  fi
}

seen_layers="|"
while IFS= read -r layer; do
  layer_name="$(jq -r '.name' <<<"$layer")"
  [[ "$layer_name" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "unsafe dotfile layer name: $layer_name"
  [[ "$seen_layers" != *"|$layer_name|"* ]] || fail "duplicate dotfile layer name: $layer_name"
  seen_layers+="$layer_name|"

  if jq -e '.source | type == "string"' >/dev/null <<<"$layer"; then
    source_dir="$(jq -r '.source' <<<"$layer")"
  else
    source_kind="$(jq -r '.source.kind' <<<"$layer")"
    case "$source_kind" in
      nix|path)
        source_dir="$(jq -r '.source.path // empty' <<<"$layer")"
        [[ -n "$source_dir" ]] || fail "layer '$layer_name' requires source.path"
        ;;
      git)
        repository="$(jq -r '.source.url // empty' <<<"$layer")"
        rev="$(jq -r '.source.rev // empty' <<<"$layer")"
        source_dir="$(resolve_git_source "$layer_name" "$repository" "$rev")"
        ;;
      *) fail "layer '$layer_name' has unsupported source kind '$source_kind'" ;;
    esac
  fi
  [[ -d "$source_dir" ]] || fail "dotfile layer '$layer_name' source is missing: $source_dir"

  if jq -e '(.entries? | type) == "array"' >/dev/null <<<"$layer"; then
    while IFS= read -r entry; do
      apply_entry "$source_dir" "$layer_name" "$entry"
    done < <(jq -c '.entries[]' <<<"$layer")
  else
    while IFS= read -r package; do
      [[ "$package" == "@shell" ]] && package="$SELECTED_SHELL"
      validate_relative_path "$package" "layer '$layer_name' package"
      apply_entry "$source_dir" "$layer_name" \
        "$(jq -cn --arg from "$package" '{from: $from, to: ".", mode: "merge"}')"
    done < <(jq -r '.packages[]' <<<"$layer")
  fi
done < <(jq -c '.layers[]' <<<"$dotfiles_json")

is_current_link() {
  local destination="$1" resolved current_resolved
  [[ -L "$destination" && -d "$current_dir" ]] || return 1
  resolved="$(realpath "$destination")" || return 1
  current_resolved="$(realpath "$current_dir")" || return 1
  [[ "$resolved" == "$current_resolved"/* ]]
}

preflight_destinations() {
  local staged relative destination

  while IFS= read -r -d '' staged; do
    relative="${staged#"$temp_dir"/}"
    destination="$HOME/$relative"
    if [[ -e "$destination" || -L "$destination" ]]; then
      if is_current_link "$destination"; then
        continue
      fi
      [[ -d "$destination" && ! -L "$destination" ]] \
        || fail "destination conflict at $destination"
    fi
  done < <(find "$temp_dir" -mindepth 1 -type d -print0)

  while IFS= read -r -d '' staged; do
    relative="${staged#"$temp_dir"/}"
    destination="$HOME/$relative"
    if [[ -e "$destination" || -L "$destination" ]]; then
      is_current_link "$destination" || fail "destination conflict at $destination"
    fi
  done < <(find "$temp_dir" -mindepth 1 \( -type f -o -type l \) -print0)
}

preflight_destinations

if [[ -d "$current_dir" ]]; then
  stow --delete --no-folding --dir="$stow_root" --target="$HOME" current \
    || fail "could not unlink the active dotfile generation"
  mv "$current_dir" "$backup_dir"
fi

transaction_started=true
mv "$temp_dir" "$current_dir"

if stow --simulate --restow --no-folding --dir="$stow_root" --target="$HOME" current \
  && stow --restow --no-folding --dir="$stow_root" --target="$HOME" current; then
  rm -rf "$backup_dir"
  transaction_started=false
else
  stow --delete --no-folding --dir="$stow_root" --target="$HOME" current >/dev/null 2>&1 || true
  rm -rf "$current_dir"
  if [[ -d "$backup_dir" ]]; then
    mv "$backup_dir" "$current_dir"
    stow --restow --no-folding --dir="$stow_root" --target="$HOME" current \
      || printf 'warning: automatic dotfile rollback could not restore links\n' >&2
  fi
  transaction_started=false
  fail "Stow could not link the new generation; the previous generation was restored"
fi

printf '  Dotfiles: composed profile at %s\n' "$current_dir"
