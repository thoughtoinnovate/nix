final: prev: {
  # Extended development packages (NO conflicting Java versions in main env)
  extendedDevPackages = with final; [
    lazygit
    kubectl
    minikube
    vscode
    gradle
    # NO corretto11, corretto17 here - only in dev shells
  ];

  # Clean main development environment (Java 21 only - no conflicts)
  full-development-environment = prev.buildEnv {
    name = "full-development-environment";
    paths = final.baseDevShellPackages ++ final.extendedDevPackages;
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  # Development shell creation with specific Java version (TEMPORARY override)
  mkDevShell = jdkVersion: { extraPackages ? [], extraShellHook ? "", useBash ? false }: 
    let
      selectedJdk = final."corretto${toString jdkVersion}";
      devShellHook = ''
        # TEMPORARY override - only in this shell
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
      # Add the specific Java version ONLY to the shell, not main env
      extraPackages = final.extendedDevPackages ++ [ selectedJdk ] ++ extraPackages;
      extraShellHook = devShellHook;
      useBash = useBash;
    };

  # Convenience shells for different Java versions
  mkJava11DevShell = final.mkDevShell 11;
  mkJava17DevShell = final.mkDevShell 17;
  mkJava21DevShell = final.mkDevShell 21;

  # Bash variants
  mkJava11BashDevShell = args: final.mkDevShell 11 (args // { useBash = true; });
  mkJava17BashDevShell = args: final.mkDevShell 17 (args // { useBash = true; });
  mkJava21BashDevShell = args: final.mkDevShell 21 (args // { useBash = true; });
}
