{
  description = "Reusable cross-platform terminal and development configuration";

  nixConfig = {
    substituters = [ "https://cache.nixos.org/" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    require-sigs = true;
    sandbox = true;
  };

  inputs = {
    # The Darwin rolling branch has substantially better binary-cache coverage
    # than the NixOS-oriented channel and is also suitable for Linux consumers.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Upstream removed Intel Darwin from 26.11. Keep the final supported,
    # security-maintained official branch solely for x86_64-darwin.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    flake-utils.url = "github:numtide/flake-utils";

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
      rawBaseOverlay = import ./overlays/base.nix;
      developmentOverlay = import ./overlays/development.nix;
      publicPackageCatalog = builtins.fromJSON (builtins.readFile ./catalogs/packages.json);
      profileConfig = import ./lib/profile-config.nix { lib = nixpkgs.lib; };
      declarativePackages = import ./lib/declarative-packages.nix { lib = nixpkgs.lib; };
      sdkmanPlugin = import ./plugins/sdkman {
        lib = nixpkgs.lib;
        inherit declarativePackages;
        sourceRoot = self.outPath;
      };
      nvmPlugin = import ./plugins/nvm {
        inherit declarativePackages;
        sourceRoot = self.outPath;
      };
      opencodeOverlay = declarativePackages.mkOverlay {
        catalog = builtins.fromJSON (builtins.readFile ./packages/opencode.json);
      };
      publicPlugins = {
        sdkman = sdkmanPlugin;
        nvm = nvmPlugin;
      };
      baseOverlay = nixpkgs.lib.composeManyExtensions [
        rawBaseOverlay sdkmanPlugin.overlay nvmPlugin.overlay opencodeOverlay
      ];
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
            shells = [ "bash" "fish" "zsh" "nushell" ];
            primaryShell = "zsh";
            packageGroups = [ ];
            dotfiles = [ ];
            packages.nix = publicPackageCatalog.development;
            plugins.nvm = {
              enabled = true;
              storage = "nix-store";
            };
            plugins.sdkman = {
              enabled = true;
              storage = "nix-store";
              allowRuntimeChanges = true;
              candidates = {
                java = [
                  { version = "11.0.31-amzn"; default = false; }
                  { version = "17.0.19-amzn"; default = false; }
                  { version = "21.0.11-amzn"; default = true; }
                  { version = "26.0.1-amzn"; default = false; }
                ];
                gradle = [ { version = "9.6.1"; default = true; } ];
              };
            };
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
          pluginRegistry = publicPlugins;
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
          plugins ? publicPlugins,
        }:
        let
          appPkgs = import packageSource {
            inherit system;
            overlays = [ baseOverlay ];
            config.allowUnsupportedSystem = true;
          };
          extensionJson = builtins.toJSON extensions;
          pluginJson = builtins.toJSON (nixpkgs.lib.mapAttrs (_: plugin: {
            inherit (plugin) schemaVersion name kind platforms lifecycle;
          }) plugins);
          wrapper = appPkgs.writeShellApplication {
            name = "home-weave";
            runtimeInputs = [ appPkgs.home-weave-cli ];
            text = ''
              export HOME_WEAVE_DISTRIBUTION=${nixpkgs.lib.escapeShellArg distributionName}
              export HOME_WEAVE_BASE_URL=${nixpkgs.lib.escapeShellArg baseUrl}
              export HOME_WEAVE_EXTENSIONS_JSON=${nixpkgs.lib.escapeShellArg extensionJson}
              export HOME_WEAVE_PLUGINS_JSON=${nixpkgs.lib.escapeShellArg pluginJson}
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
        profileConfigSchema = ./schemas/home-weave-v4.schema.json;
        declarativePackageSchema = ./schemas/declarative-packages-v1.schema.json;
        nixpkgs-x86-darwin = inputs.nixpkgs-x86-darwin;
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
          packageFor = packageSet: name:
            nixpkgs.lib.attrByPath (nixpkgs.lib.splitString "." name)
              (throw "HomeWeave package is unavailable: ${name}") packageSet;
          profileEnvironments = nixpkgs.lib.mapAttrs (name: profile:
            pkgs.buildEnv {
              name = "home-weave-${name}-environment";
              paths = map (packageFor pkgs) profile.nixPackages
                ++ map (shell: pkgs.shellPackages.${shell}) profile.shells;
            }
          ) defaultResolvedBySystem.${system}.profiles;
          defaultProfileName = defaultResolvedBySystem.${system}.defaults.profile;
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
              home-weave-native-provider
              home-weave-verified-installer
              opencode
              ;

            home-weave = pkgs.home-weave-cli;
            home-weave-environment = profileEnvironments.${defaultProfileName};
            inherit (pkgs) home-weave-sdkman home-weave-sdkman-java;

            default = pkgs.development-tools;
          } // nixpkgs.lib.mapAttrs' (name: environment:
            nixpkgs.lib.nameValuePair "home-weave-environment-${name}" environment
          ) profileEnvironments;

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
                fixturePlugin = {
                  schemaVersion = 1;
                  name = "fixture-plugin";
                  platforms = [ "aarch64-darwin" "x86_64-linux" ];
                  lifecycle = { packages = "retain"; state = "remove"; };
                  resolve = { selection, ... }: {
                    nixPackages = [ "plugin-tool" ];
                    providerPackages = { example = selection.items; };
                  };
                };
                fixturePlugins = publicPlugins // { fixture-plugin = fixturePlugin; };
                fixture = builtins.fromJSON
                  (builtins.readFile ./tests/fixtures/profile-inheritance.json);
                darwin = profileConfig.resolve {
                  config = fixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "fixture";
                  system = "aarch64-darwin";
                  packageCatalog = publicPackageCatalog;
                  pluginRegistry = fixturePlugins;
                };
                linux = profileConfig.resolve {
                  config = fixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "fixture";
                  system = "x86_64-linux";
                  packageCatalog = publicPackageCatalog;
                  pluginRegistry = fixturePlugins;
                };
                strictDarwinFixture = builtins.fromJSON
                  (builtins.readFile ./tests/fixtures/profile-strict-darwin.json);
                strictDarwin = profileConfig.resolve {
                  config = strictDarwinFixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "strict-fixture";
                  system = "aarch64-darwin";
                  packageCatalog = publicPackageCatalog;
                  pluginRegistry = publicPlugins;
                };
                strictLinuxFixture = builtins.fromJSON
                  (builtins.readFile ./tests/fixtures/profile-strict-linux.json);
                strictLinux = profileConfig.resolve {
                  config = strictLinuxFixture;
                  sourceRoot = ./tests/fixtures;
                  sourceName = "strict-linux-fixture";
                  system = "x86_64-linux";
                  packageCatalog = publicPackageCatalog;
                  pluginRegistry = publicPlugins;
                };
                invalidExclusion = builtins.tryEval (builtins.deepSeq
                  (profileConfig.resolve {
                    config = builtins.fromJSON
                      (builtins.readFile ./tests/fixtures/profile-invalid-exclusion.json);
                    sourceRoot = ./tests/fixtures;
                    sourceName = "invalid-fixture";
                    system = "aarch64-darwin";
                    packageCatalog = publicPackageCatalog;
                    pluginRegistry = publicPlugins;
                  }).profiles.minimal.nixPackages true);
              in
              assert darwin.profiles.child.dotfiles == [ "common" "work-nvim" ];
              assert darwin.profiles.child.nixPackages == [ "claude-code" "ripgrep" "plugin-tool" ];
              assert darwin.profiles.child.allowUnfree == [ "claude-code" ];
              assert darwin.profiles.child.nativePackages.homebrewFormulae == [ "vault" ];
              assert darwin.profiles.child.providerPackages.example == [ "approved-app" ];
              assert darwin.profiles.child.pluginContributions.fixture-plugin.lifecycle.packages == "retain";
              assert !(builtins.elem "plugin-tool" darwin.profiles.disabled.nixPackages);
              assert darwin.profiles.disabled.providerPackages == { };
              assert darwin.profiles.disabled.pluginContributions == { };
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
                jq -e . ${./schemas/home-weave-v4.schema.json} >/dev/null
                check-jsonschema --schemafile ${./schemas/home-weave-v4.schema.json} \
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

            nvm-shell-integration =
              pkgs.runCommand "nvm-shell-integration" {
                nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.zsh ];
              } ''
                bash ${./tests/test-nvm-plugin.sh} ${./plugins/nvm/shell-init.sh}
                touch $out
              '';

            opencode-release =
              pkgs.runCommand "opencode-release" {
                nativeBuildInputs = [ pkgs.gnugrep pkgs.opencode ];
              } ''
                set +e
                version_output="$(HOME="$TMPDIR" opencode --version)"
                version_status=$?
                set -e
                printf 'OpenCode version command exited %s and reported: %s\n' \
                  "$version_status" "$version_output"
                test "$version_status" -eq 0
                printf '%s\n' "$version_output" \
                  | grep -Eq '(^|[^0-9.])1\.18\.4([^0-9.]|$)'
                touch $out
              '';

            sdkman-java-integration =
              pkgs.runCommand "sdkman-java-integration" {
                nativeBuildInputs = [ pkgs.home-weave-sdkman-java ];
              } ''
                state="$TMPDIR/sdkman-state"
                mkdir -p "$state/candidates/scala"
                ln -s /nix/store/home-weave-obsolete-scala "$state/candidates/scala/3.8.4"
                ln -s 3.8.4 "$state/candidates/scala/current"
                HOME_WEAVE_SDKMAN_STATE="$state" sdk version >/dev/null
                test -d "$state/candidates/java"
                test -d "$state/candidates/gradle"
                test ! -e "$state/candidates/scala/3.8.4"
                test ! -e "$state/candidates/scala/current"
                test "$(cut -d' ' -f1 "$state/var/home-weave-managed-candidates" | sort -u | tr '\n' ' ')" = "gradle java "
                test -x ${pkgs.home-weave-sdkman-java}/bin/java
                test -x ${pkgs.home-weave-sdkman-java}/bin/gradle
                touch $out
              '';

            package-environment-evaluation =
              assert builtins.elem "home-weave-nvm"
                defaultResolvedBySystem.${system}.profiles.development.nixPackages;
              assert builtins.elem "opencode"
                defaultResolvedBySystem.${system}.profiles.development.nixPackages;
              assert builtins.elem "home-weave-sdkman-java"
                defaultResolvedBySystem.${system}.profiles.development.nixPackages;
              assert !(builtins.elem "home-weave-sdkman"
                defaultResolvedBySystem.${system}.profiles.development.nixPackages);
              assert defaultResolvedBySystem.${system}.profiles.development.shells
                == [ "bash" "fish" "zsh" "nushell" ];
              assert builtins.attrNames defaultResolvedBySystem.${system}.profiles.development
                .pluginContributions.sdkman.metadata.candidates == [ "gradle" "java" ];
              assert publicPackageCatalog.groups.ai == [ "opencode" ];
              assert defaultResolvedBySystem.${system}.profiles.development
                .pluginContributions.nvm.metadata.shellSupport == [ "bash" "zsh" ];
              assert defaultResolvedBySystem.${system}.profiles.development
                .pluginContributions.nvm.lifecycle.state == "retain";
              assert defaultResolvedBySystem.${system}.profiles.development
                .pluginContributions.nvm.statePaths == [ ];
              builtins.deepSeq (map (environment: environment.drvPath)
                (builtins.attrValues profileEnvironments)) (
              pkgs.runCommand "package-environment-evaluation" { } ''
                touch $out
              ''
            );

            unfree-profile-evaluation = builtins.deepSeq unfreePkgs.claude-code.drvPath (
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
                    starship
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
                  bash ${./tests/test-public-audit-git-exclusion.sh} \
                    ${./tests/test-public-dotfiles.sh}
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
                    ${./home-weave.sh} ${./templates/profile} ${./lib/home-weave-env.sh} \
                    ${pkgs.home-weave-native-provider}/bin/home-weave-native-provider \
                    ${./lib/native-provider.sh}
                  touch $out
                '';

            guided-scaffold =
              pkgs.runCommand "guided-scaffold-tests"
                {
                  nativeBuildInputs = with pkgs; [ bash gnugrep ];
                }
                ''
                  bash ${./tests/test-guided-scaffold.sh} \
                    ${./QUICKSTART.md} ${./README.md} ${./templates/profile/README.md} \
                    ${./templates/profile/flake-inherited.nix} ${./plugins/nvm/default.nix}
                  touch $out
                '';

            ci-entrypoints =
              pkgs.runCommand "ci-entrypoint-tests"
                {
                  nativeBuildInputs = with pkgs; [ bash gnugrep ];
                }
                ''
                  bash ${./tests/test-ci-entrypoints.sh} \
                    ${./.github/workflows/ci.yml} \
                    ${./.github/workflows/full-build.yml} \
                    ${./tests/containers/run-e2e.sh} \
                    ${./tests/containers/debian/Dockerfile} \
                    ${./tests/containers/ubuntu/Dockerfile} \
                    ${./tests/containers/arch/Dockerfile}
                  touch $out
                '';

            native-provider =
              pkgs.runCommand "native-provider-tests"
                {
                  nativeBuildInputs = with pkgs; [ bash gnused ];
                }
                ''
                  bash ${./tests/test-native-provider.sh} ${./lib/native-provider.sh}
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
                  nativeBuildInputs = with pkgs; [ coreutils gnused jq rsync ];
                }
                ''
                  bash ${./tests/test-install-no-casks.sh} \
                    ${./install.sh} ${./flake.nix} \
                    ${./templates/profile/home-weave} ${./templates/profile/setup.sh} ${./flake.lock}
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
                    artifacts.${system} = {
                      url = "https://unreviewed.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      install = {
                        kind = "macos-app";
                        bundle = "Tool App.app";
                        executable = "Contents/MacOS/tool";
                        command = "tool";
                      };
                    };
                  };
                };
                unsupported = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts."unsupported-system" = {
                      url = "https://official.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      install.kind = "copy-tree";
                    };
                  };
                };
                legacyPlatforms = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    platforms.${system} = {
                      url = "https://official.invalid/legacy-tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      install.kind = "copy-tree";
                    };
                  };
                };
                portableArtifact = packageForCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.default = {
                      url = "https://official.invalid/portable-tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      sourceRoot = "portable-tool-1";
                      install = { kind = "copy-tree"; destination = "share/portable-tool"; };
                    };
                  };
                };
                wrongVersion = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "nixpkgs"; attr = "jq"; version = "0.0-invalid";
                  };
                };
                unsafeDynamicLinkerPath = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      dynamicLinkerWrapper = pkgs.stdenv.hostPlatform.isLinux;
                      dynamicLinkerExecutables = [ "../libexec/tool" ];
                      runtimeLibraries =
                        nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux
                          [ "stdenv.cc.cc.lib" ];
                      install.kind = "copy-tree";
                    };
                  };
                };
                unwrappedDynamicLinkerPath = evaluateCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      dynamicLinkerExecutables = [ "libexec/tool" ];
                      install.kind = "copy-tree";
                    };
                  };
                };
                extensionlessZip = packageForCatalog
                  (builtins.fromJSON (builtins.readFile ./tests/fixtures/extensionless-zip.json));
                rawExecutable = packageForCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      format = "raw";
                      install = {
                        kind = "executables";
                        files = [ { source = "tool"; target = "bin/tool"; } ];
                      };
                    };
                  };
                };
                dmgApplication = packageForCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool.dmg";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      format = "dmg";
                      install = {
                        kind = "macos-app";
                        bundle = "Tool.app";
                        executable = "Contents/MacOS/tool";
                        command = "tool";
                      };
                    };
                  };
                };
                dmgCliApplication = packageForCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool-cli.dmg";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      format = "dmg";
                      install = {
                        kind = "macos-cli-app";
                        bundle = "Tool CLI.app";
                        executable = "Contents/MacOS/tool";
                        command = "tool";
                      };
                    };
                  };
                };
                dynamicLinkerExecutable = packageForCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      dynamicLinkerWrapper = pkgs.stdenv.hostPlatform.isLinux;
                      runtimeLibraries =
                        nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux
                          [ "stdenv.cc.cc.lib" ];
                      install = {
                        kind = "executables";
                        files = [ { source = "tool"; target = "bin/tool"; } ];
                      };
                    };
                  };
                };
                dynamicLinkerCopyTree = packageForCatalog {
                  schemaVersion = 1;
                  packages.policy-test = {
                    kind = "archive"; version = "1"; officialHosts = [ "official.invalid" ];
                    artifacts.${system} = {
                      url = "https://official.invalid/tool.tar.gz";
                      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                      dynamicLinkerWrapper = pkgs.stdenv.hostPlatform.isLinux;
                      dynamicLinkerExecutables =
                        nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux
                          [ "libexec/tool" ];
                      runtimeLibraries =
                        nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux
                          [ "stdenv.cc.cc.lib" ];
                      install = {
                        kind = "copy-tree";
                        destination = "share/tool";
                      };
                    };
                  };
                };
              in
              assert badHost.success == false;
              assert unsupported.success == false;
              assert legacyPlatforms.success == false;
              assert wrongVersion.success == false;
              assert unsafeDynamicLinkerPath.success == false;
              assert unwrappedDynamicLinkerPath.success == false;
              assert portableArtifact.src.url == "https://official.invalid/portable-tool.tar.gz";
              assert portableArtifact.sourceRoot == "portable-tool-1";
              assert portableArtifact.meta.platforms == nixpkgs.lib.platforms.all;
              assert nixpkgs.lib.hasSuffix ".zip" extensionlessZip.src.name;
              assert nixpkgs.lib.hasInfix "cp \"$src\" source/tool" rawExecutable.preInstall;
              assert nixpkgs.lib.hasSuffix ".dmg" dmgApplication.src.name;
              assert builtins.elem pkgs.undmg dmgApplication.nativeBuildInputs;
              assert !pkgs.stdenv.hostPlatform.isDarwin
                || nixpkgs.lib.hasInfix "/usr/bin/xattr -cr" dmgApplication.installPhase;
              assert nixpkgs.lib.hasInfix "$out/libexec/tool" dmgCliApplication.installPhase;
              assert nixpkgs.lib.hasInfix "Tool CLI.app/Contents" dmgCliApplication.installPhase;
              assert !nixpkgs.lib.hasInfix "$out/Applications" dmgCliApplication.installPhase;
              assert !pkgs.stdenv.hostPlatform.isDarwin
                || nixpkgs.lib.hasInfix "/usr/bin/xattr -cr" dmgCliApplication.installPhase;
              assert !pkgs.stdenv.hostPlatform.isLinux
                || builtins.elem pkgs.stdenv.cc.cc.lib dynamicLinkerExecutable.buildInputs;
              assert !pkgs.stdenv.hostPlatform.isLinux
                || nixpkgs.lib.hasInfix "--library-path"
                  dynamicLinkerExecutable.installPhase;
              assert !pkgs.stdenv.hostPlatform.isLinux
                || nixpkgs.lib.hasInfix "$out/libexec/bin/tool"
                  dynamicLinkerExecutable.installPhase;
              assert !pkgs.stdenv.hostPlatform.isLinux
                || builtins.elem pkgs.stdenv.cc.cc.lib dynamicLinkerCopyTree.buildInputs;
              assert !pkgs.stdenv.hostPlatform.isLinux
                || nixpkgs.lib.hasInfix
                  ''mv "$out/share/tool/libexec/tool" "$out/.home-weave-dynamic/share/tool/libexec/tool"''
                  dynamicLinkerCopyTree.installPhase;
              assert !pkgs.stdenv.hostPlatform.isLinux
                || nixpkgs.lib.hasInfix
                  ''"$out/.home-weave-dynamic/share/tool/libexec/tool" "\$@"''
                  dynamicLinkerCopyTree.installPhase;
              pkgs.runCommand "declarative-package-policy" { nativeBuildInputs = [ pkgs.check-jsonschema ]; } ''
                check-jsonschema --schemafile ${./schemas/declarative-packages-v1.schema.json} \
                  ${./tests/fixtures/declarative-packages.json}
                ${nixpkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
                  touch xattr-fixture
                  /usr/bin/xattr -w org.homeweave.test value xattr-fixture
                  /usr/bin/xattr -c xattr-fixture
                  test -z "$(/usr/bin/xattr xattr-fixture)"
                ''}
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

      darwinModules = {
        default = import ./modules/darwin;
        base = import ./modules/darwin;
      };

      lib.dotfiles.path = ./dotfiles;
      lib.profileConfig = profileConfig;
      lib.profileConfigSchema = ./schemas/home-weave-v4.schema.json;
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
        plugins = publicPlugins;
        sourcesBySystem = nixpkgs.lib.genAttrs
          [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ]
          (system: {
            nixpkgs = if system == "x86_64-darwin"
              then inputs.nixpkgs-x86-darwin
              else inputs.nixpkgs;
          });
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
