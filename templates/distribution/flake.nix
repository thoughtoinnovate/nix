{
  description = "Private HomeWeave work distribution";

  inputs = {
    home-weave.url = "github:thoughtoinnovate/nix";
    nixpkgs.follows = "home-weave/nixpkgs";
    home-manager.follows = "home-weave/home-manager";
    nix-darwin.follows = "home-weave/nix-darwin";
  };

  outputs =
    {
      self,
      home-weave,
      nixpkgs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Register private provider manifests here. Each provider must use
      # schemaVersion 1 and declare its executable and capabilities.
      providers = [ ];

      # Change this to the private SSH URL employees use with `nix run`.
      distributionUrl = "git+ssh://git@example.org/owner/home-weave-distribution.git";
      manifest = builtins.fromJSON (builtins.readFile ./profile-overlay/home-weave.json);
      resolvedBySystem = nixpkgs.lib.genAttrs systems (system: home-weave.lib.profileConfig.resolve {
        config = manifest;
        sourceRoot = ./profile-overlay;
        sourceName = manifest.distribution.name;
        inherit system;
        parentProfiles = home-weave.lib.setup.profilesBySystem.${system};
      });
    in
    {
      overlays = home-weave.overlays;
      homeModules = home-weave.homeModules;
      darwinModules = home-weave.darwinModules;
      lib = home-weave.lib // {
        setup = {
          schemaVersion = 4;
          namespace = "home-weave";
          defaults = resolvedBySystem.x86_64-linux.defaults // { shell = "zsh"; };
          profiles = resolvedBySystem.x86_64-linux.profiles;
          dotfiles = resolvedBySystem.x86_64-linux.dotfiles;
          profilesBySystem = nixpkgs.lib.mapAttrs (_: value: value.profiles) resolvedBySystem;
          dotfilesBySystem = nixpkgs.lib.mapAttrs (_: value: value.dotfiles) resolvedBySystem;
        };
      };

      apps = nixpkgs.lib.genAttrs systems (system: {
        home-weave = home-weave.lib.mkHomeWeaveApp {
          inherit system;
          extensions = providers;
          distributionName = "company-home-weave";
          baseUrl = distributionUrl;
          profileOverlay = ./profile-overlay;
        };
        setup = home-weave.apps.${system}.setup;
        default = self.apps.${system}.home-weave;
      });
    };
}
