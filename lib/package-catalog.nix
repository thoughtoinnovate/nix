{
  base = [
    "clang"
    "curl"
    "fd"
    "git"
    "gnumake"
    "home-weave-cli"
    "home-weave-env"
    "neovim"
    "neovimPython"
    "nodejs"
    "ripgrep"
    "starship"
    "stow"
    "unzip"
  ];

  development = [
    "jq"
    "lazygit"
    "shellcheck"
    "shfmt"
    "tmux"
  ];

  groups = {
    python = [
      "python3"
      "python3Packages.debugpy"
      "black"
      "pyright"
      "ruff"
    ];
    data-jupyter = [
      "jupyter"
      "python3Packages.notebook"
      "python3Packages.ipykernel"
      "jupytext"
      "python3Packages.pillow"
      "python3Packages.cairosvg"
    ];
    go = [ "go" "gopls" "delve" "golangci-lint" ];
    rust = [ "cargo" "rustc" "rust-analyzer" "taplo" ];
    java = [ "jdk17" "gradle" "jdt-language-server" "google-java-format" ];
    web = [
      "eslint"
      "prettier"
      "typescript-language-server"
      "yaml-language-server"
      "marksman"
      "markdownlint-cli2"
      "vscode-langservers-extracted"
      "vscode-js-debug"
    ];
    cloud = [ "awscli2" "terraform" "kubectl" "minikube" ];
    desktop = [ "vscode" ];
  };
}
