{
  description = "Consumer of the thoughtoinnovate Nix base";

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";

    nixpkgs.follows = "nix-base/nixpkgs";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nix-base,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      # Change these values for the target user and machine.
      system = "x86_64-linux";
      username = "change-me";
    in
    {
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            nix-base.overlays.base
            nix-base.overlays.development
          ];
          config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "vscode" ];
        };

        modules = [
          nix-base.homeModules.development
          {
            home = {
              inherit username;
              homeDirectory = "/home/${username}";
              stateVersion = "26.05";
            };

            thoughtoinnovate.development.enable = true;
            programs.home-manager.enable = true;
          }
        ];
      };
    };
}
