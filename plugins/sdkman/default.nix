{ lib, declarativePackages, sourceRoot }:

let
  catalog = builtins.fromJSON (builtins.readFile ./packages.json);
  expected = {
    java = [ "11.0.31-amzn" "17.0.19-amzn" "21.0.11-amzn" "26.0.1-amzn" ];
    gradle = [ "9.6.1" ];
    coursier = [ "2.1.24" ];
    sbt = [ "2.0.1" ];
    scala = [ "3.8.4" ];
    scalacli = [ "1.15.0" ];
  };
  versions = entries: lib.sort builtins.lessThan (map (entry: entry.version) entries);
  expectedVersions = name: lib.sort builtins.lessThan expected.${name};
  defaultCount = entries: builtins.length (builtins.filter (entry: entry.default or false) entries);
in
{
  schemaVersion = 1;
  name = "sdkman";
  kind = "packages";
  platforms = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
  lifecycle = { packages = "remove"; state = "remove"; };
  overlay = declarativePackages.mkOverlay { inherit catalog sourceRoot; };
  packageNames = builtins.attrNames catalog.packages;

  resolve = { system, selection, profileName }:
    let
      candidates = selection.candidates or { };
      candidateNames = lib.sort builtins.lessThan (builtins.attrNames candidates);
      expectedNames = lib.sort builtins.lessThan (builtins.attrNames expected);
      versionsMatch = lib.all
        (candidate: versions (candidates.${candidate} or [ ]) == expectedVersions candidate)
        expectedNames;
      defaultsValid = defaultCount (candidates.java or [ ]) == 1
        && lib.all (candidate: defaultCount (candidates.${candidate} or [ ]) == 1)
          [ "gradle" "coursier" "sbt" "scala" "scalacli" ];
      statePath = "~/.local/share/home-weave/${profileName}/plugins/sdkman";
    in
    if (selection.storage or null) != "nix-store" then
      throw "HomeWeave SDKMAN plugin requires storage = nix-store"
    else if !(builtins.isBool (selection.allowRuntimeChanges or null)) then
      throw "HomeWeave SDKMAN plugin requires boolean allowRuntimeChanges"
    else if candidateNames != expectedNames || !versionsMatch || !defaultsValid then
      throw "HomeWeave SDKMAN plugin candidates must match the reviewed public catalog and declare one default per candidate"
    else {
      nixPackages = [ "home-weave-sdkman" ];
      providerPackages = { };
      allowUnfree = [ ];
      environmentVariables = {
        HOME_WEAVE_SDKMAN_PROFILE = profileName;
        HOME_WEAVE_SDKMAN_ALLOW_RUNTIME_CHANGES =
          if selection.allowRuntimeChanges then "true" else "false";
      };
      packageEnvironment = {
        JAVA_HOME = {
          package = "home-weave-sdkman-corretto21";
          path = "Contents/Home";
        };
      };
      statePaths = [ statePath ];
      metadata = {
        inherit system;
        storage = "nix-store";
        candidates = candidates;
        allowRuntimeChanges = selection.allowRuntimeChanges;
      };
    };
}
