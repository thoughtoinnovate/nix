{
  description = "Reusable cross-platform terminal and development configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      baseOverlay = import ./overlays/base.nix;
      developmentOverlay = import ./overlays/development.nix;
    in
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              baseOverlay
              developmentOverlay
            ];
            config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "vscode" ];
          };
        in
        {
          packages = {
            inherit (pkgs)
              terminal-tools
              development-tools
              full-development-environment
              ;

            base = pkgs.terminal-tools;
            base-devshell = pkgs.development-tools;
            full-development = pkgs.full-development-environment;
            default = pkgs.development-tools;
          };

          devShells = {
            base = pkgs.mkBaseDevShell { };
            default = pkgs.mkJava21DevShell { };
            bash = pkgs.mkBaseBashDevShell { };
            zsh = pkgs.mkBaseZshDevShell { };
            java11 = pkgs.mkJava11DevShell { };
            java17 = pkgs.mkJava17DevShell { };
            java21 = pkgs.mkJava21DevShell { };
          };

          formatter = pkgs.nixfmt;

          checks.overlay-evaluation =
            assert pkgs ? terminal-tools;
            assert pkgs ? development-tools;
            assert pkgs ? mkJava21DevShell;
            pkgs.runCommand "overlay-evaluation" { } ''
              touch $out
            '';
        }
      )
    // {
      overlays = {
        default = baseOverlay;
        base = baseOverlay;
        development = developmentOverlay;
      };

      homeModules = {
        default = import ./modules/home;
        base = import ./modules/home/base.nix;
        development = import ./modules/home/development.nix;
      };

      darwinModules = {
        default = import ./modules/darwin;
        base = import ./modules/darwin;
      };

      templates.default = {
        path = ./templates/consumer;
        description = "Consumer flake for the thoughtoinnovate Nix base";
      };
    };
}
