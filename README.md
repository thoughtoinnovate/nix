# thoughtoinnovate/nix

Reusable Nix overlays and Home Manager modules for a consistent terminal and
development environment on Linux and macOS.

Supported systems are `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
Current Nixpkgs unstable no longer supports Intel macOS.

This repository is the public base layer. Personal and organization-specific
repositories should consume it as a flake input and add their own overlays or
modules. Credentials and proprietary source code do not belong here.

## Profiles

- `base`: Bash, Fish, Zsh, Nushell, Git, Neovim, Starship, curl, wget, Stow,
  FiraCode Nerd Font, Java 21, Ghostty on Linux, and Neovim essentials including
  ripgrep, fd, Node.js, Python, unzip, make, and Clang. Java uses Amazon
  Corretto on Linux and OpenJDK on macOS.
- `development`: everything in `base`, plus Gradle, kubectl, minikube,
  lazygit, VS Code, Java 11/17/21 development shells, Go, Rust, common language
  servers, Google Java Format, Jupyter, and ImageMagick.
- `darwin`: nix-darwin integration and optional Homebrew installation of the
  Ghostty macOS application.

Ghostty is installed from Nixpkgs on Linux. On macOS, the bootstrap uses the
official Homebrew cask when Homebrew is available; the nix-darwin module can
manage the same cask declaratively. Default configuration comes from the
sanitized dotfile template bundled in this repository.

## Test the base

```sh
nix flake show
nix flake check
nix develop .#java21
```

Development shells never modify dotfiles, change the login shell, or launch a
different interactive shell automatically.

## Bootstrap a machine

Clone the repository and run the installer interactively:

```sh
./install.sh
```

Interactive setup optionally creates a personal profile repository. It asks
for a local profile directory and an optional GitHub or GitLab SSH remote, then
generates an overrides-only `dotfiles/custom` tree. It initializes Git locally
but never commits, pushes, or stores provider credentials. The generated Stow
directory is internal and is not a user-facing choice.

Or make the choices explicit:

```sh
./install.sh --shell fish --profile development
./install.sh --shell zsh --profile base
```

The installer:

1. Detects Linux versus Apple Silicon macOS and the CPU architecture.
2. Offers Bash, Zsh, Fish, or Nushell.
3. Activates either the `base` or `development` profile.
4. Downloads the official installer from `https://nixos.org/nix/install` only
   when Nix is missing and after confirmation.
5. Generates a local flake under
   `~/.config/thoughtoinnovate-nix` and activates it with Home Manager.
6. Copies the bundled dotfile template into a generated Stow tree, simulates
   Stow to detect conflicts, then links `common`, the selected shell, Starship,
   Ghostty, and Neovim. Profile setup additionally composes custom public or
   private components.

It is safe to rerun when both generated repositories are clean. It stops on
dotfile conflicts or local changes and never uses Stow's `--adopt` option. It
does not change the login shell, install credentials, or overwrite an unrelated
Home Manager configuration. For testing an unpublished checkout, use:

```sh
./install.sh --base-url "path:$PWD" --shell fish --profile development
```

Add `--generate-only` to inspect and lock the generated flake without
activating Home Manager or running Stow.

The private work repository can provide a small wrapper around this installer
after it exports its `work` overlay and Home Manager module.

## Create a personal or work profile

Most users should create one small configuration repository rather than fork
either public base:

```sh
mkdir my-profile && cd my-profile
nix flake init -t github:thoughtoinnovate/nix#profile
nix flake lock
git init && git add . && git commit -m "Create system profile"
./setup.sh
```

The generated repository pins this Nix base, uses its bundled shell, terminal,
and Neovim template, then adds `overlay.nix`, `home.nix`, and
`dotfiles/custom` last. One repository can represent a personal setup and
another a work setup.

The profile works from GitHub, GitLab, self-hosted Git, SSH, HTTPS, or a local
path. Users can clone it and run `./setup.sh`, or use the provider-neutral
bootstrap:

```sh
./bootstrap.sh \
  --config-url https://gitlab.com/alice/system-profile.git \
  -- --shell fish
```

Private repositories require Git authentication before bootstrap. The setup
framework does not copy or manage SSH keys, tokens, or credentials.

GUI applications launched from Finder, Spotlight, or a desktop menu generally
do not source interactive shell files. Configure those applications with an
explicit Nix executable path or wrapper instead of relying on `.zshrc` or an
equivalent file. For example, an AWS-backed Claude Desktop MCP server can set
`AWS_PROFILE` explicitly while the AWS SDK reads `~/.aws/config`, the local
credentials file, or the AWS SSO cache. Keep AWS credentials and tokens in
those local stores or a secret manager, never in a dotfile component.

Profile defaults live in `lib.setup.defaults`; `--shell` and `--profile`
override them. Dotfile layers are composed in their declared order before Stow
links one generated tree. Later regular files override earlier files,
directories merge, and file/directory type conflicts stop setup. The previous
linked generation is restored if activation fails.

Schema version 2 supports tool-specific components. Each ordered layer has a
`nix`, `path`, or `git` source and one or more `{ from, to, mode }` entries.
`merge` overlays files; `replace` clears a non-root target such as
`.config/nvim` first. Private Git sources require an exact 40-character commit
and are cloned outside the Nix store. This allows a work profile to retain all
public dotfiles while replacing only Neovim or another tool from GitLab.

`./setup.sh` reapplies locked versions. Profile owners use
`./setup.sh --update` to refresh public inputs, review and commit `flake.lock`,
and separately update exact private component SHAs. Consumers receive reviewed
changes through Git pull or central bootstrap.

## Consume the overlays

```nix
{
  inputs.nix-base.url = "github:thoughtoinnovate/nix";
  inputs.nixpkgs.follows = "nix-base/nixpkgs";

  outputs = { nix-base, nixpkgs, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          nix-base.overlays.base
          nix-base.overlays.development
        ];
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "vscode" ];
      };
    in
    {
      devShells.${system}.default = pkgs.mkJava21DevShell { };
    };
}
```

Downstream work repositories should apply overlays in this order:

```text
base -> development -> work
```

Use the same model for dotfiles. This repository owns the sanitized common,
shell, terminal, and editor defaults, while a personal or organization Git
component merges or replaces selected targets. Manual
multi-repository Stow remains available for additive, non-conflicting files:

```sh
stow --dir="$HOME/.work-dotfiles" --target="$HOME" --no-folding work
```

A downstream installer wrapper should run this base installer first, then
clone its own pinned work-dotfiles repository and simulate its Stow operation.
If two layers claim the same path, Stow stops; make an explicit downstream fork
when replacement rather than extension is required.

## Home Manager

The quickest starting point is the included template:

```sh
nix flake init -t github:thoughtoinnovate/nix
```

Reusable modules are exported as:

```nix
nix-base.homeModules.base
nix-base.homeModules.development
```

Enable the development profile in a Home Manager configuration:

```nix
{
  imports = [ nix-base.homeModules.development ];
  thoughtoinnovate.development.enable = true;
}
```

The module installs only the shells selected through
`thoughtoinnovate.base.shells`, plus common packages and fonts. Home Manager
does not write shell, Starship, Ghostty, Git, or Neovim configuration; Stow is
the final owner of the composed files. Bash and Zsh both source a portable common
file rather than sourcing one shell's startup file from the other. Credential
files are not loaded automatically.

```nix
thoughtoinnovate.base = {
  enable = true;
  shells = [ "fish" ];
};
```

## Version pinning and package sources

`flake.lock` pins one Nixpkgs snapshot, so all packages are reproducible as a
set. Do not separately pin each package unless a documented compatibility or
security issue requires it. Inspect critical versions with:

```sh
nix eval --raw .#packages.$(nix eval --impure --raw --expr builtins.currentSystem).neovim.version
```

At this repository's current lock, Neovim is `0.12.4`. Updating `flake.lock`
updates the package snapshot and must be reviewed like a dependency upgrade.

Nixpkgs packages are maintained build recipes, not a guarantee that each
vendor publishes or endorses the Nix package. In particular, CLI packages such
as Codex, Claude Code, and OpenCode should be reviewed in Nixpkgs before each
lock update. Ghostty's Linux package comes from Nixpkgs; its macOS application
comes from Homebrew's official cask. Home Manager controls installation and
activation but does not change the upstream source selected by Nixpkgs.

## Dotfiles and secrets

The bundled `dotfiles/` directory contains the complete sanitized default,
including Neovim. It must remain free of usernames, machine-specific home
paths, hostnames, credentials, and organization-only configuration. Store
secrets locally in platform credential stores or a secret manager and load
them explicitly only on machines that need them.

## macOS

Import `nix-base.darwinModules.default` in a nix-darwin configuration:

```nix
{
  imports = [ nix-base.darwinModules.default ];

  thoughtoinnovate.darwin = {
    enable = true;
    primaryUser = "alice";
    installGhostty = true;
  };
}
```

Homebrew must already be installed. Automatic Homebrew update, upgrade, and
cleanup are disabled so activation does not unexpectedly change unrelated
applications.

## Security

- Commit `flake.lock` and review lock-file updates.
- Never put tokens, passwords, private keys, or credential contents in Nix
  expressions. Evaluated values can enter the world-readable Nix store.
- Authenticate to GitHub, cloud providers, and AI tools after provisioning a
  machine.
- Keep organization-only packages and settings in a private downstream repo.
- Use only reviewed overlays, flake inputs, Homebrew taps, and binary caches.

## Existing consumers

Compatibility package names such as `base`, `base-devshell`,
`terminal-tools`, and `development-tools` remain available. The installer
automates safe Stow linking from public and private configuration components.
