{
  description = "Reusable base terminal and development overlays for Nix flakes";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    ghostty = {
      url = "github:ghostty-org/ghostty?ref=v1.1.1";
    };
    dotfiles = {
      url = "github:thoughtoinnovate/dotfiles?ref=main";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ghostty, dotfiles }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            (import ./overlays/base.nix { inherit ghostty dotfiles; })
            (import ./overlays/development.nix)
          ];
        };
      in {
        packages = {
          # Individual packages
          ghostty = pkgs.ghostty;
          
          # Bundled environments
          terminal-tools = pkgs.terminal-tools;
          development-tools = pkgs.development-tools;
          full-development = pkgs.full-development-environment;
          
          # Utility scripts
          desktop-integration = pkgs.desktop-integration;
          setup-fish-default = pkgs.setup-fish-default;
          dotfiles-stow = pkgs.dotfiles-stow;
          
          # Legacy aliases
          base = pkgs.terminal-tools;
          base-devshell = pkgs.development-tools;
          
          # Default package
          default = pkgs.development-tools;
        };

        devShells = {
          # Standard shells (no force flag needed anymore)
          default = pkgs.mkBaseDevShell {};
          fish = pkgs.mkBaseFishDevShell {};
          bash = pkgs.mkBaseBashDevShell {};
          
          # Java-specific shells
          java11 = pkgs.mkJava11DevShell {};
          java17 = pkgs.mkJava17DevShell {};
          java21 = pkgs.mkJava21DevShell {};
        };
      }
    ) // {
      overlays = {
        default = import ./overlays/base.nix { inherit ghostty dotfiles; };
        development = import ./overlays/development.nix;
      };
    };
}
