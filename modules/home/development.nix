{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeWeave.development;
in
{
  imports = [ ./base.nix ];

  options.homeWeave.development.enable = lib.mkEnableOption "the HomeWeave development environment";

  config = lib.mkIf cfg.enable {
    homeWeave.base.enable = lib.mkDefault true;

    nixpkgs = {
      overlays = [ (import ../../overlays/development.nix) ];
      config.allowUnfreePredicate = lib.mkDefault (pkg: builtins.elem (lib.getName pkg) [ "vscode" ]);
    };

    home.packages = [ pkgs.full-development-environment ];
  };
}
