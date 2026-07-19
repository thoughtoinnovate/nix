{
  lib,
  core,
  nixpkgs,
  nixpkgs-x86-darwin,
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
  plugins ? [ ],
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
  parentPluginRegistry = parent.lib.homeWeave.plugins or { };
  localPluginNames = map (plugin: plugin.name) plugins;
  duplicateLocalPlugins = lib.length localPluginNames != lib.length (lib.unique localPluginNames);
  localPluginRegistry = lib.listToAttrs (map (plugin: {
    name = plugin.name;
    value = plugin;
  }) plugins);
  inheritedPluginConflicts = lib.intersectLists
    (builtins.attrNames parentPluginRegistry) localPluginNames;
  pluginRegistry =
    if duplicateLocalPlugins then
      throw "HomeWeave distribution ${distributionName} registers a duplicate local plugin name"
    else if inheritedPluginConflicts != [ ] then
      throw "HomeWeave distribution ${distributionName} replaces inherited plugin(s): ${lib.concatStringsSep ", " inheritedPluginConflicts}"
    else parentPluginRegistry // localPluginRegistry;
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
  pluginOverlays = lib.concatMap (plugin: lib.optional (plugin ? overlay) plugin.overlay) plugins;
  effectiveLocalOverlays = declarativeOverlay ++ pluginOverlays ++ localOverlays;
  # Consumers import a distribution's exported default overlay when creating
  # their package set. A child distribution must therefore export
  # the same parent + child overlay composition used by its internal activation
  # checks; exporting only the child overlay makes inherited declarative package
  # names resolve in profile metadata but disappear during real activation.
  activationOverlays =
    lib.optional (inheritParentOverlay && parent ? overlays && parent.overlays ? default)
      parent.overlays.default
    ++ effectiveLocalOverlays;
  activationOverlay = lib.composeManyExtensions activationOverlays;
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
      inherit pluginRegistry;
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
        ++ activationOverlays;
      config.allowUnfreePredicate = package:
        builtins.elem (lib.getName package) profile.allowUnfree;
      config.allowUnsupportedSystem = true;
    };
  inheritedExtensionsFor = system:
    if parent ? lib && parent.lib ? homeWeave && parent.lib.homeWeave ? extensionsBySystem
    then parent.lib.homeWeave.extensionsBySystem.${system} or [ ]
    else [ ];
  localExtensionsBySystem = lib.genAttrs systems (system:
    let pkgs = appPkgsFor system;
    in extensionsForSystem system pkgs
      ++ lib.concatMap (plugin:
        if plugin ? extensionsForSystem && builtins.elem system (plugin.platforms or [ ])
        then plugin.extensionsForSystem system pkgs
        else [ ]) plugins);
  extensionsBySystem = lib.genAttrs systems (system:
    let
      combined = inheritedExtensionsFor system ++ localExtensionsBySystem.${system};
      names = map (extension: extension.name) combined;
    in
    if lib.length names != lib.length (lib.unique names) then
      throw "HomeWeave distribution ${distributionName} registers a duplicate provider name"
    else
      combined);
  apps = lib.genAttrs systems (system:
    let packageSource = packageSourceFor system;
    in {
      home-weave = mkHomeWeaveApp {
        inherit system packageSource profileOverlay;
        plugins = pluginRegistry;
        extensions = extensionsBySystem.${system};
        inherit distributionName;
        baseUrl = distributionUrl;
      };
      setup = core.apps.${system}.setup;
      default = self.apps.${system}.home-weave;
    });
  localPackages = lib.genAttrs systems (system:
    let
      pkgs = appPkgsFor system;
      environments = lib.mapAttrs (name: profile:
        let activationPkgs = activationPkgsFor system profile;
        in activationPkgs.buildEnv {
          name = "home-weave-${name}-environment";
          paths = map (packageName:
            lib.attrByPath (lib.splitString "." packageName)
              (throw "HomeWeave package is unavailable: ${packageName}") activationPkgs
          ) profile.nixPackages
          ++ map (shell: activationPkgs.shellPackages.${shell}) profile.shells;
        }
      ) resolvedBySystem.${system}.profiles;
      environmentOutputs = lib.mapAttrs' (name: environment:
        lib.nameValuePair "home-weave-environment-${name}" environment
      ) environments;
      defaultEnvironment = environments.${resolvedBySystem.${system}.defaults.profile};
    in lib.genAttrs (builtins.attrNames (declarativeCatalog.packages or { }))
      (name: lib.attrByPath (lib.splitString "." name)
        (throw "Declarative package output is unavailable: ${name}") pkgs)
      // extraPackagesForSystem system pkgs
      // environmentOutputs
      // { home-weave-environment = defaultEnvironment; });
  checks = lib.genAttrs systems (system:
    let
      packageSource = packageSourceFor system;
      pkgs = appPkgsFor system;
      profileDerivations = map (name:
        self.packages.${system}."home-weave-environment-${name}".drvPath
      ) (builtins.attrNames resolvedBySystem.${system}.profiles);
      evaluationCheck = builtins.deepSeq profileDerivations (pkgs.runCommand "home-weave-profile-evaluation" { } ''
        touch $out
      '');
      # Generated consumer flakes import the distribution's exported default
      # overlay rather than calling activationPkgsFor. Resolve every declared
      # package through that public interface so inherited-overlay regressions
      # fail `flake check` before reaching a user's machine.
      consumerPackages = import packageSource {
        inherit system;
        overlays = [ core.overlays.darwin-cache core.overlays.base core.overlays.development
          self.overlays.default ];
        config.allowUnfreePredicate = package:
          lib.any (profile: builtins.elem (lib.getName package) profile.allowUnfree)
            (builtins.attrValues resolvedBySystem.${system}.profiles);
        config.allowUnsupportedSystem = true;
      };
      consumerPackagePaths = lib.concatMap (profile:
        map (name: toString (lib.attrByPath (lib.splitString "." name)
          (throw "Exported HomeWeave overlay is missing package: ${name}")
          consumerPackages)) profile.nixPackages
      ) (builtins.attrValues resolvedBySystem.${system}.profiles);
      consumerOverlayCheck = builtins.deepSeq consumerPackagePaths
        (pkgs.runCommand "home-weave-consumer-overlay-evaluation" { } ''
          touch $out
        '');
    in {
      profile-evaluation = evaluationCheck;
      consumer-overlay-evaluation = consumerOverlayCheck;
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
  overlays = (parent.overlays or core.overlays) // { default = activationOverlay; };
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
    };
    homeWeave = (parent.lib.homeWeave or { }) // {
      schemaVersion = 1;
      inherit distributionName extensionsBySystem;
      plugins = pluginRegistry;
    };
  };
}
