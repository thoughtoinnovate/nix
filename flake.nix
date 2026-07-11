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
          homeTest =
            shell: development:
            inputs.home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                self.homeModules.default
                {
                  home = {
                    username = "test-user";
                    homeDirectory = if pkgs.stdenv.hostPlatform.isDarwin then "/Users/test-user" else "/home/test-user";
                    stateVersion = "26.05";
                  };
                  thoughtoinnovate = {
                    base = {
                      enable = true;
                      shells = [ shell ];
                    };
                    development.enable = development;
                  };
                }
              ];
            };
          homeTestDerivations =
            builtins.concatMap
              (
                shell:
                map (development: (homeTest shell development).activationPackage.drvPath) [
                  false
                  true
                ]
              )
              [
                "bash"
                "fish"
                "nushell"
                "zsh"
              ];
        in
        {
          packages = {
            inherit (pkgs)
              terminal-tools
              development-tools
              full-development-environment
              neovim
              starship
              stow
              ;

            base = pkgs.terminal-tools;
            base-devshell = pkgs.development-tools;
            full-development = pkgs.full-development-environment;
            default = pkgs.development-tools;
          };

          apps = {
            setup = {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "thoughtoinnovate-setup";
                  runtimeInputs = with pkgs; [
                    coreutils
                    curl
                    git
                    gnused
                    jq
                    rsync
                    stow
                  ];
                  text = ''
                    export THOUGHTOINNOVATE_DOTFILE_COMPOSER=${./lib/compose-dotfiles.sh}
                    exec ${pkgs.bash}/bin/bash ${./install.sh} "$@"
                  '';
                }
              }/bin/thoughtoinnovate-setup";
              meta.description = "Bootstrap a standalone or custom thoughtoinnovate system profile";
            };
            default = self.apps.${system}.setup;
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

          checks = {
            overlay-evaluation =
              assert pkgs ? terminal-tools;
              assert pkgs ? development-tools;
              assert pkgs ? mkJava21DevShell;
              pkgs.runCommand "overlay-evaluation" { } ''
                touch $out
              '';

            home-module-evaluation = builtins.deepSeq homeTestDerivations (
              pkgs.runCommand "home-module-evaluation" { } ''
                touch $out
              ''
            );

            dotfile-components =
              pkgs.runCommand "dotfile-components"
                {
                  nativeBuildInputs = with pkgs; [
                    coreutils
                    git
                    jq
                    rsync
                    stow
                  ];
                }
                ''
                    bash ${./tests/test-profile-dotfiles.sh} \
                      ${./dotfiles} \
                      ${./lib/compose-dotfiles.sh}
                  touch $out
                '';

            public-dotfile-sanitization =
              pkgs.runCommand "public-dotfile-sanitization"
                {
                  nativeBuildInputs = with pkgs; [
                    coreutils
                    gnugrep
                    ripgrep
                  ];
                }
                ''
                  bash ${./tests/test-public-dotfiles.sh} ${./dotfiles}
                  touch $out
                '';
          };
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

      lib.dotfiles.path = ./dotfiles;

      templates.default = {
        path = ./templates/consumer;
        description = "Consumer flake for the thoughtoinnovate Nix base";
      };

      templates.profile = {
        path = ./templates/profile;
        description = "Extensible personal or work profile using Nix and Stow";
      };
    };
}
