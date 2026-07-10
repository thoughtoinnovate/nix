final: prev:
let
  lib = final.lib;
  isLinux = final.stdenv.hostPlatform.isLinux;
  isDarwin = final.stdenv.hostPlatform.isDarwin;

  commonToolPackages = with final; [
    curl
    git
    neovim
    nerd-fonts.fira-code
    starship
    stow
    wget
  ];

  shellPackages = with final; {
    bash = bashInteractive;
    fish = fish;
    nushell = nushell;
    zsh = zsh;
  };

  commonTerminalPackages = commonToolPackages ++ builtins.attrValues shellPackages;

  platformTerminalPackages = lib.optionals isLinux [ final.ghostty ];
  baseJdk = if isLinux then final.corretto21 else final.jdk21;
  pathsToLink = [
    "/bin"
    "/share"
    "/lib"
  ]
  ++ lib.optionals isDarwin [ "/Applications" ];
in
{
  inherit
    commonTerminalPackages
    commonToolPackages
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
    paths = final.basePackages;
    inherit pathsToLink;
  };

  # Compatibility aliases retained for existing consumers.
  base = final.terminal-tools;
  base-devshell = final.development-tools;

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
