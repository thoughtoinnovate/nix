{ lib, ... }:
{
  imports = [
    (lib.mkAliasOptionModule [ "thoughtoinnovate" ] [ "homeWeave" ])
    ./base.nix
    ./development.nix
  ];
}
