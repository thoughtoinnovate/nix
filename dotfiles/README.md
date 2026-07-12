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

Credentials are never stored here. Keep machine-local secrets in
`~/.secrets`, tool-specific credential stores, or an organization-approved
secret manager. Shell startup files deliberately do not load `~/.secrets`
automatically.

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
the extension files may reference local credential stores without committing
their values.

The `nvim` package owns the canonical public configuration at
`~/.config/nvim`. The Nix profile framework can merge or replace that subtree
with a later private component while retaining the public shell, Starship, and
Ghostty files.
