{ ghostty, dotfiles }:

final: prev: {
  # Expose ghostty as a package
  ghostty = ghostty.packages.${final.system}.default;

  # Only stow packages that actually exist
  dotfilesStowPackages = builtins.filter (pkg: 
    builtins.pathExists "${dotfiles}/${pkg}"
  ) [ "fish" "nvim" "starship" "ghostty" ];

  # Base development packages
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

  # Bundled environments
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

  # Simple mkBaseDevShell
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

      # Simple stow integration
      stowSetup = ''
        echo "🔧 Setting up dotfiles integration..."
        
        export DOTFILES="${dotfiles}"
        echo "📁 DOTFILES: $DOTFILES"
        
        if [ -d "$DOTFILES" ] && command -v stow >/dev/null 2>&1; then
          cd "$DOTFILES"
          
          PACKAGES="${builtins.concatStringsSep " " final.dotfilesStowPackages}"
          if [ -n "$PACKAGES" ]; then
            echo "📦 Processing packages: $PACKAGES"
            
            for pkg in $PACKAGES; do
              if [ -d "$pkg" ]; then
                echo "  📦 $pkg - stowing dotfiles config"
                
                if stow --target="$HOME" "$pkg" 2>/dev/null; then
                  echo "    ✅ $pkg stowed successfully"
                else
                  echo "    ⚠️  $pkg - conflicts detected, use 'dotfiles-stow' to resolve"
                fi
              else
                echo "  ❌ $pkg directory not found"
              fi
            done
          else
            echo "📦 No stow packages found"
          fi
          
          echo "💡 Use 'dotfiles-stow' to manage conflicts manually"
        else
          echo "⚠️  Stow not available or dotfiles directory missing"
        fi
        
        echo "🏁 Dotfiles setup complete"
        echo ""
      '';

      commonInfo = ''
        echo "🖥️  Development environment ready"
        echo "☕ Java: $(java -version 2>&1 | head -n1)"
        echo "📦 Editor: $EDITOR"
        echo ""
      '';

      shellSetup = if useBash then ''
        ${commonInfo}
        echo "🚀 Running in Bash mode"
        export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        eval "$(starship init bash)"
      '' else ''
        ${commonInfo}
        echo "🐠 Starting Fish shell..."
        export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
      '';

    in
    prev.mkShell (commonEnvVars // {
      buildInputs = final.baseDevShellPackages ++ extraPackages;
      shellHook = stowSetup + shellSetup + extraShellHook + (if useBash then ''
        echo "💡 Switch to Fish: 'fish'"
      '' else ''
        exec fish
      '');
    });

  # Convenience functions
  mkBaseFishDevShell = { extraPackages ? [], extraShellHook ? "" }:
    final.mkBaseDevShell { inherit extraPackages extraShellHook; };

  mkBaseBashDevShell = { extraPackages ? [], extraShellHook ? "" }:
    final.mkBaseDevShell { inherit extraPackages extraShellHook; useBash = true; };

  # Helper scripts
  desktop-integration = prev.writeShellScriptBin "setup-nix-desktop" ''
    echo "🖥️ Setting up Nix desktop integration..."
    case "$(uname -s)" in
      Linux*)
        mkdir -p ~/.local/share/applications ~/.local/share/icons
        if [ -d ~/.nix-profile/share/applications ]; then
          for app in ~/.nix-profile/share/applications/*.desktop; do
            if [ -f "$app" ]; then
              ln -sf "$app" ~/.local/share/applications/
              echo "  ✓ Linked $(basename "$app")"
            fi
          done
        fi
        export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        echo "✅ Linux desktop integration complete!"
        ;;
      Darwin*)
        echo "🍎 Detected macOS - use nix-darwin for app integration"
        ;;
    esac
  '';

  setup-fish-default = prev.writeShellScriptBin "setup-fish-default" ''
    echo "🐠 Setting up Fish as system default shell..."
    if ! grep -q "$(which fish)" /etc/shells 2>/dev/null; then
      echo "Adding fish to /etc/shells (requires sudo)"
      echo "$(which fish)" | sudo tee -a /etc/shells
    fi
    echo "Setting fish as default shell for $USER (requires password)"
    chsh -s "$(which fish)"
    echo "✅ Fish configured as system default!"
  '';

  # Simple dotfiles management tool
  dotfiles-stow = prev.writeShellScriptBin "dotfiles-stow" ''
    DOTFILES="${dotfiles}"
    echo "🔗 Manual dotfiles management: $DOTFILES -> $HOME"
    
    cd "$DOTFILES"
    PACKAGES="${builtins.concatStringsSep " " final.dotfilesStowPackages}"
    
    if [ -n "$PACKAGES" ]; then
      echo ""
      echo "📋 Available packages: $PACKAGES"
      echo ""
      echo "Options:"
      echo "  1. Show conflicts only (safe)"
      echo "  2. Stow non-conflicting packages"
      echo "  3. Adopt conflicting files (WARNING: modifies dotfiles)"
      echo "  4. Override all conflicts (WARNING: overwrites files)"
      echo ""
      read -p "Choose (1-4): " choice
      
      case $choice in
        1)
          echo "🔍 Showing conflicts..."
          for pkg in $PACKAGES; do
            if [ -d "$pkg" ]; then
              echo "--- $pkg ---"
              stow --target="$HOME" --simulate "$pkg" 2>&1
            fi
          done
          ;;
        2)
          echo "📦 Stowing non-conflicting packages..."
          for pkg in $PACKAGES; do
            if [ -d "$pkg" ]; then
              if stow --target="$HOME" --simulate "$pkg" 2>&1 | grep -q "conflict"; then
                echo "  ⏭️  Skipping $pkg (conflicts detected)"
              else
                stow --target="$HOME" "$pkg" && echo "  ✓ Stowed $pkg"
              fi
            fi
          done
          ;;
        3)
          echo "⚠️  Adopting conflicting files..."
          for pkg in $PACKAGES; do
            [ -d "$pkg" ] && stow --adopt --target="$HOME" "$pkg" && echo "  ✓ Adopted $pkg"
          done
          echo "⚠️  Check 'git diff' in your dotfiles - files may have changed"
          ;;
        4)
          echo "⚠️  Overriding all conflicts..."
          for pkg in $PACKAGES; do
            [ -d "$pkg" ] && stow --override='.*' --target="$HOME" "$pkg" && echo "  ✓ Override $pkg"
          done
          ;;
        *)
          echo "❌ Invalid choice"
          exit 1
          ;;
      esac
    else
      echo "📦 No packages found to manage"
    fi
    
    echo "✅ Done"
  '';
}
