{
  description = "HomeWeave child profile";

  nixConfig = {
    substituters = [ "https://cache.nixos.org/" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    require-sigs = true;
    sandbox = true;
  };

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";
    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs = inputs@{ self, nix-base, ... }:
    nix-base.lib.mkHomeWeaveDistribution {
      inherit self;
      parent = nix-base;
      configPath = ./home-weave.json;
      sourceRoot = ./.;
      profileOverlay = ./.;
      packageDefinitions = ./packages.json;
      localOverlays = [ (import ./overlay.nix) ];
      distributionUrl = "path:${self.outPath}";
    };
}
