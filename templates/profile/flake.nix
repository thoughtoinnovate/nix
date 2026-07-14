{
  description = "Personal configuration built with HomeWeave";

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
      localOverlays = [ (import ./overlay.nix) ];
      distributionUrl = "path:${self.outPath}";
    };
}
