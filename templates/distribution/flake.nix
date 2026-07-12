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
      distributionUrl = "git+ssh://git@gitlab.com/company/nix.git";
    in
    {
      overlays = home-weave.overlays;
      homeModules = home-weave.homeModules;
      darwinModules = home-weave.darwinModules;
      lib = home-weave.lib;

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
