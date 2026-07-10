# Personal configuration profile

This repository extends `thoughtoinnovate/nix` and
`thoughtoinnovate/dotfiles`. Edit `overlay.nix`, `home.nix`, and
`dotfiles/custom`, then commit `flake.lock`.

Run `./setup.sh` to restore the profile on Linux or Apple Silicon macOS.
Credentials must remain outside this repository and the Nix store.

Change `lib.setup.defaults` in `flake.nix` to select the default shell and
package profile. Command-line `--shell` and `--profile` options take priority.
