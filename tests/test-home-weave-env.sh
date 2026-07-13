#!/usr/bin/env bash
set -Eeuo pipefail

loader="${1:?home-weave-env script is required}"
dotfiles="${2:?base dotfiles are required}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/profile" <<'EOF'
# non-secret values
EDITOR=nvim
export VALUE_WITH_SPACES=hello world
LITERAL_DOLLAR=$HOME
EOF
cat >"$tmp/.home_weave_secrets" <<'EOF'
OPEN_AI_API_KEY=test-only-value
EOF
chmod 0600 "$tmp/.home_weave_secrets"

posix_output="$(bash "$loader" render posix "$tmp/profile" "$tmp/.home_weave_secrets")"
bash -c "$posix_output; [[ \"\$EDITOR\" == nvim ]]; [[ \"\$VALUE_WITH_SPACES\" == 'hello world' ]]; [[ \"\$LITERAL_DOLLAR\" == '\$HOME' ]]; [[ \"\$OPEN_AI_API_KEY\" == test-only-value ]]"
zsh -c "$posix_output; [[ \"\$VALUE_WITH_SPACES\" == 'hello world' ]]"

fish_output="$(bash "$loader" render fish "$tmp/profile" "$tmp/.home_weave_secrets")"
fish --no-config -c "$fish_output; test \"\$VALUE_WITH_SPACES\" = 'hello world'; and test \"\$LITERAL_DOLLAR\" = '\$HOME'"

bash "$loader" render json "$tmp/profile" "$tmp/.home_weave_secrets" \
  | jq -e '.EDITOR == "nvim" and .OPEN_AI_API_KEY == "test-only-value" and .LITERAL_DOLLAR == "$HOME"' >/dev/null

chmod 0644 "$tmp/.home_weave_secrets"
if bash "$loader" render json "$tmp/.home_weave_secrets" >/dev/null 2>&1; then
  printf 'expected insecure secrets permissions to fail\n' >&2
  exit 1
fi
chmod 0600 "$tmp/.home_weave_secrets"
mv "$tmp/.home_weave_secrets" "$tmp/secret-source"
ln -s "$tmp/secret-source" "$tmp/.home_weave_secrets"
if bash "$loader" render json "$tmp/.home_weave_secrets" >/dev/null 2>&1; then
  printf 'expected a secrets symlink to fail\n' >&2
  exit 1
fi
rm "$tmp/.home_weave_secrets"

for unsafe in 'BAD=$(id)' 'BAD=`id`' 'BAD-NAME=value'; do
  printf '%s\n' "$unsafe" >"$tmp/unsafe"
  if bash "$loader" render json "$tmp/unsafe" >/dev/null 2>&1; then
    printf 'expected unsafe environment entry to fail: %s\n' "$unsafe" >&2
    exit 1
  fi
done

bash "$loader" render json "$tmp/missing" | jq -e '. == {}' >/dev/null
bash -n "$dotfiles/common/.config/shell/common.sh"
zsh -n "$dotfiles/common/.config/shell/common.sh"
fish --no-config -n "$dotfiles/fish/.config/fish/config.fish"
HOME="$tmp" nu --no-config-file \
  "$dotfiles/nushell/.config/nushell/vendor/autoload/home-weave-env.nu"

printf 'Canonical HomeWeave environment and shell-loader tests passed.\n'
