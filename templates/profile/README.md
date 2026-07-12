# Personal configuration profile

This private repository extends HomeWeave from `thoughtoinnovate/nix` (or a
private work distribution) and its sanitized defaults. Named profiles live at
`nix/<name>/profile.nix`; personal dotfiles live under `dotfiles/custom`.

Put personal, non-secret files under `dotfiles/custom` using their final home
paths, for example `dotfiles/custom/.config/git/config`. The included
`.gitkeep` only preserves the empty directory in Git and is never linked into
the home directory. Keep credentials in local credential stores or a secret
manager even when the profile repository is private.

Use `home-weave plan` to build safely and `home-weave apply` to activate. The
compatibility wrapper `./setup.sh` also restores the profile on Linux or Apple
Silicon macOS.

Before activation installs the global command, use the repository-local
launcher, which supplies the required Nix feature flags automatically:

```sh
./home-weave plan
./home-weave apply
```

`./setup.sh plan` and `./setup.sh apply` delegate to the same launcher for
compatibility. Execute these scripts directly; do not prefix them with `sh`,
because they require Bash.
Credentials must remain outside this repository and the Nix store.

The active machine selection is stored under the Git-ignored `.state`
directory. Add packages, shells, casks, and unfree allow-list entries to the
selected `profile.nix`. Custom profiles may extend any existing profile.

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
