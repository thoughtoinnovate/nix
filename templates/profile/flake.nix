{
  description = "Personal configuration built on thoughtoinnovate/nix";

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";

    dotfiles-base = {
      url = "github:thoughtoinnovate/dotfiles";
      flake = false;
    };

    nix-base.inputs.dotfiles.follows = "dotfiles-base";
    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs =
    {
      self,
      nix-base,
      nixpkgs,
      dotfiles-base,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      overlays.default = import ./overlay.nix;
      homeModules.default = import ./home.nix;

      lib.setup = {
        schemaVersion = 1;
        defaults = {
          shell = "zsh";
          profile = "development";
        };
        dotfiles.layers = [
          {
            name = "base";
            source = "${dotfiles-base}";
            packages = [
              "common"
              "starship"
              "@shell"
              "ghostty"
              "nvim"
            ];
          }
          {
            name = "custom";
            source = "${self.outPath}/dotfiles";
            packages = [ "custom" ];
          }
        ];
      };

      apps = forAllSystems (system: {
        setup = nix-base.apps.${system}.setup;
        default = nix-base.apps.${system}.setup;
      });
    };
}
