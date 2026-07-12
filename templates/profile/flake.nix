{
  description = "Personal configuration built with HomeWeave";

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";

    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs =
    {
      self,
      nix-base,
      nixpkgs,
      ...
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      profileEntries = builtins.readDir ./nix;
      profileNames = builtins.filter (
        name: profileEntries.${name} == "directory" && builtins.pathExists (./nix + "/${name}/profile.nix")
      ) (builtins.attrNames profileEntries);
      rawProfiles = lib.genAttrs profileNames (name: import (./nix + "/${name}/profile.nix"));
      emptyProfile = {
        extends = null;
        shells = [ "zsh" ];
        primaryShell = "zsh";
        nixPackages = [ ];
        homebrewCasks = [ ];
        allowUnfree = [ ];
      };
      resolveProfile =
        seen: name:
        if builtins.elem name seen then
          throw "HomeWeave profile inheritance cycle: ${lib.concatStringsSep " -> " (seen ++ [ name ])}"
        else if !(builtins.hasAttr name rawProfiles) then
          throw "HomeWeave profile does not exist: ${name}"
        else
          let
            current = rawProfiles.${name};
            parentName = current.extends or null;
            parent = if parentName == null then emptyProfile else resolveProfile (seen ++ [ name ]) parentName;
          in
          parent
          // current
          // {
            nixPackages = lib.unique (parent.nixPackages ++ (current.nixPackages or [ ]));
            homebrewCasks = lib.unique (parent.homebrewCasks ++ (current.homebrewCasks or [ ]));
            allowUnfree = lib.unique (parent.allowUnfree ++ (current.allowUnfree or [ ]));
            development =
              (parent.development or false) || name == "development" || (current.development or false);
          };
      resolvedProfiles = lib.genAttrs profileNames (resolveProfile [ ]);
      profileModule =
        profile:
        {
          lib,
          pkgs,
          ...
        }:
        let
          packageFor =
            name: lib.attrByPath (lib.splitString "." name) (throw "Nix package is unavailable: ${name}") pkgs;
        in
        {
          homeWeave.base = {
            enable = true;
            shells = profile.shells;
          };
          homeWeave.development.enable = profile.development;
          home.packages = map packageFor profile.nixPackages;
        };
    in
    {
      overlays.default = import ./overlay.nix;
      homeModules.default = import ./home.nix;
      homeModules.profiles = lib.mapAttrs (_: profileModule) resolvedProfiles;

      lib.setup = {
        schemaVersion = 2;
        namespace = "home-weave";
        defaults = {
          shell = "zsh";
          profile = "base";
        };
        profiles = resolvedProfiles;
        dotfiles.layers = [
          {
            name = "base";
            source = {
              kind = "nix";
              path = "${nix-base.lib.dotfiles.path}";
            };
            entries =
              map
                (package: {
                  from = package;
                  to = ".";
                  mode = "merge";
                })
                [
                  "common"
                  "starship"
                  "ghostty"
                  "nvim"
                ]
              ++ [
                {
                  from = "@shells";
                  to = ".";
                  mode = "merge";
                }
              ];
          }
          {
            name = "custom";
            source = {
              kind = "nix";
              path = "${self.outPath}/dotfiles";
            };
            entries = [
              {
                from = "custom";
                to = ".";
                mode = "merge";
              }
            ];
          }
        ];
      };

      apps = forAllSystems (system: {
        setup = nix-base.apps.${system}.setup;
        home-weave = nix-base.apps.${system}.home-weave;
        default = nix-base.apps.${system}.home-weave;
      });
    };
}
