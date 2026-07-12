{
  description = "Consumer of HomeWeave";

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";

    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs =
    {
      nix-base,
      nixpkgs,
      ...
    }:
    let
      # Change these values for the target user and machine.
      system = "x86_64-linux";
      username = "change-me";
      home-manager = nix-base.inputs.home-manager;
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
          config.allowUnsupportedSystem = true;
        };

        modules = [
          nix-base.homeModules.development
          {
            home = {
              inherit username;
              homeDirectory = "/home/${username}";
              stateVersion = "26.05";
            };

            homeWeave.development.enable = true;
            programs.home-manager.enable = true;
          }
        ];
      };
    };
}
