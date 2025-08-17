{ ghostty, dotfiles }:

final: prev: {
  # Expose ghostty as a package
  ghostty = ghostty.packages.${final.system}.default;

  # Default stow package list
  dotfilesStowPackages = [
    "fish"
    "nvim"
    "starship"
    "ghostty"
  ];

  # IMPORTANT: Define baseDevShellPackages as a simple list with explicit package references
  baseDevShellPackages = [
    final.ghostty
    final.fish
    final.bash
    final.starship
    final.git
    final.neovim
    final.stow
    final.curl
    final.wget
    final.corretto21
  ];

  # Bundled environments for profile installation
  terminal-tools = prev.buildEnv {
    name = "terminal-tools";
    paths = [
      final.ghostty
      final.fish
      final.bash
      final.starship
      final.git
      final.neovim
      final.stow
    ];
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  development-tools = prev.buildEnv {
    name = "development-tools";
    paths = final.baseDevShellPackages;
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  # Legacy aliases
  base = final.terminal-tools;
  base-devshell = final.development-tools;

  # Cross-platform desktop integration script
  desktop-integration = prev.writeShellScriptBin "setup-nix-desktop" ''
    echo "🖥️ Setting up Nix desktop integration..."
    
    case "$(uname -s)" in
      Linux*)
        echo "📋 Detected Linux - setting up XDG desktop integration"
        
        mkdir -p ~/.local/share/applications ~/.local/share/icons
        
        if [ -d ~/.nix-profile/share/applications ]; then
          for app in ~/.nix-profile/share/applications/*.desktop; do
            if [ -f "$app" ]; then
              ln -sf "$app" ~/.local/share/applications/
              echo "  ✓ Linked $(basename "$app")"
            fi
          done
        fi
        
        if [ -d ~/.nix-profile/share/icons ]; then
          for icon_dir in ~/.nix-profile/share/icons/*; do
            if [ -d "$icon_dir" ]; then
              target_dir=~/.local/share/icons/$(basename "$icon_dir")
              mkdir -p "$target_dir"
              ln -sf "$icon_dir"/* "$target_dir"/ 2>/dev/null || true
            fi
          done
        fi
        
        if command -v update-desktop-database >/dev/null 2>&1; then
          update-desktop-database ~/.local/share/applications 2>/dev/null || true
          echo "  ✓ Updated desktop database"
        fi
        
        export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        
        echo "✅ Linux desktop integration complete!"
        ;;
        
      Darwin*)
        echo "🍎 Detected macOS - use nix-darwin for app integration"
        ;;
        
      *)
        echo "❓ Unknown operating system: $(uname -s)"
        ;;
    esac
  '';

  # Base shell creation function
  mkBaseDevShell = {
    extraPackages ? [],
    extraShellHook ? "",
    useBash ? false
  }:
    let
      commonEnvVars = {
        JAVA_HOME = "${final.corretto21}";
        EDITOR = "nvim";
        TERM = "xterm-256color";
      };

      stowApply = ''
        if command -v stow >/dev/null 2>&1; then
          DOTFILES="${dotfiles}"
          if [ -d "$DOTFILES" ]; then
            echo "🔗 Stowing from: $DOTFILES -> $HOME"
            cd "$DOTFILES"
            for pkg in ${builtins.concatStringsSep " " final.dotfilesStowPackages}; do
              if [ -d "$pkg" ]; then
                stow --verbose=1 --restow --no-folding --target "$HOME" "$pkg" || true
                echo "  ✓ stowed $pkg"
              fi
            done
          fi
        else
          echo "⚠️ GNU Stow not found; ensure it's included in baseDevShellPackages"
        fi
      '';

      commonInfo = ''
        echo "🖥️ Development environment loaded"
        echo "☕ Java: $(java -version 2>&1 | head -n1)"
        echo "📦 Editor: $EDITOR"
        echo "💡 Platform: ${final.system}"
        echo "🔧 Run 'setup-nix-desktop' for GUI app integration"
        echo ""
      '';

      bashSetup = ''
        ${commonInfo}
        echo "🚀 Running in Bash/Zsh mode"
        echo "💡 To use Fish (recommended): 'fish'"
        echo ""
        case "$(uname -s)" in
          Linux*)
            export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
            ;;
        esac
        if [ -n "$BASH_VERSION" ]; then
          eval "$(starship init bash)"
        elif [ -n "$ZSH_VERSION" ]; then
          eval "$(starship init zsh)"
        else
          eval "$(starship init bash)"
        fi
      '';

      fishSetup = ''
        ${commonInfo}
        echo "🐠 Preparing Fish shell as default..."
        case "$(uname -s)" in
          Linux*)
            export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
            ;;
        esac
      '';
    in
    prev.mkShell (commonEnvVars // {
      buildInputs = final.baseDevShellPackages ++ extraPackages;
      shellHook = (if useBash then bashSetup else fishSetup) + stowApply + extraShellHook + (if useBash then ''
        echo "💡 Switch to Fish anytime: 'fish'"
      '' else ''
        echo "🐠 Starting Fish shell..."
        exec fish
      '');
    });

  # Convenience functions
  mkBaseFishDevShell = { extraPackages ? [], extraShellHook ? "" }:
    final.mkBaseDevShell { inherit extraPackages extraShellHook; };

  mkBaseBashDevShell = { extraPackages ? [], extraShellHook ? "" }:
    final.mkBaseDevShell { inherit extraPackages extraShellHook; useBash = true; };

  # Helper scripts
  setup-fish-default = prev.writeShellScriptBin "setup-fish-default" ''
    echo "🐠 Setting up Fish as system default shell..."
    
    if ! grep -q "$(which fish)" /etc/shells 2>/dev/null; then
      echo "Adding fish to /etc/shells (requires sudo)"
      echo "$(which fish)" | sudo tee -a /etc/shells
    fi
    
    echo "Setting fish as default shell for $USER (requires password)"
    chsh -s "$(which fish)"
    
    echo "✅ Fish configured as system default!"
    echo "💡 Restart your terminal or run: exec fish"
  '';

  dotfiles-stow = prev.writeShellScriptBin "dotfiles-stow" ''
    set -e
    DOTFILES="${dotfiles}"
    echo "🔗 Stowing from: $DOTFILES -> $HOME"
    cd "$DOTFILES"
    for pkg in ${builtins.concatStringsSep " " final.dotfilesStowPackages}; do
      if [ -d "$pkg" ]; then
        stow --verbose=1 --restow --no-folding --target "$HOME" "$pkg"
        echo "  ✓ stowed $pkg"
      fi
    done
    echo "✅ Done"
  '';
}
