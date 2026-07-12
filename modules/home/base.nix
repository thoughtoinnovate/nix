{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homeWeave.base;
in
{
  options.homeWeave.base = {
    enable = lib.mkEnableOption "the HomeWeave base user environment";

    shells = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "bash"
          "fish"
          "nushell"
          "zsh"
        ]
      );
      default = [ "zsh" ];
      description = "Shells to install and configure. The bootstrap script normally selects one.";
    };

  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ (import ../../overlays/base.nix) ];

    assertions = [
      {
        assertion = cfg.shells != [ ];
        message = "homeWeave.base.shells must contain at least one shell.";
      }
    ];

    home.packages =
      pkgs.commonToolPackages
      ++ map (shell: pkgs.shellPackages.${shell}) cfg.shells
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.ghostty ];

    fonts.fontconfig.enable = pkgs.stdenv.hostPlatform.isLinux;
  };
}
