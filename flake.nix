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
      publicPackageCatalog = builtins.fromJSON (builtins.readFile ./catalogs/packages.json);
      profileConfig = import ./lib/profile-config.nix { lib = nixpkgs.lib; };
      declarativePackages = import ./lib/declarative-packages.nix { lib = nixpkgs.lib; };
      defaultProfileManifest = builtins.fromJSON (builtins.readFile ./templates/profile/home-weave.json);
      defaultCoreManifest = defaultProfileManifest // {
        distribution.name = "home-weave-core";
        profiles = {
          base = {
            extends = null;
            shells = [ "zsh" ];
            primaryShell = "zsh";
            dotfiles = [ "common" "starship" "ghostty" "nvim" "shells" ];
            packages.nix = publicPackageCatalog.base;
          };
          development = {
            extends = "base";
            development = true;
            packageGroups = [ ];
            dotfiles = [ ];
            packages.nix = publicPackageCatalog.development;
          };
        };
      };
      defaultResolvedBySystem = nixpkgs.lib.genAttrs
        [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ]
        (system: profileConfig.resolve {
          config = defaultCoreManifest;
          sourceRoot = self.outPath;
          sourceName = "home-weave-core";
          packageCatalog = publicPackageCatalog;
          inherit system;
        });
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
          meta.description = "Manage the ${distributionName} HomeWeave distribution";
        };
      mkHomeWeaveDistribution = import ./lib/distribution.nix {
        lib = nixpkgs.lib;
        core = self;
        inherit nixpkgs profileConfig publicPackageCatalog declarativePackages mkHomeWeaveApp;
        profileConfigSchema = ./schemas/home-weave-v3.schema.json;
        declarativePackageSchema = ./schemas/declarative-packages-v1.schema.json;
        nixpkgs-x86-darwin = inputs.nixpkgs-x86-darwin;
        home-manager = inputs.home-manager;
        home-manager-x86-darwin = inputs.home-manager-x86-darwin;
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
          unfreePkgs = import packageSource {
            inherit system;
            overlays = [
              darwinCacheOverlay
              baseOverlay
              developmentOverlay
            ];
            config.allowUnfreePredicate = pkg: packageSource.lib.getName pkg == "claude-code";
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
                    homeDirectory = "/tmp/home-weave-test-home";
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
          unfreeHomeTest = selectedHomeManager.lib.homeManagerConfiguration {
            pkgs = unfreePkgs;
            modules = [
              self.homeModules.default
              {
                home = {
                  username = "test-user";
                  homeDirectory = "/tmp/home-weave-test-home";
                  stateVersion = "26.05";
                  packages = [ unfreePkgs.claude-code ];
                };
                homeWeave.development.enable = true;
              }
            ];
          };
        in
        {
          packages = {
            inherit (pkgs)
              terminal-tools
              development-tools
              neovim
              starship
              stow
              home-weave-env
              home-weave-verified-installer
              ;

            home-weave = pkgs.home-weave-cli;

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
                    export HOME_WEAVE_PREFLIGHT_REPORTER=${./lib/preflight-report.sh}
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
            profile-config =
              let
                fixture = builtins.fromJSON
                  (builtins.readFile ./tests/fixtures/profile-inheritance.json);
                darwin = profileConfig.resolve {
                  config = fixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "fixture";
                  system = "aarch64-darwin";
                  packageCatalog = publicPackageCatalog;
                };
                linux = profileConfig.resolve {
                  config = fixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "fixture";
                  system = "x86_64-linux";
                  packageCatalog = publicPackageCatalog;
                };
                strictDarwinFixture = builtins.fromJSON
                  (builtins.readFile ./tests/fixtures/profile-strict-darwin.json);
                strictDarwin = profileConfig.resolve {
                  config = strictDarwinFixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "strict-fixture";
                  system = "aarch64-darwin";
                  packageCatalog = publicPackageCatalog;
                };
                strictLinuxFixture = builtins.fromJSON
                  (builtins.readFile ./tests/fixtures/profile-strict-linux.json);
                strictLinux = profileConfig.resolve {
                  config = strictLinuxFixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "strict-linux-fixture";
                  system = "x86_64-linux";
                  packageCatalog = publicPackageCatalog;
                };
                invalidExclusion = builtins.tryEval (builtins.deepSeq
                  (profileConfig.resolve {
                    config = builtins.fromJSON
                      (builtins.readFile ./tests/fixtures/profile-invalid-exclusion.json);
                    sourceRoot = ./tests/fixtures;
                    sourceName = "invalid-fixture";
                    system = "aarch64-darwin";
                    packageCatalog = publicPackageCatalog;
                  }).profiles.minimal.nixPackages true);
              in
              assert darwin.profiles.child.dotfiles == [ "common" "work-nvim" ];
              assert darwin.profiles.child.nixPackages == [ "claude-code" "ripgrep" ];
              assert darwin.profiles.child.allowUnfree == [ "claude-code" ];
              assert darwin.profiles.child.nativePackages.homebrewFormulae == [ "vault" ];
              assert darwin.profiles.child.providerPackages.company == [ "approved-app" ];
              assert map (layer: layer.name) darwin.profiles.child.dotfileLayers == [
                "fixture--base"
                "fixture--child"
              ];
              assert linux.profiles.child.nativePackages.apt == [ "curl" ];
              assert strictDarwin.profiles.minimal.nixPackages == [ ];
              assert strictDarwin.profiles.minimal.dotfiles == [ ];
              assert strictDarwin.profiles.minimal.nativePackages.homebrewFormulae == [ ];
              assert strictDarwin.profiles.minimal.nativePackages.homebrewCasks == [ ];
              assert strictDarwin.profiles.minimal.providerPackages == { };
              assert strictLinux.profiles.minimal.nativePackages.apt == [ ];
              assert strictLinux.profiles.minimal.nativePackages.pacman == [ ];
              assert invalidExclusion.success == false;
              pkgs.runCommand "profile-config" { nativeBuildInputs = [ pkgs.jq pkgs.check-jsonschema ]; } ''
                jq -e . ${./schemas/home-weave-v3.schema.json} >/dev/null
                check-jsonschema --schemafile ${./schemas/home-weave-v3.schema.json} \
                  ${./templates/profile/home-weave.json} \
                  ${./templates/distribution/profile-overlay/home-weave.json} \
                  ${./tests/fixtures/profile-inheritance.json} \
                  ${./tests/fixtures/profile-strict-darwin.json} \
                  ${./tests/fixtures/profile-strict-linux.json} \
                  ${./tests/fixtures/profile-invalid-exclusion.json}
                check-jsonschema --schemafile ${./schemas/package-catalog-v1.schema.json} \
                  ${./catalogs/packages.json}
                touch $out
              '';

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

            unfree-profile-evaluation = builtins.deepSeq unfreeHomeTest.activationPackage.drvPath (
              pkgs.runCommand "unfree-profile-evaluation" { } ''
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
                  bash ${./tests/test-public-dotfiles.sh} ${./dotfiles} ${./.}
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
                    nix
                    ripgrep
                    rsync
                    stow
                  ];
                }
                ''
                  bash ${./tests/test-home-weave-cli.sh} \
                    ${./home-weave.sh} ${./templates/profile} ${./lib/home-weave-env.sh}
                  touch $out
                '';

            home-weave-env =
              pkgs.runCommand "home-weave-env-tests"
                {
                  nativeBuildInputs = with pkgs; [
                    bash
                    coreutils
                    fish
                    jq
                    nushell
                    zsh
                  ];
                }
                ''
                  bash ${./tests/test-home-weave-env.sh} \
                    ${./lib/home-weave-env.sh} ${./dotfiles}
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

            install-no-casks =
              pkgs.runCommand "install-no-casks-tests"
                {
                  nativeBuildInputs = [ pkgs.gnused ];
                }
                ''
                  bash ${./tests/test-install-no-casks.sh} ${./install.sh} ${./flake.nix}
                  touch $out
                '';

            verified-installer =
              pkgs.runCommand "verified-installer-tests"
                {
                  nativeBuildInputs = with pkgs; [
                    bash
                    coreutils
                    gawk
                    gnugrep
                    jq
                  ];
                }
                ''
                  bash ${./tests/test-verified-installer.sh} \
                    ${./lib/verified-installer.sh}
                  touch $out
                '';

            declarative-package-policy =
              let
                packageForCatalog = catalog:
                  let candidate = import packageSource {
                    inherit system;
                    overlays = [ (declarativePackages.mkOverlay { inherit catalog; sourceRoot = ./.; }) ];
                    config.allowUnsupportedSystem = true;
                  };
                  in candidate.policy-test;
                evaluateCatalog = catalog:
                  builtins.tryEval (builtins.deepSeq (packageForCatalog catalog).drvPath true);
                badHost = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    platforms.${system} = {
                      url = "https://unreviewed.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      install.kind = "copy-tree";
                    };
                  };
                };
                unsupported = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    platforms."unsupported-system" = {
                      url = "https://official.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      install.kind = "copy-tree";
                    };
                  };
                };
                wrongVersion = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "nixpkgs"; attr = "jq"; version = "0.0-invalid";
                  };
                };
                extensionlessZip = packageForCatalog
                  (builtins.fromJSON (builtins.readFile ./tests/fixtures/extensionless-zip.json));
              in
              assert badHost.success == false;
              assert unsupported.success == false;
              assert wrongVersion.success == false;
              assert nixpkgs.lib.hasSuffix ".zip" extensionlessZip.src.name;
              pkgs.runCommand "declarative-package-policy" { nativeBuildInputs = [ pkgs.check-jsonschema ]; } ''
                check-jsonschema --schemafile ${./schemas/declarative-packages-v1.schema.json} \
                  ${./tests/fixtures/declarative-packages.json}
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
      lib.profileConfig = profileConfig;
      lib.profileConfigSchema = ./schemas/home-weave-v3.schema.json;
      lib.setup = {
        schemaVersion = 5;
        namespace = "home-weave";
        defaults = { profile = "base"; shell = "zsh"; };
        profilesBySystem = nixpkgs.lib.mapAttrs (_: value: value.profiles) defaultResolvedBySystem;
        dotfilesBySystem = nixpkgs.lib.mapAttrs (_: value: value.dotfiles) defaultResolvedBySystem;
        profiles = defaultResolvedBySystem.x86_64-linux.profiles;
        dotfiles = defaultResolvedBySystem.x86_64-linux.dotfiles;
      };
      lib.verifiedInstaller = {
        schemaVersion = 1;
        program = ./lib/verified-installer.sh;
      };
      lib.mkHomeWeaveApp = mkHomeWeaveApp;
      lib.packageCatalog = publicPackageCatalog;
      lib.packageCatalogSchema = ./schemas/package-catalog-v1.schema.json;
      lib.declarativePackages = declarativePackages;
      lib.declarativePackageSchema = ./schemas/declarative-packages-v1.schema.json;
      lib.mkHomeWeaveDistribution = mkHomeWeaveDistribution;
      lib.homeWeave = {
        schemaVersion = 1;
        sourcesBySystem = nixpkgs.lib.genAttrs
          [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ]
          (system: {
            nixpkgs = if system == "x86_64-darwin"
              then inputs.nixpkgs-x86-darwin
              else inputs.nixpkgs;
            homeManager = if system == "x86_64-darwin"
              then inputs.home-manager-x86-darwin
              else inputs.home-manager;
          });
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
