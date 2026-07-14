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
  leanDevelopmentPackages = with final; [
    jq
    tmux
    lazygit
    shellcheck
    shfmt
  ];

  homeWeavePackageGroups = {
    python = with final; [
      python3
      python3Packages.debugpy
      black
      pyright
      ruff
    ];
    data-jupyter = with final; [
      jupyter
      python3Packages.notebook
      python3Packages.ipykernel
      jupytext
      python3Packages.pillow
      python3Packages.cairosvg
    ];
    go = with final; [
      go
      gopls
      delve
      golangci-lint
    ];
    rust = with final; [
      cargo
      rustc
      rust-analyzer
      taplo
    ];
    java = with final; [
      (final.jdkForVersion 17)
      gradle
      jdt-language-server
      google-java-format
    ];
    web = with final; [
      eslint
      prettier
      typescript-language-server
      yaml-language-server
      marksman
      markdownlint-cli2
      vscode-langservers-extracted
      vscode-js-debug
    ];
    cloud = with final; [
      awscli2
      terraform
      kubectl
      minikube
    ];
    desktop = with final; [ vscode ];
  };

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
