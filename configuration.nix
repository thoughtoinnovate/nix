{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "nixos";
  time.timeZone = "UTC";

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    git
    fish
    starship
  ];

  system.stateVersion = "23.11";
}
