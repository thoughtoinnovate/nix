final: prev:
let
  lib = final.lib;
  catalog = builtins.fromJSON (builtins.readFile ../catalogs/packages.json);
  packageFor = name:
    if name == "jdk17" then
      (if final.stdenv.hostPlatform.isLinux then final.corretto17 else final.jdk17)
    else
      lib.attrByPath (lib.splitString "." name)
        (throw "Public package catalog entry is unavailable: ${name}") final;
  packagesFor = names: map packageFor names;
  pathsToLink = [
    "/bin"
    "/share"
    "/lib"
  ]
  ++ lib.optionals final.stdenv.hostPlatform.isDarwin [ "/Applications" ];
in
{
  leanDevelopmentPackages = packagesFor catalog.development;

  homeWeavePackageGroups = lib.mapAttrs (_: names: packagesFor names) catalog.groups;

  neovimDevelopmentPackages = packagesFor catalog.bundles."neovim-development";

  jdkForVersion =
    jdkVersion:
    if final.stdenv.hostPlatform.isLinux then
      final."corretto${toString jdkVersion}"
    else
      final."jdk${toString jdkVersion}";

  mkDevShell =
    jdkVersion:
    {
      extraPackages ? [ ],
      extraShellHook ? "",
      shellLabel ? "development",
    }:
    let
      selectedJdk = final.jdkForVersion jdkVersion;
    in
    final.mkBaseDevShell {
      jdk = selectedJdk;
      extraPackages = final.leanDevelopmentPackages ++ extraPackages;
      inherit shellLabel;
      extraShellHook = ''
        export PATH="${selectedJdk}/bin:$PATH"
        echo "Java ${toString jdkVersion} active in this shell"
        ${extraShellHook}
      '';
    };

  mkJava11DevShell = final.mkDevShell 11;
  mkJava17DevShell = final.mkDevShell 17;
  mkJava21DevShell = final.mkDevShell 21;

  mkJava11BashDevShell =
    args: final.mkDevShell 11 (args // { shellLabel = "bash-compatible Java 11"; });
  mkJava17BashDevShell =
    args: final.mkDevShell 17 (args // { shellLabel = "bash-compatible Java 17"; });
  mkJava21BashDevShell =
    args: final.mkDevShell 21 (args // { shellLabel = "bash-compatible Java 21"; });
}
