{
  description = "Personal configuration built with HomeWeave";

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";
    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs =
    { self, nix-base, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = lib.genAttrs systems;
      manifest = builtins.fromJSON (builtins.readFile ./home-weave.json);
      parentProfiles =
        if nix-base ? lib && nix-base.lib ? setup && nix-base.lib.setup ? profiles
        then nix-base.lib.setup.profiles
        else { };
      resolvedFor = system: nix-base.lib.profileConfig.resolve {
        config = manifest;
        sourceRoot = self.outPath;
        sourceName = manifest.distribution.name;
        inherit system parentProfiles;
      };
      resolvedBySystem = lib.genAttrs systems resolvedFor;
      resolved = resolvedBySystem.x86_64-linux;
      profileModule = name: { lib, pkgs, ... }:
        let
          profile = (resolvedFor pkgs.stdenv.hostPlatform.system).profiles.${name};
          packageFor = packageName:
            lib.attrByPath (lib.splitString "." packageName)
              (throw "Nix package is unavailable: ${packageName}") pkgs;
        in {
          homeWeave.base = {
            enable = true;
            shells = profile.shells;
            packageGroups = profile.packageGroups;
          };
          homeWeave.development.enable = profile.development;
          home.packages = map packageFor profile.nixPackages;
          home.sessionVariables = profile.environment.variables;
        };
    in {
      overlays.default = import ./overlay.nix;
      homeModules.default = import ./home.nix;
      homeModules.profiles = lib.genAttrs (builtins.attrNames resolved.profiles) profileModule;

      lib.setup = {
        schemaVersion = 4;
        namespace = "home-weave";
        defaults = resolved.defaults // { shell = "zsh"; };
        profiles = resolved.profiles;
        dotfiles = resolved.dotfiles;
        profilesBySystem = lib.mapAttrs (_: value: value.profiles) resolvedBySystem;
        dotfilesBySystem = lib.mapAttrs (_: value: value.dotfiles) resolvedBySystem;
      };

      apps = forAllSystems (system: {
        setup = nix-base.apps.${system}.setup;
        home-weave = nix-base.apps.${system}.home-weave;
        default = nix-base.apps.${system}.home-weave;
      });
    };
}
