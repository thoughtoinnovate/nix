{
  description = "Reusable cross-platform terminal and development configuration";

  inputs = {
    # The Darwin rolling branch has substantially better binary-cache coverage
    # than the NixOS-oriented channel and is also suitable for Linux consumers.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Upstream removed Intel Darwin from 26.11. Keep the final supported,
    # security-maintained official branch solely for x86_64-darwin.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    flake-utils.url = "github:numtide/flake-utils";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-x86-darwin = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-x86-darwin";
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
      # nixpkgs-unstable's Darwin linker fix landed before its Starship output
      # reached cache.nixos.org. Use the final supported Darwin channel's
      # cache-backed Starship until the unstable output is substituted.
      darwinCacheOverlay = final: prev: {
        starship =
          if prev.stdenv.hostPlatform.isDarwin then
            (import inputs.nixpkgs-x86-darwin {
              system = prev.stdenv.hostPlatform.system;
            }).starship
          else
            prev.starship;
      };
      mkHomeWeaveApp =
        {
          system,
          extensions ? [ ],
          distributionName ? "HomeWeave",
          baseUrl ? "github:thoughtoinnovate/nix",
          profileOverlay ? null,
          packageSource ? nixpkgs,
        }:
        let
          appPkgs = import packageSource {
            inherit system;
            overlays = [ baseOverlay ];
            config.allowUnsupportedSystem = true;
          };
          extensionJson = builtins.toJSON extensions;
          wrapper = appPkgs.writeShellApplication {
            name = "home-weave";
            runtimeInputs = [ appPkgs.home-weave-cli ];
            text = ''
              export HOME_WEAVE_DISTRIBUTION=${nixpkgs.lib.escapeShellArg distributionName}
              export HOME_WEAVE_BASE_URL=${nixpkgs.lib.escapeShellArg baseUrl}
              export HOME_WEAVE_EXTENSIONS_JSON=${nixpkgs.lib.escapeShellArg extensionJson}
              ${nixpkgs.lib.optionalString (profileOverlay != null) ''
                export HOME_WEAVE_PROFILE_OVERLAY=${nixpkgs.lib.escapeShellArg (toString profileOverlay)}
              ''}
              exec home-weave "$@"
            '';
          };
        in
        {
          type = "app";
          program = "${wrapper}/bin/home-weave";
        };
    in
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ]
      (
        system:
        let
          packageSource = if system == "x86_64-darwin" then inputs.nixpkgs-x86-darwin else nixpkgs;
          selectedHomeManager =
            if system == "x86_64-darwin" then inputs.home-manager-x86-darwin else inputs.home-manager;
          pkgs = import packageSource {
            inherit system;
            overlays = [
              darwinCacheOverlay
              baseOverlay
              developmentOverlay
            ];
            config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "vscode" ];
            config.allowUnsupportedSystem = true;
          };
          homeTest =
            shell: development:
            selectedHomeManager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                self.homeModules.default
                {
                  home = {
                    username = "test-user";
                    homeDirectory = if pkgs.stdenv.hostPlatform.isDarwin then "/Users/test-user" else "/home/test-user";
                    stateVersion = "26.05";
                  };
                  homeWeave = {
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

            home-weave = pkgs.home-weave-cli;

            base = pkgs.terminal-tools;
            base-devshell = pkgs.development-tools;
            full-development = pkgs.full-development-environment;
            default = pkgs.development-tools;
          };

          apps = {
            home-weave = mkHomeWeaveApp {
              inherit system packageSource;
            };
            setup = {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "home-weave-setup";
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
                    export HOME_WEAVE_DOTFILE_COMPOSER=${./lib/compose-dotfiles.sh}
                    exec ${pkgs.bash}/bin/bash ${./install.sh} "$@"
                  '';
                }
              }/bin/home-weave-setup";
              meta.description = "Bootstrap a standalone or custom HomeWeave system profile";
            };
            default = self.apps.${system}.home-weave;
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
              assert
                let
                  leanNames = map nixpkgs.lib.getName pkgs.leanDevelopmentPackages;
                in
                builtins.all (name: !(builtins.elem name leanNames)) [
                  "jupyter"
                  "vscode"
                  "jdk"
                  "go"
                  "rustc"
                  "terraform"
                  "kubectl"
                ];
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

            home-weave-cli =
              pkgs.runCommand "home-weave-cli-tests"
                {
                  nativeBuildInputs = with pkgs; [
                    bash
                    coreutils
                    diffutils
                    git
                    gnugrep
                    gnused
                    jq
                    ripgrep
                    rsync
                    stow
                  ];
                }
                ''
                  bash ${./tests/test-home-weave-cli.sh} \
                    ${./home-weave.sh} ${./templates/profile}
                  touch $out
                '';

            preflight-parser =
              pkgs.runCommand "preflight-parser-tests"
                {
                  nativeBuildInputs = with pkgs; [
                    bash
                    coreutils
                    gnugrep
                    gnused
                    jq
                  ];
                }
                ''
                  bash ${./tests/test-preflight-parser.sh} ${./lib/preflight-report.sh}
                  touch $out
                '';

            publisher-verification =
              pkgs.runCommand "publisher-verification-tests"
                {
                  nativeBuildInputs = [ pkgs.jq ];
                }
                ''
                  bash ${./tests/test-publisher-verification.sh} \
                    ${./lib/verify-publishers.jq} ${./lib/reviewed-publishers.json}
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
        darwin-cache = darwinCacheOverlay;
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
      lib.mkHomeWeaveApp = mkHomeWeaveApp;
      lib.packageCatalog = {
        base = [
          "clang"
          "fd"
          "git"
          "gnumake"
          "home-weave-cli"
          "neovim"
          "nodejs"
          "python3"
          "ripgrep"
          "starship"
          "stow"
          "unzip"
        ];
        development = [
          "jq"
          "lazygit"
          "shellcheck"
          "shfmt"
          "tmux"
        ];
        groups = {
          python = [
            "python3"
            "python3Packages.debugpy"
            "black"
            "pyright"
            "ruff"
          ];
          data-jupyter = [
            "jupyter"
            "python3Packages.notebook"
            "python3Packages.ipykernel"
            "jupytext"
            "python3Packages.pillow"
            "python3Packages.cairosvg"
          ];
          go = [
            "go"
            "gopls"
            "delve"
            "golangci-lint"
          ];
          rust = [
            "cargo"
            "rustc"
            "rust-analyzer"
            "taplo"
          ];
          java = [
            "jdk17"
            "gradle"
            "jdt-language-server"
            "google-java-format"
          ];
          web = [
            "eslint"
            "prettier"
            "typescript-language-server"
            "yaml-language-server"
            "marksman"
            "markdownlint-cli2"
            "vscode-langservers-extracted"
            "vscode-js-debug"
          ];
          cloud = [
            "awscli2"
            "terraform"
            "kubectl"
            "minikube"
          ];
          desktop = [ "vscode" ];
        };
      };

      templates.default = {
        path = ./templates/consumer;
        description = "Consumer flake for HomeWeave";
      };

      templates.profile = {
        path = ./templates/profile;
        description = "Extensible personal or work profile using Nix and Stow";
      };

      templates.distribution = {
        path = ./templates/distribution;
        description = "Private redistributable HomeWeave edition";
      };
    };
}
