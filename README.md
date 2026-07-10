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
  Java 21, and Ghostty on Linux. Java uses Amazon Corretto on Linux and
  OpenJDK on macOS.
- `development`: everything in `base`, plus Gradle, kubectl, minikube,
  lazygit, VS Code, and Java 11/17/21 development shells.
- `darwin`: nix-darwin integration and optional Homebrew installation of the
  Ghostty macOS application.

Ghostty is installed from Nixpkgs on Linux. On macOS, Home Manager manages the
configuration while nix-darwin asks an existing Homebrew installation to
install the official Ghostty cask.

## Test the base

```sh
nix flake show
nix flake check
nix develop .#java21
```

Development shells never modify dotfiles, change the login shell, or launch a
different interactive shell automatically.

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

The module configures Bash and Zsh from the same settings. It does not source
`~/.bash_profile` from Zsh and does not load credential files.

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
`terminal-tools`, and `development-tools` remain available. Automatic Stow,
desktop mutation, and login-shell setup helpers were intentionally removed;
Home Manager now owns persistent user configuration.
