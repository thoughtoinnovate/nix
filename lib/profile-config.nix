{ lib }:

let
  packageName = entry:
    if builtins.isString entry then
      entry
    else if builtins.isAttrs entry && entry ? name && builtins.isString entry.name then
      entry.name
    else
      throw "HomeWeave Nix package entries must be strings or { name, allowUnfree? } objects";

  packageAllowsUnfree = entry:
    builtins.isAttrs entry && (entry.allowUnfree or false);

  packageUnfreeName = entry:
    if builtins.isAttrs entry && entry ? unfreeName then entry.unfreeName else packageName entry;

  strictRemove = profile: category: inherited: removals:
    let
      missing = builtins.filter (item: !(builtins.elem item inherited)) removals;
    in
    if missing != [ ] then
      throw "HomeWeave profile ${profile} excludes non-inherited ${category}: ${lib.concatStringsSep ", " missing}"
    else
      builtins.filter (item: !(builtins.elem item removals)) inherited;

  strictRemoveProviders = profile: inherited: removals:
    let
      providerNames = builtins.attrNames removals;
      unknownProviders = builtins.filter (name: !(builtins.hasAttr name inherited)) providerNames;
      removeOne = name:
        strictRemove profile "provider package(s) for ${name}" (inherited.${name} or [ ]) (removals.${name} or [ ]);
    in
    if unknownProviders != [ ] then
      throw "HomeWeave profile ${profile} excludes package(s) from non-inherited provider(s): ${lib.concatStringsSep ", " unknownProviders}"
    else
      lib.filterAttrs (_: values: values != [ ]) (
        lib.mapAttrs (name: _: removeOne name) inherited
      );

  mergeProviders = parent: current:
    let
      names = lib.unique (builtins.attrNames parent ++ builtins.attrNames current);
    in
    lib.genAttrs names (
      name: lib.unique ((parent.${name} or [ ]) ++ (current.${name} or [ ]))
    );

  emptyProfile = {
    extends = null;
    shells = [ "zsh" ];
    primaryShell = "zsh";
    packageGroups = [ ];
    nixPackages = [ ];
    providerPackages = { };
    plugins = { };
    pluginContributions = { };
    homebrewFormulae = [ ];
    homebrewCasks = [ ];
    allowUnfree = [ ];
    development = false;
    environment = {
      variables = { };
      requiredSecrets = [ ];
    };
    dotfiles = [ ];
    dotfileLayers = [ ];
    packageOrigins = { };
    nativePackages = {
      homebrewFormulae = [ ];
      homebrewCasks = [ ];
      apt = [ ];
      pacman = [ ];
    };
  };
in
{
  schemaVersion = 4;

  resolve =
    {
      config,
      sourceRoot,
      sourceName,
      system,
      parentProfiles ? { },
      packageCatalog ? { groups = { }; },
      pluginRegistry ? { },
    }:
    let
      checkedConfig =
        if (config.schemaVersion or null) != 4 then
          throw "HomeWeave configuration requires schemaVersion 4"
        else if !(config ? profiles) || !builtins.isAttrs config.profiles then
          throw "HomeWeave configuration requires a profiles object"
        else
          config;

      rawProfiles = checkedConfig.profiles;
      isDarwin = lib.hasSuffix "-darwin" system;

      resolveProfile =
        seen: name:
        if builtins.elem name seen then
          throw "HomeWeave profile inheritance cycle: ${lib.concatStringsSep " -> " (seen ++ [ name ])}"
        else if builtins.hasAttr name rawProfiles then
          let
            current = rawProfiles.${name};
            hasExtends = current ? extends;
            parentName = if hasExtends then current.extends else throw "HomeWeave profile ${name} must declare extends (use null for a standalone profile)";
            parent =
              if parentName == null then
                emptyProfile
              else if parentName == name && builtins.hasAttr parentName parentProfiles then
                parentProfiles.${parentName}
              else if builtins.hasAttr parentName rawProfiles then
                resolveProfile (seen ++ [ name ]) parentName
              else if builtins.hasAttr parentName parentProfiles then
                parentProfiles.${parentName}
              else
                throw "HomeWeave profile does not exist: ${toString parentName}";

            parentPluginNix = lib.unique (lib.concatMap
              (contribution: contribution.nixPackages or [ ])
              (builtins.attrValues (parent.pluginContributions or { })));
            parentPluginUnfree = lib.unique (lib.concatMap
              (contribution: contribution.allowUnfree or [ ])
              (builtins.attrValues (parent.pluginContributions or { })));
            parentAllowUnfreeWithoutPlugins = builtins.filter
              (package: !(builtins.elem package parentPluginUnfree)) parent.allowUnfree;
            hasNonPluginOrigin = package:
              lib.any (origin: !(lib.hasPrefix "plugin:" origin))
                (parent.packageOrigins.${package} or [ ]);
            parentNixWithoutPlugins = builtins.filter
              (package: !(builtins.elem package parentPluginNix) || hasNonPluginOrigin package)
              parent.nixPackages;
            subtractProviderContributions = providers: contributions:
              lib.foldl' (result: contribution:
                let contributed = contribution.providerPackages or { };
                in lib.mapAttrs
                  (provider: values: builtins.filter
                    (value: !(builtins.elem value (contributed.${provider} or [ ]))) values)
                  result
              ) providers (builtins.attrValues contributions);
            parentProvidersWithoutPlugins = lib.filterAttrs (_: values: values != [ ])
              (subtractProviderContributions parent.providerPackages (parent.pluginContributions or { }));

            exclude = current.exclude or { };
            excludePackages = exclude.packages or { };
            excludeHomebrew = excludePackages.homebrew or { };
            excludedGroups = exclude.packageGroups or [ ];
            inheritedGroups = strictRemove name "package group(s)" parent.packageGroups excludedGroups;

            groupPackages = group:
              if builtins.hasAttr group (packageCatalog.groups or { }) then
                packageCatalog.groups.${group}
              else
                throw "HomeWeave profile ${name} selects unknown package group: ${group}";
            removedGroupPackages = lib.unique (lib.concatMap groupPackages excludedGroups);
            packagesStillProvidedByGroups = lib.unique (lib.concatMap groupPackages inheritedGroups);
            inheritedAfterGroupRemoval = builtins.filter (
              package: !(builtins.elem package removedGroupPackages) || builtins.elem package packagesStillProvidedByGroups
            ) parentNixWithoutPlugins;
            inheritedNixPackages = strictRemove name "Nix package(s)" inheritedAfterGroupRemoval (excludePackages.nix or [ ]);

            commonPackages = (current.packages or { }).nix or [ ];
            platform =
              if isDarwin then
                (current.platforms or { }).macos or { }
              else
                (current.platforms or { }).linux or { };
            platformPackages = platform.packages or { };
            selectedNixEntries = commonPackages ++ (platformPackages.nix or [ ]);
            selectedNixPackages = map packageName selectedNixEntries;
            selectedGroups = current.packageGroups or [ ];
            selectedGroupPackages = lib.unique (lib.concatMap groupPackages selectedGroups);
            selectedUnfree = map packageUnfreeName (builtins.filter packageAllowsUnfree selectedNixEntries);
            selectedProviders = { };
            selectedHomebrew = platformPackages.homebrew or { };

            inheritedProviders = parentProvidersWithoutPlugins;
            inheritedFormulae = strictRemove name "Homebrew formula(e)" parent.homebrewFormulae (excludeHomebrew.formulae or [ ]);
            inheritedCasks = strictRemove name "Homebrew cask(s)" parent.homebrewCasks (excludeHomebrew.casks or [ ]);

            additions = current.dotfiles or [ ];
            removals = exclude.dotfiles or [ ];
            inheritedAfterRemoval = strictRemove name "dotfile component(s)" parent.dotfiles removals;
            duplicates = lib.intersectLists inheritedAfterRemoval additions;
            checkedAdditions =
              if duplicates != [ ] then
                throw "HomeWeave profile ${name} redefines inherited dotfile component(s) without excluding them: ${lib.concatStringsSep ", " duplicates}"
              else
                additions;
            filteredParentLayers = builtins.filter (layer: layer.packages != [ ]) (
              map
                (layer: layer // {
                  packages = builtins.filter (component: !(builtins.elem component removals)) layer.packages;
                })
                parent.dotfileLayers
            );
            localLayer = lib.optional (checkedAdditions != [ ]) {
              name = "${sourceName}--${name}";
              source = { kind = "nix"; path = "${toString sourceRoot}/dotfiles"; };
              packages = map (component: if component == "shells" then "@shells" else component) checkedAdditions;
            };

            currentEnvironment = current.environment or { };
            linuxDistributions = if isDarwin then { } else (platform.distributions or { });
            distroPackages = distro: ((linuxDistributions.${distro} or { }).packages or { });
            selectedApt = (platformPackages.apt or [ ])
              ++ ((distroPackages "debian").apt or [ ])
              ++ ((distroPackages "ubuntu").apt or [ ]);
            selectedPacman = (platformPackages.pacman or [ ])
              ++ ((distroPackages "arch").pacman or [ ]);
            inheritedApt = strictRemove name "APT package(s)" parent.nativePackages.apt (excludePackages.apt or [ ]);
            inheritedPacman = strictRemove name "Pacman package(s)" parent.nativePackages.pacman (excludePackages.pacman or [ ]);

            commonPlugins = current.plugins or { };
            platformPlugins = platform.plugins or { };
            duplicatePluginSelections = lib.intersectLists
              (builtins.attrNames commonPlugins) (builtins.attrNames platformPlugins);
            checkedPluginSelections =
              if duplicatePluginSelections != [ ] then
                throw "HomeWeave profile ${name} selects plugin(s) in both common and platform configuration: ${lib.concatStringsSep ", " duplicatePluginSelections}"
              else commonPlugins // platformPlugins;
            excludedPlugins = exclude.plugins or [ ];
            missingExcludedPlugins = builtins.filter
              (plugin: !(builtins.hasAttr plugin (parent.plugins or { }))) excludedPlugins;
            inheritedPlugins =
              if missingExcludedPlugins != [ ] then
                throw "HomeWeave profile ${name} excludes non-inherited plugin(s): ${lib.concatStringsSep ", " missingExcludedPlugins}"
              else lib.filterAttrs (plugin: _: !(builtins.elem plugin excludedPlugins)) (parent.plugins or { });
            mergedPlugins = inheritedPlugins // checkedPluginSelections;
            enabledPlugins = lib.filterAttrs (_: selection: selection.enabled or false) mergedPlugins;
            unknownPlugins = builtins.filter
              (plugin: !(builtins.hasAttr plugin pluginRegistry)) (builtins.attrNames enabledPlugins);
            pluginContributions =
              if unknownPlugins != [ ] then
                throw "HomeWeave profile ${name} selects unavailable plugin(s): ${lib.concatStringsSep ", " unknownPlugins}"
              else lib.mapAttrs (plugin: selection:
                let
                  descriptor = pluginRegistry.${plugin};
                  supported = descriptor.platforms or [ ];
                  lifecycle = descriptor.lifecycle or { packages = "remove"; state = "remove"; };
                  contribution = descriptor.resolve {
                    inherit system selection;
                    profileName = name;
                  };
                in
                if (descriptor.schemaVersion or null) != 1 then
                  throw "HomeWeave plugin ${plugin} has an unsupported descriptor schema"
                else if !(builtins.elem system supported) then
                  throw "HomeWeave plugin ${plugin} does not support ${system}"
                else if !(builtins.elem (lifecycle.packages or "") [ "remove" "retain" ])
                  || !(builtins.elem (lifecycle.state or "") [ "remove" "retain" ]) then
                  throw "HomeWeave plugin ${plugin} has an invalid lifecycle policy"
                else contribution // {
                  inherit lifecycle;
                  nixPackages = contribution.nixPackages or [ ];
                  allowUnfree = contribution.allowUnfree or [ ];
                  providerPackages = contribution.providerPackages or { };
                  statePaths = contribution.statePaths or [ ];
                  packageEnvironment = contribution.packageEnvironment or { };
                }
              ) enabledPlugins;
            pluginNixPackages = lib.unique (lib.concatMap
              (contribution: contribution.nixPackages)
              (builtins.attrValues pluginContributions));
            pluginAllowUnfree = lib.unique (lib.concatMap
              (contribution: contribution.allowUnfree)
              (builtins.attrValues pluginContributions));
            pluginProviderPackages = lib.foldl' mergeProviders { }
              (map (contribution: contribution.providerPackages)
                (builtins.attrValues pluginContributions));
            pluginEnvironmentVariables = lib.foldl' (result: contribution:
              result // (contribution.environmentVariables or { })) { }
              (builtins.attrValues pluginContributions);

            nonPluginNixPackages = lib.unique (inheritedNixPackages ++ selectedNixPackages ++ selectedGroupPackages);
            finalNixPackages = lib.unique (nonPluginNixPackages ++ pluginNixPackages);
            excludedNix = lib.unique ((excludePackages.nix or [ ]) ++ removedGroupPackages);
            finalAllowUnfree = builtins.filter (
              unfree: builtins.elem unfree finalNixPackages || !(builtins.elem unfree excludedNix)
            ) (lib.unique (parentAllowUnfreeWithoutPlugins ++ (current.allowUnfree or [ ]) ++ selectedUnfree ++ pluginAllowUnfree));

            inheritedOrigins = lib.filterAttrs (package: _: builtins.elem package inheritedNixPackages) parent.packageOrigins;
            explicitOrigins = lib.genAttrs selectedNixPackages (_: [ "profile:${name}" ]);
            groupOrigins = lib.foldl' (origins: group:
              lib.foldl' (result: package:
                result // { ${package} = lib.unique ((result.${package} or [ ]) ++ [ "group:${group}" ]); }
              ) origins (groupPackages group)
            ) { } selectedGroups;
            pluginOrigins = lib.foldl' (origins: plugin:
              lib.foldl' (result: package:
                result // { ${package} = lib.unique ((result.${package} or [ ]) ++ [ "plugin:${plugin}" ]); }
              ) origins pluginContributions.${plugin}.nixPackages
            ) { } (builtins.attrNames pluginContributions);
            packageOrigins = lib.foldl' (result: package:
              result // {
                ${package} = lib.unique (
                  (inheritedOrigins.${package} or [ ])
                  ++ (explicitOrigins.${package} or [ ])
                  ++ (groupOrigins.${package} or [ ])
                  ++ (pluginOrigins.${package} or [ ])
                );
              }
            ) { } finalNixPackages;
          in
          parent // current // {
            inherit parentName packageOrigins;
            extends = parentName;
            shells = current.shells or parent.shells;
            primaryShell = current.primaryShell or parent.primaryShell;
            packageGroups = lib.unique (inheritedGroups ++ selectedGroups);
            nixPackages = finalNixPackages;
            allowUnfree = finalAllowUnfree;
            plugins = enabledPlugins;
            inherit pluginContributions;
            providerPackages = mergeProviders
              (mergeProviders inheritedProviders selectedProviders)
              pluginProviderPackages;
            homebrewFormulae = lib.unique (inheritedFormulae ++ (selectedHomebrew.formulae or [ ]));
            homebrewCasks = lib.unique (inheritedCasks ++ (selectedHomebrew.casks or [ ]));
            development = parent.development || name == "development" || (current.development or false);
            environment = {
              variables = parent.environment.variables // (currentEnvironment.variables or { })
                // pluginEnvironmentVariables;
              requiredSecrets = lib.unique (parent.environment.requiredSecrets ++ (currentEnvironment.requiredSecrets or [ ]));
            };
            dotfiles = lib.unique (inheritedAfterRemoval ++ checkedAdditions);
            dotfileLayers = filteredParentLayers ++ localLayer;
            nativePackages = {
              homebrewFormulae = lib.unique (inheritedFormulae ++ (selectedHomebrew.formulae or [ ]));
              homebrewCasks = lib.unique (inheritedCasks ++ (selectedHomebrew.casks or [ ]));
              apt = lib.unique (inheritedApt ++ selectedApt);
              pacman = lib.unique (inheritedPacman ++ selectedPacman);
            };
          }
        else if builtins.hasAttr name parentProfiles then
          parentProfiles.${name}
        else
          throw "HomeWeave profile does not exist: ${name}";

      profileNames = lib.unique (builtins.attrNames parentProfiles ++ builtins.attrNames rawProfiles);
      profiles = lib.genAttrs profileNames (resolveProfile [ ]);
    in
    {
      inherit profiles;
      defaults = checkedConfig.defaults or { profile = "base"; };
      dotfiles.profiles = lib.mapAttrs (_: profile: { layers = profile.dotfileLayers; }) profiles;
    };
}
