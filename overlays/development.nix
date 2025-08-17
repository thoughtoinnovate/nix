final: prev: {
  # Development packages (for both Host OS & DevShell)
  developmentPackages = with final; [
    # Git tools
    lazygit
    
    # Container & Kubernetes
    kubectl
    minikube
    
    # Development Tools
    vscode
    gradle
    
    # Additional Java versions for development
    corretto11
    corretto17
  ];

  # Complete development environment (inherits from base automatically)
  my-dev-environment = prev.buildEnv {
    name = "full-development-environment";
    paths = final.hostOSPackages ++ final.baseDevShellPackages ++ final.developmentPackages;
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  # Development shell creation with specific Java version
  mkDevShell = jdkVersion: { extraPackages ? [], extraShellHook ? "", useFish ? false }: 
    let
      selectedJdk = final."corretto${toString jdkVersion}";
      devShellHook = ''
        # Override Java version for this shell
        export JAVA_HOME=${selectedJdk}
        
        echo "🔧 Development environment loaded"
        echo "☕ Java ${toString jdkVersion} (Corretto): $(java -version 2>&1 | head -n1)"
        echo "🐙 Lazygit, kubectl, minikube available"
        echo "💻 VS Code, Gradle available"
        echo ""
      '' + extraShellHook;
    in
    final.mkBaseDevShell {
      extraPackages = final.developmentPackages ++ [ selectedJdk ] ++ extraPackages;
      extraShellHook = devShellHook;
      inherit useFish;
    };

  # Convenience shells for different Java versions
  mkJava11DevShell = final.mkDevShell 11;
  mkJava17DevShell = final.mkDevShell 17;
  mkJava21DevShell = final.mkDevShell 21;

  # Fish variants
  mkJava11FishDevShell = args: final.mkDevShell 11 (args // { useFish = true; });
  mkJava17FishDevShell = args: final.mkDevShell 17 (args // { useFish = true; });
  mkJava21FishDevShell = args: final.mkDevShell 21 (args // { useFish = true; });
}
