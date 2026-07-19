{ declarativePackages, sourceRoot }:

let
  catalog = builtins.fromJSON (builtins.readFile ./packages.json);
in
{
  schemaVersion = 1;
  name = "nvm";
  kind = "packages";
  platforms = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
  # HomeWeave owns the immutable NVM loader, but ~/.nvm may contain mutable
  # Node installations and aliases created directly by the user.
  lifecycle = { packages = "remove"; state = "retain"; };
  overlay = declarativePackages.mkOverlay { inherit catalog sourceRoot; };
  packageNames = builtins.attrNames catalog.packages;

  resolve = { selection, profileName, ... }:
    if (selection.storage or "nix-store") != "nix-store" then
      throw "HomeWeave NVM plugin requires storage = nix-store"
    else {
      nixPackages = [ "home-weave-nvm" ];
      providerPackages = { };
      allowUnfree = [ ];
      statePaths = [ ];
      metadata = {
        storage = "nix-store";
        version = "0.40.6";
        shellSupport = [ "bash" "zsh" ];
        inherit profileName;
      };
    };
}
