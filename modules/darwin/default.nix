{
  config,
  lib,
  ...
}:
let
  cfg = config.homeWeave.darwin;
in
{
  imports = [ (lib.mkAliasOptionModule [ "thoughtoinnovate" "darwin" ] [ "homeWeave" "darwin" ]) ];

  options.homeWeave.darwin = {
    enable = lib.mkEnableOption "the HomeWeave macOS environment";

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

    casks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional reviewed Homebrew casks managed by nix-darwin.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.manageHomebrew || cfg.primaryUser != null;
        message = "homeWeave.darwin.primaryUser must be set when Homebrew management is enabled.";
      }
    ];

    nixpkgs.overlays = [
      (import ../../overlays/base.nix)
      (import ../../overlays/development.nix)
    ];

    system.primaryUser = lib.mkIf (cfg.primaryUser != null) cfg.primaryUser;

    homebrew = lib.mkIf cfg.manageHomebrew {
      enable = true;
      casks = lib.unique (lib.optionals cfg.installGhostty [ "ghostty" ] ++ cfg.casks);
      onActivation = {
        autoUpdate = false;
        upgrade = false;
        cleanup = "none";
      };
    };
  };
}
