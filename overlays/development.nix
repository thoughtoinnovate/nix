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
  ];

  # Complete development environment (inherits from base automatically)
  my-dev-environment = prev.buildEnv {
    name = "full-development-environment";
    paths = final.hostOSPackages ++ final.baseDevShellPackages ++ final.developmentPackages;
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  # Development shell creation with specific Java version - FIXED
  mkDevShell = jdkVersion: { extraPackages ? [], extraShellHook ? "" }: 
    let
      selectedJdk = final."corretto${toString jdkVersion}";
    in prev.mkShell {
      buildInputs = final.baseDevShellPackages ++ final.developmentPackages ++ [ selectedJdk ] ++ extraPackages;
      shellHook = final.baseShellHook + ''
        # Override Java version for this shell
        export JAVA_HOME=${selectedJdk}
        
        echo "🔧 Development environment loaded"
        echo "☕ Java ${toString jdkVersion} (Corretto): $(java -version 2>&1 | head -n1)"
        echo "🐙 Lazygit, kubectl, minikube available"
        echo "💻 VS Code, Gradle, DBeaver available"
      '' + extraShellHook;
    };

  # Convenience shells for different Java versions - FIXED
  mkJava11DevShell = final.mkDevShell 11;
  mkJava17DevShell = final.mkDevShell 17;
  mkJava21DevShell = final.mkDevShell 21;
}
