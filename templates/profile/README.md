# Personal configuration profile

For setup, planning, profile management, updates, and uninstall examples, see
the public [HomeWeave quick-start guide](https://github.com/thoughtoinnovate/nix/blob/main/QUICKSTART.md).

This private repository extends HomeWeave from `thoughtoinnovate/nix` (or a
private work distribution) and its sanitized defaults. `home-weave.json` is
the canonical package, platform, profile, environment, and dotfile manifest.

Put personal, non-secret files under `dotfiles/custom` using their final home
paths, for example `dotfiles/custom/.config/git/config`. The included
`.gitkeep` only preserves the empty directory in Git and is never linked into
the home directory. Keep credentials in local credential stores or a secret
manager even when the profile repository is private.

Use `home-weave plan` to build safely and `home-weave apply` to activate. The
activation wrapper `./setup.sh` also restores the profile on Linux or Apple
Silicon macOS.

Before activation installs the global command, use the repository-local
launcher, which supplies the required Nix feature flags automatically:

```sh
./home-weave plan
./home-weave apply
```

`./setup.sh plan` and `./setup.sh apply` delegate to the same launcher.
Execute these scripts directly; do not prefix them with `sh`,
because they require Bash.

To preview or remove the managed environment safely:

```sh
./home-weave uninstall --dry-run
./home-weave uninstall
```

Uninstall keeps this repository and its backups unless repository archival is
explicitly selected. It never removes Nix itself.
Credentials must remain outside this repository and the Nix store.

The active machine selection is stored under the Git-ignored `.state`
directory. Add packages, shells, platform packages, and dotfile component names
to the selected profile in `home-weave.json`. Custom profiles may extend any existing profile and
select `packageGroups` from `python`, `data-jupyter`, `go`, `rust`, `java`,
`web`, `cloud`, and `desktop`.

Profiles may also declare provider-owned applications under their operating
system. The key must
match a provider registered by the distribution; package IDs are inherited and
deduplicated just like Nix packages and groups:

```json
"platforms": {
  "macos": {
    "packages": {
      "providers": {
        "company-self-service": ["approved-editor", "approved-vpn"]
      }
    }
  }
}
```

HomeWeave never substitutes a different provider when the declared provider is
unavailable.

Successful activations write immutable JSON receipts under
`.state/receipts/`; inspect the latest activation with `./home-weave status`
or `./home-weave status --json`. Manage definitions with `profile list`,
`show`, `create`, `diff`, `switch`, and `delete`.

Setup can select an existing profile or create a custom one. To preview and
then make another existing profile active:

```sh
./home-weave plan --profile work
./home-weave apply --profile work
```

Only a successful `apply` changes `.state/active-profile`; `plan` is read-only.
The selected profile's own `primaryShell` is used during activation.

## Dotfile components

HomeWeave follows the normal GNU Stow package layout. Every first-level
directory under `dotfiles/` is a component and everything below it mirrors
`$HOME`:

```text
dotfiles/neovim/.config/nvim/init.lua -> ~/.config/nvim/init.lua
```

Select it with `"dotfiles": ["neovim"]`. Child profiles inherit components,
add new names uniquely, and can use `dotfilesRemove` for an intentional
replacement. HomeWeave composes the generation and invokes Stow with `$HOME`
as its target and `--no-folding`. Credentials and secret values must remain in
local secret stores.

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
