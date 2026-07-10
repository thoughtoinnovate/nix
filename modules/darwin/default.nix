{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.thoughtoinnovate.darwin;
in
{
  options.thoughtoinnovate.darwin = {
    enable = lib.mkEnableOption "the thoughtoinnovate macOS environment";

    primaryUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = "The macOS user that owns Homebrew operations.";
    };

    manageHomebrew = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether nix-darwin should manage an existing Homebrew installation.";
    };

    installGhostty = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install the Ghostty macOS application using Homebrew Cask.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.manageHomebrew || cfg.primaryUser != null;
        message = "thoughtoinnovate.darwin.primaryUser must be set when Homebrew management is enabled.";
      }
    ];

    nixpkgs.overlays = [
      (import ../../overlays/base.nix)
      (import ../../overlays/development.nix)
    ];

    system.primaryUser = lib.mkIf (cfg.primaryUser != null) cfg.primaryUser;

    programs.zsh.enable = true;

    environment.shells = with pkgs; [
      bashInteractive
      fish
      zsh
    ];

    homebrew = lib.mkIf cfg.manageHomebrew {
      enable = true;
      casks = lib.optionals cfg.installGhostty [ "ghostty" ];
      onActivation = {
        autoUpdate = false;
        upgrade = false;
        cleanup = "none";
      };
    };
  };
}
