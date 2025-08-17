{ ghostty, dotfiles }:

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
        ;;
        
      Darwin*)
        echo "🍎 Detected macOS - use nix-darwin for app integration"
        ;;
        
      *)
        echo "❓ Unknown operating system: $(uname -s)"
        ;;
    esac
  '';

  # Host OS terminal environment
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

  # Base shell creation function with Fish as default and universal env vars
  mkBaseDevShell = { 
    extraPackages ? [], 
    extraShellHook ? "", 
    useBash ? false  # Changed: now useBash instead of useFish, Fish is default
  }: 
    let
      # Universal environment variables (automatically exported by mkShell)
      commonEnvVars = {
        JAVA_HOME = "${final.corretto21}";
        EDITOR = "nvim";
        TERM = "xterm-256color";
      } // (if builtins.pathExists "${dotfiles}/starship.toml" 
           then { STARSHIP_CONFIG = "${dotfiles}/starship.toml"; }
           else {});
      
      # Common informational output
      commonInfo = ''
        echo "🖥️ Development environment loaded"
        echo "☕ Java: $(java -version 2>&1 | head -n1)"
        echo "📦 Editor: $EDITOR"
        echo "⭐ Starship config: ''${STARSHIP_CONFIG:-default}"
        echo "💡 Platform: ${final.system}"
        echo "🔧 Run 'setup-nix-desktop' for GUI app integration"
        echo ""
      '';
      
      # Bash/Zsh specific setup (fallback)
      bashSetup = ''
        ${commonInfo}
        echo "🚀 Running in Bash/Zsh mode"
        echo "💡 To use Fish (recommended): 'fish'"
        echo ""
        
        # Set XDG_DATA_DIRS for Linux desktop integration
        case "$(uname -s)" in
          Linux*)
            export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
            ;;
        esac
        
        # Initialize Starship for bash/zsh
        if [ -n "$BASH_VERSION" ]; then
          eval "$(starship init bash)"
        elif [ -n "$ZSH_VERSION" ]; then
          eval "$(starship init zsh)"
        else
          eval "$(starship init bash)"  # fallback
        fi
      '';
      
      # Fish specific setup (default)
      fishSetup = ''
        ${commonInfo}
        echo "🐠 Preparing Fish shell as default..."
        
        # Set XDG_DATA_DIRS for Linux desktop integration
        case "$(uname -s)" in
          Linux*)
            export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
            ;;
        esac
        
        # Create fish configuration directory
        mkdir -p ~/.config/fish/conf.d/
        
        # Create fish devshell config that inherits environment variables
        cat > ~/.config/fish/conf.d/nix-devshell.fish << 'EOF'
        # Auto-generated nix devshell config for Fish
        # Environment variables are automatically inherited from mkShell
        
        # Set XDG_DATA_DIRS for Linux desktop integration
        switch (uname -s)
          case Linux
            set -gx XDG_DATA_DIRS "$HOME/.nix-profile/share:$XDG_DATA_DIRS"
        end
        
        # Initialize starship prompt
        if command -v starship > /dev/null
          starship init fish | source
        end
        
        # Custom fish greeting for devshell
        function fish_greeting
          echo "🐠 Fish development shell ready!"
        end
        EOF
        
        # Also ensure fish configuration loads properly
        touch ~/.config/fish/config.fish
      '';
      
    in if useBash then
      # Bash mode (fallback)
      prev.mkShell (commonEnvVars // {
        buildInputs = final.baseDevShellPackages ++ extraPackages;
        shellHook = bashSetup + extraShellHook + ''
          echo "💡 Switch to Fish anytime: 'fish'"
        '';
      })
    else
      # Fish mode (default)
      prev.mkShell (commonEnvVars // {
        buildInputs = final.baseDevShellPackages ++ extraPackages;
        shellHook = fishSetup + extraShellHook + ''
          echo "🐠 Starting Fish shell..."
          exec fish
        '';
      });

  # Convenience functions
  mkBaseFishDevShell = { extraPackages ? [], extraShellHook ? "" }:
    final.mkBaseDevShell { inherit extraPackages extraShellHook; }; # Fish is now default

  mkBaseBashDevShell = { extraPackages ? [], extraShellHook ? "" }:
    final.mkBaseDevShell { inherit extraPackages extraShellHook; useBash = true; };

  # Helper to set fish as system default (for permanent setup)
  setup-fish-default = prev.writeShellScriptBin "setup-fish-default" ''
    echo "🐠 Setting up Fish as system default shell..."
    
    # Add fish to /etc/shells if not already there
    if ! grep -q "$(which fish)" /etc/shells 2>/dev/null; then
      echo "Adding fish to /etc/shells (requires sudo)"
      echo "$(which fish)" | sudo tee -a /etc/shells
    fi
    
    # Change user's default shell to fish
    echo "Setting fish as default shell for $USER (requires password)"
    chsh -s "$(which fish)"
    
    # Set up permanent starship configuration
    mkdir -p ~/.config/fish/conf.d/
    
    cat > ~/.config/fish/conf.d/starship.fish << 'EOF'
    # Permanent Starship configuration for Fish
    if command -v starship > /dev/null
      starship init fish | source
    end
    EOF
    
    # Set up environment variables permanently
    echo "# Permanent environment variables" >> ~/.config/fish/config.fish
    echo "set -gx EDITOR nvim" >> ~/.config/fish/config.fish
    echo "set -gx TERM xterm-256color" >> ~/.config/fish/config.fish
    
    if [ -f "${dotfiles}/starship.toml" ]; then
      echo "set -gx STARSHIP_CONFIG ${dotfiles}/starship.toml" >> ~/.config/fish/config.fish
    fi
    
    echo "✅ Fish configured as system default!"
    echo "💡 Restart your terminal or run: exec fish"
  '';
}
