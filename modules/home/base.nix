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

    enableFish = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Home Manager should configure Fish in addition to Bash and Zsh.";
    };

    enableGhostty = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Home Manager should manage Ghostty and its shell integration.";
    };

    shellAliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        vim = "nvim";
      };
      description = "Shell aliases shared by Bash, Zsh, and Fish.";
    };

    sessionVariables = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      );
      default = {
        EDITOR = "nvim";
      };
      description = "Non-secret environment variables shared across supported shells.";
    };

    shellInit = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Optional shell-neutral initialization shared by Bash and Zsh.
        Do not put credentials or secret values here because Home Manager
        configuration is copied to the Nix store.
      '';
    };

    ghosttySettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Settings written to the Ghostty configuration file.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ (import ../../overlays/base.nix) ];

    home.packages = [ pkgs.terminal-tools ];
    home.sessionVariables = cfg.sessionVariables;

    programs.bash = {
      enable = true;
      shellAliases = cfg.shellAliases;
      initExtra = cfg.shellInit;
    };

    programs.zsh = {
      enable = true;
      shellAliases = cfg.shellAliases;
      initContent = cfg.shellInit;
    };

    programs.fish = lib.mkIf cfg.enableFish {
      enable = true;
      shellAliases = cfg.shellAliases;
    };

    programs.git.enable = true;

    programs.neovim = {
      enable = true;
      defaultEditor = true;
    };

    programs.starship = {
      enable = true;
      enableBashIntegration = true;
      enableFishIntegration = cfg.enableFish;
      enableZshIntegration = true;
    };

    programs.ghostty = lib.mkIf cfg.enableGhostty {
      enable = true;
      package = if pkgs.stdenv.hostPlatform.isLinux then pkgs.ghostty else null;
      settings = cfg.ghosttySettings;
      enableBashIntegration = true;
      enableFishIntegration = cfg.enableFish;
      enableZshIntegration = true;
    };
  };
}
