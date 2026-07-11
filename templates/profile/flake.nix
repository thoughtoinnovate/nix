{
  description = "Personal configuration built on thoughtoinnovate/nix";

  inputs = {
    nix-base.url = "github:thoughtoinnovate/nix";

    nixpkgs.follows = "nix-base/nixpkgs";
  };

  outputs =
    {
      self,
      nix-base,
      nixpkgs,
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
        schemaVersion = 2;
        defaults = {
          shell = "zsh";
          profile = "development";
        };
        dotfiles.layers = [
          {
            name = "base";
            source = {
              kind = "nix";
              path = "${nix-base.outPath}/dotfiles";
            };
            entries =
              map
                (package: {
                  from = package;
                  to = ".";
                  mode = "merge";
                })
                [
                  "common"
                  "starship"
                  "@shell"
                  "ghostty"
                  "nvim"
                ];
          }
          {
            name = "custom";
            source = {
              kind = "nix";
              path = "${self.outPath}/dotfiles";
            };
            entries = [
              {
                from = "custom";
                to = ".";
                mode = "merge";
              }
            ];
          }
        ];
      };

      apps = forAllSystems (system: {
        setup = nix-base.apps.${system}.setup;
        default = nix-base.apps.${system}.setup;
      });
    };
}
