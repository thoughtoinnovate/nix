# Personal configuration profile

This repository extends `thoughtoinnovate/nix` and its bundled sanitized
dotfile template. Edit `overlay.nix`, `home.nix`, and `dotfiles/custom`, then
commit `flake.lock`.

Put personal, non-secret files under `dotfiles/custom` using their final home
paths, for example `dotfiles/custom/.config/git/config`. The included
`.gitkeep` only preserves the empty directory in Git and is never linked into
the home directory. Keep credentials in local credential stores or a secret
manager even when the profile repository is private.

Run `./setup.sh` to restore the profile on Linux or Apple Silicon macOS.
Credentials must remain outside this repository and the Nix store.

Change `lib.setup.defaults` in `flake.nix` to select the default shell and
package profile. Command-line `--shell` and `--profile` options take priority.

## Private work components

Ordered components can come from pinned Nix inputs, local profile paths, or
exact private Git commits. Append a layer like this after `base` to replace
only Neovim while retaining public shell, Starship, and Ghostty files:

```nix
{
  name = "work-nvim";
  source = {
    kind = "git";
    url = "git@gitlab.com:company/work-nvim.git";
    rev = "0123456789abcdef0123456789abcdef01234567";
  };
  entries = [
    {
      from = ".";
      to = ".config/nvim";
      mode = "replace";
    }
  ];
}
```

Use `mode = "merge"` for partial overrides. Git content is cloned under the
framework data directory instead of being copied into the Nix store.
Authenticate to GitLab before setup. Private settings are supported, but
credentials and secret values must remain in local secret stores.

Desktop applications normally do not load interactive shell configuration.
Give GUI tools such as Claude Desktop an explicit Nix executable path (or a
small wrapper) and set non-secret selectors such as `AWS_PROFILE` in the app's
configuration. AWS credentials remain in `~/.aws/credentials`, the AWS SSO
cache, `aws-vault`, or another approved secret manager—not in profile layers.

## Updates

Normal setup reapplies the versions committed in `flake.lock`. Profile owners
can explicitly update the public Nix input, which includes the default
dotfiles:

```sh
./setup.sh --update
git diff flake.lock
git add flake.lock && git commit -m "Update system inputs"
```

Private Git layers remain pinned to their declared commit SHA. Update and
review that `rev` separately. Other users receive reviewed updates with
`git pull && ./setup.sh` or by rerunning central bootstrap.
