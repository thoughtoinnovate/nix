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

for command in jq realpath rsync stow; do
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
    (.source | type == "object") and
    (.source.kind == "nix" or .source.kind == "path") and
    (.source.path | type == "string" and length > 0) and
    (.packages | type == "array" and length > 0) and
    (has("entries") | not)
  )
' >/dev/null <<<"$dotfiles_json" || fail "invalid dotfile component schema"

data_root="${HOME_WEAVE_DATA_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$NAMESPACE}"
stow_root="$data_root/dotfiles"
current_dir="$stow_root/current"
temp_dir="$stow_root/.current.new.$$"
backup_dir="$stow_root/.current.previous.$$"
transaction_started=false
stale_links_file="$stow_root/.stale-links.$$"

cleanup() {
  rm -rf "$temp_dir"
  rm -f "$stale_links_file"
  if [[ -d "$backup_dir" && "$transaction_started" == false ]]; then
    rm -rf "$backup_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$temp_dir"
: >"$stale_links_file"

validate_relative_path() {
  local path="$1" label="$2"
  [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* ]] \
    || fail "$label must be a relative path: $path"
  [[ "$path" == "." || ( "$path" != */. && "$path" != ./* && "$path" != *//* \
    && "/$path/" != *"/../"* && "/$path/" != *"/./"* ) ]] \
    || fail "$label may not contain traversal or empty segments: $path"
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

apply_package() {
  local component_source="$1" component_name="$2" package="$3"
  local source_dir
  [[ "$package" == "@shell" ]] && package="$SELECTED_SHELL"
  if [[ "$package" == "@shells" ]]; then
    while IFS= read -r selected_shell; do
      apply_package "$component_source" "$component_name" "$selected_shell"
    done < <(tr ',' '\n' <<<"$SELECTED_SHELLS")
    return
  fi
  validate_relative_path "$package" "layer '$component_name' package"
  [[ "$package" != "." ]] || fail "layer '$component_name' package must be a named Stow component"
  source_dir="$component_source/$package"
  [[ -e "$source_dir" || -L "$source_dir" ]] \
    || fail "layer '$component_name' package is missing: $package"

  if [[ -d "$source_dir" && ! -L "$source_dir" ]]; then
    check_merge_conflicts "$source_dir" "$temp_dir"
    rsync --archive --no-perms --no-owner --no-group \
      --exclude='.git/' --exclude='.gitkeep' --exclude='.DS_Store' \
      "$source_dir/" "$temp_dir/" \
      || fail "could not apply Stow package '$component_name:$package'"
    find "$temp_dir" -type d -exec chmod u+rwx {} +
    find "$temp_dir" -type f -exec chmod u+rw {} +
  else
    fail "layer '$component_name' package must be a directory: $package"
  fi
}

seen_layers="|"
while IFS= read -r layer; do
  layer_name="$(jq -r '.name' <<<"$layer")"
  [[ "$layer_name" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "unsafe dotfile layer name: $layer_name"
  [[ "$seen_layers" != *"|$layer_name|"* ]] || fail "duplicate dotfile layer name: $layer_name"
  seen_layers+="$layer_name|"

  source_dir="$(jq -r '.source.path' <<<"$layer")"
  [[ -d "$source_dir" ]] || fail "dotfile layer '$layer_name' source is missing: $source_dir"

  while IFS= read -r package; do
    apply_package "$source_dir" "$layer_name" "$package"
  done < <(jq -r '.packages[]' <<<"$layer")
done < <(jq -c '.layers[]' <<<"$dotfiles_json")

normalize_absolute_path() {
  local path="$1" segment normalized=""
  local parts=()
  [[ "$path" == /* ]] || return 1
  while IFS= read -r segment; do
    case "$segment" in
      ""|.) ;;
      ..)
        ((${#parts[@]} > 0)) || return 1
        parts=("${parts[@]:0:${#parts[@]}-1}")
        ;;
      *) parts+=("$segment") ;;
    esac
  done < <(tr '/' '\n' <<<"$path")
  for segment in "${parts[@]}"; do
    normalized="$normalized/$segment"
  done
  printf '%s\n' "${normalized:-/}"
}

is_current_link() {
  local destination="$1" relative="$2" raw candidate expected
  [[ -L "$destination" ]] || return 1
  raw="$(readlink "$destination")" || return 1
  if [[ "$raw" == /* ]]; then
    candidate="$raw"
  else
    candidate="$(dirname "$destination")/$raw"
  fi
  candidate="$(normalize_absolute_path "$candidate")" || return 1
  expected="$(normalize_absolute_path "$current_dir/$relative")" || return 1
  [[ "$candidate" == "$expected" ]] || return 1

  # A link into the exact expected generation is HomeWeave-owned even when a
  # previous root deletion left it dangling. Preserve its raw value so a
  # failed Stow transaction can restore the pre-operation state byte-for-byte.
  if [[ ! -e "$destination" ]]; then
    [[ "$destination" != *$'\t'* && "$destination" != *$'\n'* \
      && "$raw" != *$'\t'* && "$raw" != *$'\n'* ]] || return 1
    printf '%s\t%s\n' "$destination" "$raw" >>"$stale_links_file"
  fi
  return 0
}

restore_stale_managed_links() {
  local destination raw
  while IFS=$'\t' read -r destination raw; do
    [[ -n "$destination" ]] || continue
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
      mkdir -p "$(dirname "$destination")"
      ln -s "$raw" "$destination"
    elif [[ -L "$destination" && "$(readlink "$destination")" == "$raw" ]]; then
      :
    else
      printf 'warning: stale managed link changed during rollback: %s\n' "$destination" >&2
    fi
  done <"$stale_links_file"
}

remove_stale_managed_links() {
  local destination raw
  while IFS=$'\t' read -r destination raw; do
    [[ -n "$destination" ]] || continue
    [[ -L "$destination" ]] || continue
    rm "$destination"
  done <"$stale_links_file"
}

preflight_destinations() {
  local staged relative destination

  while IFS= read -r -d '' staged; do
    relative="${staged#"$temp_dir"/}"
    destination="$HOME/$relative"
    if [[ -e "$destination" || -L "$destination" ]]; then
      if is_current_link "$destination" "$relative"; then
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
      is_current_link "$destination" "$relative" || fail "destination conflict at $destination"
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
remove_stale_managed_links
mv "$temp_dir" "$current_dir"

stow_preflight_output="$(mktemp)"
if stow --simulate --restow --no-folding --dir="$stow_root" --target="$HOME" current \
  >"$stow_preflight_output" 2>&1 \
  && stow --restow --no-folding --dir="$stow_root" --target="$HOME" current; then
  rm -f "$stow_preflight_output"
  rm -rf "$backup_dir"
  transaction_started=false
else
  cat "$stow_preflight_output" >&2
  rm -f "$stow_preflight_output"
  stow --delete --no-folding --dir="$stow_root" --target="$HOME" current >/dev/null 2>&1 || true
  rm -rf "$current_dir"
  if [[ -d "$backup_dir" ]]; then
    mv "$backup_dir" "$current_dir"
    stow --restow --no-folding --dir="$stow_root" --target="$HOME" current \
      || printf 'warning: automatic dotfile rollback could not restore links\n' >&2
  fi
  restore_stale_managed_links
  transaction_started=false
  fail "Stow could not link the new generation; the previous generation was restored"
fi

printf '  Dotfiles: composed profile at %s\n' "$current_dir"
