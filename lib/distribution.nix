{
  lib,
  core,
  nixpkgs,
  nixpkgs-x86-darwin,
  home-manager,
  home-manager-x86-darwin,
  profileConfig,
  profileConfigSchema,
  publicPackageCatalog,
  declarativePackages,
  declarativePackageSchema,
  mkHomeWeaveApp,
}:

{
  self,
  parent ? core,
  configPath,
  sourceRoot ? self.outPath,
  profileOverlay ? sourceRoot,
  distributionUrl ? "path:${self.outPath}",
  systems ? [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ],
  defaultShell ? null,
  localOverlays ? [ ],
  inheritParentOverlay ? true,
  packageDefinitions ? null,
  packageGroups ? { },
  extensionsForSystem ? (_system: _pkgs: [ ]),
  extraPackagesForSystem ? (_system: _pkgs: { }),
  extraChecksForSystem ? (_system: _pkgs: { }),
}:
let
  manifest = builtins.fromJSON (builtins.readFile configPath);
  distributionName = manifest.distribution.name;
  inheritedPackageCatalog = parent.lib.packageCatalog or publicPackageCatalog;
  mergedPackageCatalog = inheritedPackageCatalog // {
    groups = (inheritedPackageCatalog.groups or { }) // packageGroups;
  };
  declarativeOverlay = lib.optional (packageDefinitions != null) (
    declarativePackages.mkOverlay {
      catalog = builtins.fromJSON (builtins.readFile packageDefinitions);
      inherit sourceRoot;
    }
  );
  declarativeCatalog = if packageDefinitions == null then { packages = { }; }
    else builtins.fromJSON (builtins.readFile packageDefinitions);
  declarativeUnfreeNames = lib.unique (lib.concatMap (name:
    let spec = declarativeCatalog.packages.${name};
    in lib.optional (spec.allowUnfree or false) (spec.unfreeName or spec.attr or name)
  ) (builtins.attrNames (declarativeCatalog.packages or { })));
  effectiveLocalOverlays = declarativeOverlay ++ localOverlays;
  localOverlay = lib.composeManyExtensions effectiveLocalOverlays;
  parentProfilesFor = system:
    if parent ? lib && parent.lib ? setup && parent.lib.setup ? profilesBySystem
      && builtins.hasAttr system parent.lib.setup.profilesBySystem
    then parent.lib.setup.profilesBySystem.${system}
    else { };
  resolvedBySystem = lib.genAttrs systems (system: profileConfig.resolve {
    config = manifest;
    inherit sourceRoot system;
    sourceName = distributionName;
    parentProfiles = parentProfilesFor system;
    packageCatalog = mergedPackageCatalog;
  });
  representativeSystem = if builtins.elem "x86_64-linux" systems then "x86_64-linux" else builtins.head systems;
  resolved = resolvedBySystem.${representativeSystem};
  packageSourceFor = system: if system == "x86_64-darwin" then nixpkgs-x86-darwin else nixpkgs;
  appPkgsFor = system: import (packageSourceFor system) {
    inherit system;
    overlays = [ core.overlays.base ] ++ effectiveLocalOverlays;
    config.allowUnfreePredicate = package:
      builtins.elem (lib.getName package) declarativeUnfreeNames;
    config.allowUnsupportedSystem = true;
  };
  activationPkgsFor = system: profile:
    import (packageSourceFor system) {
      inherit system;
      overlays = [ core.overlays.darwin-cache core.overlays.base core.overlays.development ]
        ++ lib.optional (inheritParentOverlay && parent ? overlays && parent.overlays ? default) parent.overlays.default
        ++ effectiveLocalOverlays;
      config.allowUnfreePredicate = package:
        builtins.elem (lib.getName package) profile.allowUnfree;
      config.allowUnsupportedSystem = true;
    };
  inheritedExtensionsFor = system:
    if parent ? lib && parent.lib ? homeWeave && parent.lib.homeWeave ? extensionsBySystem
    then parent.lib.homeWeave.extensionsBySystem.${system} or [ ]
    else [ ];
  localExtensionsBySystem = lib.genAttrs systems (system:
    extensionsForSystem system (appPkgsFor system));
  extensionsBySystem = lib.genAttrs systems (system:
    let
      combined = inheritedExtensionsFor system ++ localExtensionsBySystem.${system};
      names = map (extension: extension.name) combined;
    in
    if lib.length names != lib.length (lib.unique names) then
      throw "HomeWeave distribution ${distributionName} registers a duplicate provider name"
    else
      combined);
  profileModuleFor = system: name:
    { lib, pkgs, ... }:
    let
      profile = resolvedBySystem.${system}.profiles.${name};
      packageEnvironment = lib.foldl' (result: packageName:
        let specification = (declarativeCatalog.packages or { }).${packageName} or { };
        in result // lib.mapAttrs (_: reference:
          let package = lib.attrByPath (lib.splitString "." reference.package)
            (throw "Environment package is unavailable: ${reference.package}") pkgs;
          in "${package}/${reference.path or ""}"
        ) (specification.environment or { })
      ) { } profile.nixPackages;
    in {
      imports = lib.optional (builtins.pathExists (sourceRoot + "/home.nix")) (sourceRoot + "/home.nix");
      homeWeave.base = {
        enable = true;
        shells = profile.shells;
        packageNames = profile.nixPackages;
        packageGroups = [ ];
      };
      homeWeave.development = {
        enable = profile.development;
        includeDefaultPackages = false;
      };
      home.sessionVariables = packageEnvironment // profile.environment.variables;
    };
  profileModulesBySystem = lib.genAttrs systems (system: {
    profiles = lib.genAttrs (builtins.attrNames resolvedBySystem.${system}.profiles) (profileModuleFor system);
  });
  apps = lib.genAttrs systems (system:
    let packageSource = packageSourceFor system;
    in {
      home-weave = mkHomeWeaveApp {
        inherit system packageSource profileOverlay;
        extensions = extensionsBySystem.${system};
        inherit distributionName;
        baseUrl = distributionUrl;
      };
      setup = core.apps.${system}.setup;
      default = self.apps.${system}.home-weave;
    });
  localPackages = lib.genAttrs systems (system:
    let pkgs = appPkgsFor system;
    in lib.genAttrs (builtins.attrNames (declarativeCatalog.packages or { }))
      (name: lib.attrByPath (lib.splitString "." name)
        (throw "Declarative package output is unavailable: ${name}") pkgs)
      // extraPackagesForSystem system pkgs);
  checks = lib.genAttrs systems (system:
    let
      pkgs = appPkgsFor system;
      selectedHomeManager = if system == "x86_64-darwin" then home-manager-x86-darwin else home-manager;
      profileDerivations = map (name:
        let
          profile = resolvedBySystem.${system}.profiles.${name};
          activationPkgs = activationPkgsFor system profile;
          evaluated = selectedHomeManager.lib.homeManagerConfiguration {
            pkgs = activationPkgs;
            modules = [
              core.homeModules.default
              profileModulesBySystem.${system}.profiles.${name}
              {
                home = {
                  username = "home-weave-test";
                  homeDirectory = "/var/empty/home-weave-test";
                  stateVersion = "26.05";
                };
                programs.home-manager.enable = true;
              }
            ];
          };
        in evaluated.activationPackage.drvPath
      ) (builtins.attrNames resolvedBySystem.${system}.profiles);
      evaluationCheck = builtins.deepSeq profileDerivations (pkgs.runCommand "home-weave-profile-evaluation" { } ''
        touch $out
      '');
    in {
      profile-evaluation = evaluationCheck;
      configuration-schema = pkgs.runCommand "home-weave-configuration-schema" {
        nativeBuildInputs = [ pkgs.check-jsonschema ];
      } ''
        check-jsonschema --schemafile ${profileConfigSchema} ${configPath}
        ${lib.optionalString (packageDefinitions != null) ''
          check-jsonschema --schemafile ${declarativePackageSchema} ${packageDefinitions}
        ''}
        touch $out
      '';
    } // extraChecksForSystem system pkgs);
in
{
  overlays = (parent.overlays or core.overlays) // { default = localOverlay; };
  homeModules = (parent.homeModules or core.homeModules) // {
    profiles = profileModulesBySystem.${representativeSystem}.profiles;
  };
  darwinModules = parent.darwinModules or core.darwinModules;
  inherit apps checks;
  packages = localPackages;
  lib = parent.lib // {
    packageCatalog = mergedPackageCatalog;
    setup = {
      schemaVersion = 5;
      namespace = "home-weave";
      defaults = resolved.defaults // {
        shell = if defaultShell != null then defaultShell else
          resolved.profiles.${resolved.defaults.profile}.primaryShell;
      };
      profiles = resolved.profiles;
      dotfiles = resolved.dotfiles;
      profilesBySystem = lib.mapAttrs (_: value: value.profiles) resolvedBySystem;
      dotfilesBySystem = lib.mapAttrs (_: value: value.dotfiles) resolvedBySystem;
      inherit profileModulesBySystem;
    };
    homeWeave = (parent.lib.homeWeave or { }) // {
      schemaVersion = 1;
      inherit distributionName extensionsBySystem;
    };
  };
}
