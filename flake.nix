{
  description = "Reusable base terminal and development overlays for Nix flakes";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    ghostty = {
      url = "github:ghostty-org/ghostty?ref=v1.1.1";
    };
    dotfiles = {
      url = "path:./dotfiles";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ghostty, dotfiles }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ (import ./overlays/base.nix { inherit ghostty dotfiles; }) ];
        };
      in {
        packages = {
          ghostty = pkgs.ghostty;
          base = pkgs.base;
          base-devshell = pkgs.base-devshell;
          desktop-integration = pkgs.desktop-integration;
          setup-fish-default = pkgs.setup-fish-default;  # New helper
          default = pkgs.base;
        };

        devShells = {
          # Fish is now the default shell
          default = pkgs.mkBaseDevShell {};
          
          # Explicit options
          fish = pkgs.mkBaseFishDevShell {};  # Same as default now
          bash = pkgs.mkBaseBashDevShell {};  # Fallback option
        };
      }
    ) // {
      overlays = {
        default = import ./overlays/base.nix { inherit ghostty dotfiles; };
      };
    };
}
