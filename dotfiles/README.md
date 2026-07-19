# Bundled default dotfiles

Portable shell, terminal, prompt, and editor configuration bundled with
HomeWeave and delivered through GNU Stow.

Each top-level directory is an independent Stow package. A typical installation
for Zsh is:

```sh
stow --dir="$HOME/.dotfiles" --target="$HOME" \
  --no-folding common starship zsh ghostty nvim
```

Use exactly one shell package: `bash`, `zsh`, `fish`, or `nushell`. The Nix
bootstrap script simulates Stow first and stops if an existing file would be
overwritten.

Credentials are never stored here. HomeWeave uses two shell-neutral files:

- `~/.home_weave_profile` is managed configuration for non-secret
  `NAME=VALUE` entries.
- `~/.home_weave_secrets` is an optional machine-local file for secrets that
  intentionally need to be inherited by every shell child process.

The secrets file is never supplied, adopted, backed up, or recorded by
HomeWeave. If used, it must be a regular, non-symlink file owned by the current
user with mode `0600`:

```sh
umask 077
touch ~/.home_weave_secrets
chmod 600 ~/.home_weave_secrets
```

Both files use strict `NAME=VALUE` syntax. A leading `export ` is accepted for
migration, but values are literal: command substitution and backticks are
rejected. Bash, Zsh, Fish, and Nushell receive native environment updates.
Prefer a secret manager for credentials that should only be exposed to one
command rather than every process started by the shell.

## Neovim

The `nvim` Stow package contains the complete public Neovim configuration.
Plugins are pinned by `lazy-lock.json`; review lock updates before publishing
them. Python, Java, language servers, formatters, linters, and debuggers are
resolved from the active Nix profile rather than hard-coded Homebrew, system,
or SDK-manager paths. Neovim does not run global npm, Homebrew, Pacman, or sudo
installation commands.

Keep database connections outside this repository under
`~/.connections/db/connections.toml`. Keep MCP credentials in local MCP
configuration or an approved secret manager.

## Downstream personal and work layers

Keep machine- or organization-specific configuration in a separate Git
repository. Stow the base first and the downstream package second:

```sh
stow --dir="$HOME/.dotfiles" --target="$HOME" --no-folding \
  common starship zsh ghostty nvim
stow --dir="$HOME/.work-dotfiles" --target="$HOME" --no-folding work
```

The downstream `work` package can add files without replacing base-owned
files. Supported extension locations include:

- `.config/shell/conf.d/*.sh` for portable Bash/Zsh additions
- `.config/bash/conf.d/*.sh` and `.config/zsh/conf.d/*.zsh`
- `.config/fish/conf.d/*.fish`
- Nushell's standard `.config/nushell/vendor/autoload/*.nu`
- tool-specific files composed by the profile framework

For example, the private repository can contain
`work/.config/shell/conf.d/work.sh`. Keep credentials out of both repositories;
extension files may add non-secret values to `.home_weave_profile` or reference
local credential stores without committing their values. Never add
`.home_weave_secrets` to a dotfile layer.

The `nvim` package owns the canonical public configuration at
`~/.config/nvim`. The Nix profile framework can merge or replace that subtree
with a later private component while retaining the public shell, Starship, and
Ghostty files.
