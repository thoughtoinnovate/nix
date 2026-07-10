{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.thoughtoinnovate.base;
in
{
  options.thoughtoinnovate.base = {
    enable = lib.mkEnableOption "the thoughtoinnovate base user environment";

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
        message = "thoughtoinnovate.base.shells must contain at least one shell.";
      }
    ];

    home.packages =
      (with pkgs; [
        curl
        git
        neovim
        nerd-fonts.fira-code
        starship
        stow
        wget
      ])
      ++ map (shell: pkgs.shellPackages.${shell}) cfg.shells
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.ghostty ];

    fonts.fontconfig.enable = pkgs.stdenv.hostPlatform.isLinux;
  };
}
