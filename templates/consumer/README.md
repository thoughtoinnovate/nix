# Consumer template

Edit `system`, `username`, and `home.homeDirectory` in `flake.nix`, then run:

```sh
home-manager switch --flake .#YOUR_USERNAME
```

For Apple Silicon macOS, use `aarch64-darwin` and a home directory under
`/Users`. A complete macOS system configuration should also import
`nix-base.darwinModules.default` through nix-darwin.
