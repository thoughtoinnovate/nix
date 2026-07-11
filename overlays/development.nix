final: prev:
let
  lib = final.lib;
  pathsToLink = [
    "/bin"
    "/share"
    "/lib"
  ]
  ++ lib.optionals final.stdenv.hostPlatform.isDarwin [ "/Applications" ];
in
{
  neovimDevelopmentPackages = with final; [
    bash-language-server
    black
    cargo
    delve
    eslint
    go
    google-java-format
    golangci-lint
    gopls
    imagemagick
    jdt-language-server
    jupyter
    lua-language-server
    markdownlint-cli2
    marksman
    prettier
    pyright
    ruff
    rust-analyzer
    rustc
    shellcheck
    shfmt
    sqlfluff
    stylua
    taplo
    typescript-language-server
    vscode-js-debug
    vscode-langservers-extracted
    yaml-language-server
  ];

  jdkForVersion =
    jdkVersion:
    if final.stdenv.hostPlatform.isLinux then
      final."corretto${toString jdkVersion}"
    else
      final."jdk${toString jdkVersion}";

  extendedDevPackages =
    with final;
    [
      gradle
      kubectl
      lazygit
      minikube
      vscode
    ]
    ++ final.neovimDevelopmentPackages;

  fullDevBasePackages = final.basePackagesWithoutJava ++ [ (final.jdkForVersion 17) ];

  full-development-environment = prev.buildEnv {
    name = "full-development-environment";
    paths = final.fullDevBasePackages ++ final.extendedDevPackages;
    inherit pathsToLink;
  };

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
      extraPackages = final.extendedDevPackages ++ extraPackages;
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
