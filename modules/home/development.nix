{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.thoughtoinnovate.development;
in
{
  imports = [ ./base.nix ];

  options.thoughtoinnovate.development.enable = lib.mkEnableOption "the thoughtoinnovate development environment";

  config = lib.mkIf cfg.enable {
    thoughtoinnovate.base.enable = lib.mkDefault true;

    nixpkgs = {
      overlays = [ (import ../../overlays/development.nix) ];
      config.allowUnfreePredicate = lib.mkDefault (pkg: builtins.elem (lib.getName pkg) [ "vscode" ]);
    };

    home.packages = [ pkgs.full-development-environment ];
  };
}
