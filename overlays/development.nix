final: prev: {
  extendedDevPackages = with final; [
    lazygit
    kubectl
    minikube
    vscode
    gradle
  ];

  # Helper: Replace corretto21 with any other Java version as needed
  fullDevBasePackages = builtins.map (pkg:
    if pkg == final.corretto21 then final.corretto17 else pkg
  ) final.baseDevShellPackages;

  # This environment will use Java 17, not 21 (can change to corretto11/21 as needed)
  full-development-environment = prev.buildEnv {
    name = "full-development-environment";
    paths = final.fullDevBasePackages ++ final.extendedDevPackages;
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  # Convenient devShells with specific Java versions
  mkDevShell = jdkVersion: { extraPackages ? [], extraShellHook ? "", useBash ? false }:
    let
      selectedJdk = final."corretto${toString jdkVersion}";
      devShellHook = ''
        export JAVA_HOME=${selectedJdk}
        export PATH=${selectedJdk}/bin:$PATH
        echo "🔧 Development environment loaded"
        echo "☕ Java ${toString jdkVersion} (Corretto): $(java -version 2>&1 | head -n1)"
        echo "🐙 Lazygit, kubectl, minikube available"
        echo "💻 VS Code, Gradle available"
        echo "⚠️  Java ${toString jdkVersion} active in this shell only"
        echo ""
      '' + extraShellHook;
    in
    final.mkBaseDevShell {
      extraPackages = final.extendedDevPackages ++ [ selectedJdk ] ++ extraPackages;
      extraShellHook = devShellHook;
      useBash = useBash;
    };

  mkJava11DevShell = final.mkDevShell 11;
  mkJava17DevShell = final.mkDevShell 17;
  mkJava21DevShell = final.mkDevShell 21;

  # Bash variants
  mkJava11BashDevShell = args: final.mkDevShell 11 (args // { useBash = true; });
  mkJava17BashDevShell = args: final.mkDevShell 17 (args // { useBash = true; });
  mkJava21BashDevShell = args: final.mkDevShell 21 (args // { useBash = true; });
}
