final: prev:
let
  lib = final.lib;
  isLinux = final.stdenv.hostPlatform.isLinux;
  isDarwin = final.stdenv.hostPlatform.isDarwin;

  homeWeaveCli = prev.writeShellApplication {
    name = "home-weave";
    runtimeInputs = with final; [
      coreutils
      check-jsonschema
      curl
      diffutils
      fzf
      git
      gnugrep
      gnused
      gum
      jq
      nix
      rsync
      ripgrep
      stow
    ];
    text = ''
      export HOME_WEAVE_PROFILE_TEMPLATE="''${HOME_WEAVE_PROFILE_TEMPLATE:-${../templates/profile}}"
      export HOME_WEAVE_BUNDLED_DOTFILES="''${HOME_WEAVE_BUNDLED_DOTFILES:-${../dotfiles}}"
      export HOME_WEAVE_PACKAGE_PREVIEW="''${HOME_WEAVE_PACKAGE_PREVIEW:-${../lib/package-preview.sh}}"
      export HOME_WEAVE_PUBLISHER_REGISTRY="''${HOME_WEAVE_PUBLISHER_REGISTRY:-${../lib/reviewed-publishers.json}}"
      export HOME_WEAVE_PUBLISHER_FILTER="''${HOME_WEAVE_PUBLISHER_FILTER:-${../lib/verify-publishers.jq}}"
      export HOME_WEAVE_NATIVE_PROVIDER="''${HOME_WEAVE_NATIVE_PROVIDER:-${../lib/native-provider.sh}}"
      export HOME_WEAVE_PREFLIGHT_REPORTER="''${HOME_WEAVE_PREFLIGHT_REPORTER:-${../lib/preflight-report.sh}}"
      export HOME_WEAVE_ENV_RENDERER="''${HOME_WEAVE_ENV_RENDERER:-${../lib/home-weave-env.sh}}"
      export HOME_WEAVE_CONFIG_SCHEMA="''${HOME_WEAVE_CONFIG_SCHEMA:-${../schemas/home-weave-v3.schema.json}}"
      exec ${final.bash}/bin/bash ${../home-weave.sh} "$@"
    '';
  };

  homeWeaveEnv = prev.writeShellApplication {
    name = "home-weave-env";
    runtimeInputs = with final; [
      coreutils
      jq
    ];
    text = ''
      exec ${final.bash}/bin/bash ${../lib/home-weave-env.sh} "$@"
    '';
  };

  homeWeaveVerifiedInstaller = prev.writeShellApplication {
    name = "home-weave-verified-installer";
    runtimeInputs = with final; [
      coreutils
      curl
      gawk
      gnused
      jq
    ];
    text = ''
      exec ${final.bash}/bin/bash ${../lib/verified-installer.sh} "$@"
    '';
  };

  neovimPython = final.python3.withPackages (pythonPackages: [ pythonPackages.pynvim ]);

  neovimCorePackages = with final; [
    clang
    fd
    gnumake
    nodejs
    neovimPython
    ripgrep
    unzip
  ];

  commonToolPackages =
    with final;
    [
      curl
      git
      homeWeaveCli
      homeWeaveEnv
      neovim
      starship
      stow
    ]
    ++ neovimCorePackages;

  shellPackages = with final; {
    bash = bashInteractive;
    fish = fish;
    nushell = nushell;
    zsh = zsh;
  };

  commonTerminalPackages = commonToolPackages ++ builtins.attrValues shellPackages;

  platformTerminalPackages = [ ];
  baseJdk = if isLinux then final.corretto21 else final.jdk21;
  pathsToLink = [
    "/bin"
    "/share"
    "/lib"
  ]
  ++ lib.optionals isDarwin [ "/Applications" ];
in
{
  home-weave-cli = homeWeaveCli;
  home-weave-env = homeWeaveEnv;
  home-weave-verified-installer = homeWeaveVerifiedInstaller;
  inherit
    commonTerminalPackages
    commonToolPackages
    neovimCorePackages
    neovimPython
    platformTerminalPackages
    shellPackages
    ;

  basePackagesWithoutJava = commonTerminalPackages ++ platformTerminalPackages;
  inherit baseJdk;
  basePackages = final.basePackagesWithoutJava ++ [ final.baseJdk ];

  terminal-tools = prev.buildEnv {
    name = "terminal-tools";
    paths = final.basePackagesWithoutJava;
    inherit pathsToLink;
  };

  development-tools = prev.buildEnv {
    name = "development-tools";
    paths = final.basePackagesWithoutJava;
    inherit pathsToLink;
  };

  mkBaseDevShell =
    {
      extraPackages ? [ ],
      extraShellHook ? "",
      jdk ? final.baseJdk,
      shellLabel ? "default",
    }:
    prev.mkShell {
      packages = final.basePackagesWithoutJava ++ [ jdk ] ++ extraPackages;

      JAVA_HOME = "${jdk}";
      EDITOR = "nvim";
      TERM = "xterm-256color";

      shellHook = ''
        echo "Development environment ready (${shellLabel})"
        echo "Java: $(java -version 2>&1 | head -n1)"
        echo "Editor: $EDITOR"
        ${extraShellHook}
      '';
    };

  mkBaseBashDevShell = args: final.mkBaseDevShell (args // { shellLabel = "bash-compatible"; });

  mkBaseZshDevShell =
    args:
    final.mkBaseDevShell (
      args
      // {
        shellLabel = "zsh-compatible; run zsh to switch shells";
        extraPackages = (args.extraPackages or [ ]) ++ [ final.zsh ];
      }
    );
}
