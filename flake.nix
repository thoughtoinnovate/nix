{
  description = "Reusable base terminal and development overlays for Nix flakes";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    ghostty = {
      url = "github:ghostty-org/ghostty?ref=v1.1.1";  # Pin to working version for Debian
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, ghostty }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ (import ./overlays/base.nix { inherit ghostty; }) ];
        };
      in {
        packages = {
          ghostty = pkgs.ghostty;
          base = pkgs.base;
          base-devshell = pkgs.base-devshell;
          desktop-integration = pkgs.desktop-integration;
          default = pkgs.base;
        };

        devShells = {
          default = pkgs.mkBaseDevShell {};
        };
      }
    ) // {
      # Export overlay for composability
      overlays = {
        default = import ./overlays/base.nix { inherit ghostty; };
      };
    };
}
