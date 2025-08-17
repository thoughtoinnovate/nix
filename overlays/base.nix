{ ghostty }:

final: prev: {
  # Expose ghostty as a package
  ghostty = ghostty.packages.${final.system}.default;

  # Host OS packages (terminal only)
  hostOSPackages = [ final.ghostty ];

  # DevShell base packages
  baseDevShellPackages = with final; [
    fish
    bash
    starship
    git
    neovim
    stow
    curl
    wget
    corretto21
  ];

  # Cross-platform desktop integration script
  desktop-integration = prev.writeShellScriptBin "setup-nix-desktop" ''
    echo "🖥️ Setting up Nix desktop integration..."
    
    case "$(uname -s)" in
      Linux*)
        echo "📋 Detected Linux - setting up XDG desktop integration"
        
        # Ensure directories exist
        mkdir -p ~/.local/share/applications ~/.local/share/icons
        
        # Symlink desktop files
        if [ -d ~/.nix-profile/share/applications ]; then
          for app in ~/.nix-profile/share/applications/*.desktop; do
            if [ -f "$app" ]; then
              ln -sf "$app" ~/.local/share/applications/
              echo "  ✓ Linked $(basename "$app")"
            fi
          done
        fi
        
        # Symlink icons
        if [ -d ~/.nix-profile/share/icons ]; then
          for icon_dir in ~/.nix-profile/share/icons/*; do
            if [ -d "$icon_dir" ]; then
              target_dir=~/.local/share/icons/$(basename "$icon_dir")
              mkdir -p "$target_dir"
              ln -sf "$icon_dir"/* "$target_dir"/ 2>/dev/null || true
            fi
          done
        fi
        
        # Update desktop database
        if command -v update-desktop-database >/dev/null 2>&1; then
          update-desktop-database ~/.local/share/applications 2>/dev/null || true
          echo "  ✓ Updated desktop database"
        fi
        
        # Set XDG_DATA_DIRS for current session
        export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        
        echo "✅ Linux desktop integration complete!"
        echo "💡 Add this to your ~/.bashrc for permanent integration:"
        echo "    export XDG_DATA_DIRS=\"\$HOME/.nix-profile/share:\$XDG_DATA_DIRS\""
        echo "🔄 Log out and back in, or restart your desktop environment"
        ;;
        
      Darwin*)
        echo "🍎 Detected macOS"
        echo "ℹ️  For macOS app integration, use nix-darwin:"
        echo "    https://github.com/LnL7/nix-darwin"
        echo "💡 nix-darwin automatically handles .app bundle integration with Spotlight"
        ;;
        
      CYGWIN*|MINGW*|MSYS*)
        echo "🪟 Detected Windows/WSL environment"
        echo "ℹ️  For Windows integration, consider:"
        echo "    - WSLg for GUI app integration"
        echo "    - NixOS-WSL for better Nix integration"
        echo "    - Manual shortcuts in Start Menu"
        ;;
        
      *)
        echo "❓ Unknown operating system: $(uname -s)"
        echo "ℹ️  Desktop integration not available for this platform"
        ;;
    esac
  '';

  # Host OS terminal environment (just Ghostty)
  base = prev.buildEnv {
    name = "host-terminal-environment";
    paths = final.hostOSPackages;
    pathsToLink = [ "/bin" "/share" "/lib" "/Applications" ];
  };

  # Base development shell environment
  base-devshell = prev.buildEnv {
    name = "base-devshell-environment";
    paths = final.baseDevShellPackages;
    pathsToLink = [ "/bin" "/share" "/lib" ];
  };

  # Base shell configurations
  baseShellHook = ''
    export STARSHIP_CONFIG=${../dotfiles/starship.toml}
    
    if command -v fish >/dev/null 2>&1; then
      if [[ "$SHELL" != *"fish"* ]]; then
        export SHELL=$(which fish)
      fi
      eval "$(starship init fish 2>/dev/null || starship init bash)"
    else
      eval "$(starship init bash)"
    fi
    
    export JAVA_HOME=${final.corretto21}
    
    # Set XDG_DATA_DIRS on Linux for desktop integration
    case "$(uname -s)" in
      Linux*)
        export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        ;;
    esac
    
    echo "🖥️ Base development environment loaded"
    echo "🐚 Shell: Fish/Bash cross-compatible" 
    echo "⭐ Starship with Catppuccin theme"
    echo "☕ Java 21 (Corretto): $(java -version 2>&1 | head -n1)"
    echo "📦 Stow available for dotfile management"
    echo "💡 Platform: ${final.system}"
    echo "🔧 Run 'setup-nix-desktop' for GUI app integration"
  '';

  # Base shell creation function
  mkBaseDevShell = { extraPackages ? [], extraShellHook ? "" }: prev.mkShell {
    buildInputs = final.baseDevShellPackages ++ extraPackages;
    shellHook = final.baseShellHook + extraShellHook;
  };
}
