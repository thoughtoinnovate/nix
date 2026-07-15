{ config, pkgs, ... }:

{
  home.username = "user";
  home.homeDirectory = "/home/user";
  home.stateVersion = "23.11";

  programs.home-manager.enable = true;

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      starship init fish | source
    '';
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = true;
    };
  };

  home.packages = with pkgs; [
    stow
    neovim
  ];
}
