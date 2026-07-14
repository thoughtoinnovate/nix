{
  description = "Private HomeWeave work distribution";

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
