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
  FiraCode Nerd Font, Java 21, and Ghostty on Linux. Java uses Amazon Corretto
  on Linux and OpenJDK on macOS.
- `development`: everything in `base`, plus Gradle, kubectl, minikube,
  lazygit, VS Code, and Java 11/17/21 development shells.
- `darwin`: nix-darwin integration and optional Homebrew installation of the
  Ghostty macOS application.

Ghostty is installed from Nixpkgs on Linux. On macOS, the bootstrap uses the
official Homebrew cask when Homebrew is available; the nix-darwin module can
manage the same cask declaratively. Configuration always comes from the
separate public dotfiles repository.

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
6. Clones the exact dotfiles revision pinned by `flake.lock` into
   `~/.dotfiles`, simulates Stow to detect conflicts, then links `common`, the
   selected shell, Starship, Ghostty, and Neovim configuration.

It is safe to rerun when both generated repositories are clean. It stops on
dotfile conflicts or local changes and never uses Stow's `--adopt` option. It
does not change the login shell, install credentials, or overwrite an unrelated
Home Manager configuration. For testing an unpublished checkout, use:

```sh
./install.sh --base-url "path:$PWD" --shell fish --profile development
```

Use `--dotfiles-url` or `--dotfiles-dir` to override dotfile checkout details.
Add `--generate-only` to inspect and lock the generated flake without
activating Home Manager, cloning dotfiles, or running Stow.

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

The generated repository pins this Nix base and the public dotfiles base, then
adds `overlay.nix`, `home.nix`, and `dotfiles/custom` last. Change either input
URL only when intentionally using a fork. One repository can represent a
personal setup and another a work setup.

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

Profile defaults live in `lib.setup.defaults`; `--shell` and `--profile`
override them. Dotfile layers are composed in their declared order before Stow
links one generated tree. Later regular files override earlier files,
directories merge, and file/directory type conflicts stop setup. The previous
linked generation is restored if activation fails.

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

Use the same model for dotfiles. The public dotfiles repository owns common
files; a separate personal or organization Git repository adds a `work` Stow
package through the documented `conf.d`, Nushell autoload, and Neovim
`local.lua` extension points. Stow uses `--no-folding`, which leaves parent
directories available for multiple repositories to add non-conflicting files:

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
the sole owner of those files. Bash and Zsh both source a small portable common
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

The companion repository is `https://github.com/thoughtoinnovate/dotfiles`.
Its revision is a non-flake input pinned in this repository's `flake.lock`.
Public configuration must never contain credentials. Store secrets locally in
`~/.secrets` or a secret manager and load them explicitly only on machines that
need them.

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
automates safe Stow linking, while the dotfiles repository owns persistent user
configuration.
