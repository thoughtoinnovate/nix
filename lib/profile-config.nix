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
    nativePackages = {
      homebrewFormulae = [ ];
      apt = [ ];
      pacman = [ ];
    };
  };
in
{
  schemaVersion = 2;

  resolve =
    {
      config,
      sourceRoot,
      sourceName,
      system,
      parentProfiles ? { },
    }:
    let
      checkedConfig =
        if (config.schemaVersion or null) != 2 then
          throw "HomeWeave configuration requires schemaVersion 2"
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
            parentName = current.extends or null;
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
                throw "HomeWeave profile does not exist: ${parentName}";

            commonPackages = (current.packages or { }).nix or [ ];
            platform =
              if isDarwin then
                (current.platforms or { }).macos or { }
              else
                (current.platforms or { }).linux or { };
            platformPackages = (platform.packages or { });
            selectedNixEntries = commonPackages ++ (platformPackages.nix or [ ]);
            selectedNixPackages = map packageName selectedNixEntries;
            selectedUnfree = map packageUnfreeName (builtins.filter packageAllowsUnfree selectedNixEntries);
            selectedProviders = platformPackages.providers or { };
            selectedHomebrew = platformPackages.homebrew or { };

            additions = current.dotfiles or [ ];
            removals = current.dotfilesRemove or [ ];
            inheritedAfterRemoval = builtins.filter (
              component: !(builtins.elem component removals)
            ) parent.dotfiles;
            duplicates = lib.intersectLists inheritedAfterRemoval additions;
            checkedAdditions =
              if duplicates != [ ] then
                throw "HomeWeave profile ${name} redefines inherited dotfile component(s): ${lib.concatStringsSep ", " duplicates}"
              else
                additions;
            filteredParentLayers = builtins.filter (layer: layer.packages != [ ]) (
              map
                (layer: layer // {
                  packages = builtins.filter (
                    component: !(builtins.elem component removals)
                  ) layer.packages;
                })
                parent.dotfileLayers
            );
            localLayer = lib.optional (checkedAdditions != [ ]) {
              name = "${sourceName}:${name}";
              source = {
                kind = "nix";
                path = "${toString sourceRoot}/dotfiles";
              };
              packages = map (
                component: if component == "shells" then "@shells" else component
              ) checkedAdditions;
            };
            currentEnvironment = current.environment or { };
            linuxDistributions = if isDarwin then { } else (platform.distributions or { });
            distroPackages = distro:
              ((linuxDistributions.${distro} or { }).packages or { });
          in
          parent
          // current
          // {
            inherit parentName;
            extends = parentName;
            shells = current.shells or parent.shells;
            primaryShell = current.primaryShell or parent.primaryShell;
            packageGroups = lib.unique (parent.packageGroups ++ (current.packageGroups or [ ]));
            nixPackages = lib.unique (parent.nixPackages ++ selectedNixPackages);
            allowUnfree = lib.unique (
              parent.allowUnfree ++ (current.allowUnfree or [ ]) ++ selectedUnfree
            );
            providerPackages = mergeProviders parent.providerPackages selectedProviders;
            homebrewFormulae = lib.unique (
              parent.homebrewFormulae ++ (selectedHomebrew.formulae or [ ])
            );
            homebrewCasks = lib.unique (
              parent.homebrewCasks ++ (selectedHomebrew.casks or [ ])
            );
            development =
              parent.development || name == "development" || (current.development or false);
            environment = {
              variables = parent.environment.variables // (currentEnvironment.variables or { });
              requiredSecrets = lib.unique (
                parent.environment.requiredSecrets ++ (currentEnvironment.requiredSecrets or [ ])
              );
            };
            dotfiles = lib.unique (inheritedAfterRemoval ++ checkedAdditions);
            dotfileLayers = filteredParentLayers ++ localLayer;
            nativePackages = {
              homebrewFormulae = lib.unique (
                parent.nativePackages.homebrewFormulae ++ (selectedHomebrew.formulae or [ ])
              );
              apt = lib.unique (
                parent.nativePackages.apt ++ (platformPackages.apt or [ ])
                ++ ((distroPackages "debian").apt or [ ])
                ++ ((distroPackages "ubuntu").apt or [ ])
              );
              pacman = lib.unique (
                parent.nativePackages.pacman ++ (platformPackages.pacman or [ ])
                ++ ((distroPackages "arch").pacman or [ ])
              );
            };
          }
        else if builtins.hasAttr name parentProfiles then
          parentProfiles.${name}
        else
          throw "HomeWeave profile does not exist: ${name}";

      profileNames = lib.unique (
        builtins.attrNames parentProfiles ++ builtins.attrNames rawProfiles
      );
      profiles = lib.genAttrs profileNames (resolveProfile [ ]);
    in
    {
      inherit profiles;
      defaults = checkedConfig.defaults or {
        profile = "base";
      };
      dotfiles = {
        profiles = lib.mapAttrs (_: profile: { layers = profile.dotfileLayers; }) profiles;
      };
    };
}
