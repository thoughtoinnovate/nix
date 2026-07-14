{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeWeave.development;
  catalog = import ../../lib/package-catalog.nix;
in
{
  imports = [ ./base.nix ];

  options.homeWeave.development = {
    enable = lib.mkEnableOption "the HomeWeave development environment";
    includeDefaultPackages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include the public lean development package set for direct module consumers.";
    };
  };

  config = lib.mkIf cfg.enable {
    homeWeave.base.enable = lib.mkDefault true;
    homeWeave.base.packageNames = lib.mkIf cfg.includeDefaultPackages (lib.mkAfter catalog.development);

    nixpkgs.overlays = [ (import ../../overlays/development.nix) ];
  };
}
