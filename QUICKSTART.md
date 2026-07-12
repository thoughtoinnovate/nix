# HomeWeave quick start

HomeWeave installs a reproducible terminal environment with Nix and manages
dotfiles with Stow. It does not replace Nix, change your login shell, or remove
unrelated applications.

## 1. Create your HomeWeave repository

Run the setup application:

```sh
nix run github:thoughtoinnovate/nix#home-weave -- setup
```

The interactive setup creates `~/.home-weave`, asks which shell and profile to
use, and offers to adopt selected existing dotfiles. Choose `--no-apply` when
you want to review everything before installation:

```sh
nix run github:thoughtoinnovate/nix#home-weave -- setup --no-apply
```

For a non-interactive lean development profile:

```sh
nix run github:thoughtoinnovate/nix#home-weave -- setup \
  --profile development --shell zsh --no-apply --yes
```

## 2. Review the plan

Use the repository-local command after setup:

```sh
~/.home-weave/home-weave plan
```

The plan does not activate anything. It reports downloads, expanded size,
binary-cache substitutions, local builds, and any unfree or unsupported
packages. Review unexpected local builds before continuing.

## 3. Apply the configuration

```sh
~/.home-weave/home-weave apply
```

HomeWeave records the profile as active only after Home Manager and Stow both
succeed. Open a new terminal when activation completes. The login shell is not
changed automatically.

Check what HomeWeave installed:

```sh
~/.home-weave/home-weave status
~/.home-weave/home-weave status --json
```

## Add optional toolchains

Keep `development` lean and add large toolchains through the interactive
package-group selector during setup. Use Space to toggle groups and Enter to
confirm, or choose `skip` to install none. For scripted setup, repeat
`--group`:

```sh
home-weave setup --profile work --extends development \
  --group python --group go --group cloud --no-apply
```

Groups can also be changed later through `packageGroups` in
`~/.home-weave/nix/<profile>/profile.nix`:

```nix
{
  extends = "development";
  shells = [ "zsh" ];
  primaryShell = "zsh";
  packageGroups = [
    "python"
    "go"
    "cloud"
  ];
  nixPackages = [ ];
  homebrewCasks = [ ];
  allowUnfree = [ "terraform" ];
}
```

Available groups are:

- `python`: Python, debugpy, Black, Pyright, and Ruff.
- `data-jupyter`: Jupyter, notebook, ipykernel, jupytext, Pillow, and CairoSVG.
- `go`: Go, gopls, Delve, and golangci-lint.
- `rust`: Cargo, Rust, rust-analyzer, and Taplo.
- `java`: JDK 17, Gradle, JDT language server, and Google Java Format.
- `web`: JavaScript, TypeScript, YAML, and Markdown tooling.
- `cloud`: AWS CLI, Terraform, kubectl, and Minikube.
- `desktop`: VS Code. Add other desktop applications explicitly.

Run `plan` and `apply` again after editing a profile.

## Work with multiple profiles

```sh
~/.home-weave/home-weave profile list
~/.home-weave/home-weave profile create work --extends development
~/.home-weave/home-weave profile diff work
~/.home-weave/home-weave profile switch work
```

`profile switch` shows a plan first and records the new profile only after a
successful activation.

Inspect a profile or safely remove an unused definition:

```sh
~/.home-weave/home-weave profile show work
~/.home-weave/home-weave profile delete work
```

An active profile must be switched to its parent before deletion. Profiles
that still have children cannot be deleted.

## Update pinned packages

```sh
~/.home-weave/home-weave update
~/.home-weave/home-weave plan
~/.home-weave/home-weave apply
```

Review the `flake.lock` change before applying or committing it. If activation
fails, downloaded Nix store paths remain cached, while the active profile,
dotfiles, and latest successful receipt remain unchanged.

## Uninstall safely

Preview any uninstall first:

```sh
~/.home-weave/home-weave uninstall --dry-run
```

Common modes:

```sh
# Remove active HomeWeave effects but retain the repository and backups.
~/.home-weave/home-weave uninstall

# Switch an active child profile back to its parent.
~/.home-weave/home-weave uninstall --profile work

# Remove all active HomeWeave effects proven by ownership records.
~/.home-weave/home-weave uninstall --all

# Also delete the HomeWeave repository after typing the complete displayed
# phrase: DELETE /absolute/path/to/home-weave-root
~/.home-weave/home-weave uninstall --nuke
```

No uninstall mode removes Nix or performs global Nix store garbage collection.

## If something goes wrong

- Run `home-weave status` to inspect the last successful receipt.
- Run `home-weave plan` again after fixing a profile.
- Do not repeatedly apply a plan that requires an unexpected large local build.
- A message about another HomeWeave operation means setup, apply, update,
  switch, or uninstall is already running for that repository.
- A transient SQLite busy warning is safe when Nix continues and finishes; do
  not rewrite or restart the Nix database automatically.

HomeWeave state, receipts, generated configurations, and backups remain inside
the selected HomeWeave root. Keep credentials and secrets outside the profile
repository and dotfiles.
