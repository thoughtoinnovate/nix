{
  description = "Private HomeWeave work distribution";

  nixConfig = {
    substituters = [ "https://cache.nixos.org/" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    require-sigs = true;
    sandbox = true;
  };

  inputs = {
    home-weave.url = "github:thoughtoinnovate/nix";
    nixpkgs.follows = "home-weave/nixpkgs";
  };

  outputs = inputs@{ self, home-weave, ... }:
    home-weave.lib.mkHomeWeaveDistribution {
      inherit self;
      parent = home-weave;
      configPath = ./profile-overlay/home-weave.json;
      sourceRoot = ./profile-overlay;
      profileOverlay = ./profile-overlay;
      distributionUrl = "git+ssh://git@example.org/owner/home-weave-distribution.git";

      # Register private adapters here. Public HomeWeave receives only the
      # generic provider descriptor and executable path.
      extensionsForSystem = _system: _pkgs: [ ];
    };
}
