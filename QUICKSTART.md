# HomeWeave quick start

HomeWeave installs a reproducible terminal environment with Nix and manages
dotfiles with Stow. It does not replace Nix, change your login shell, or remove
unrelated applications.

## 0. Install Nix

If this command already succeeds, keep the existing installation and continue
to step 1:

```sh
nix --version
```

Use only the official Nix installer. On macOS, run:

```sh
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh
```

On Linux with systemd, the official recommended multi-user installation is:

```sh
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install \
  | sh -s -- --daemon
```

The installer explains its privileged operations before requesting `sudo`.
When it finishes, close Terminal completely, open a new terminal, and verify:

```sh
nix --version
nix --extra-experimental-features 'nix-command flakes' \
  eval --expr '1 + 1'
```

The second command should print `2`. HomeWeave commands enable `nix-command`
and flakes for each invocation, so changing global Nix configuration is not a
prerequisite. Official installation details and current platform notes are at
[nixos.org/download](https://nixos.org/download/) and
[nix.dev/install-nix](https://nix.dev/install-nix.html).

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

## Configure shared environment variables

HomeWeave provides one shell-neutral source for Bash, Zsh, Fish, and Nushell.
Put non-secret values in the managed `~/.home_weave_profile` file using strict
`NAME=VALUE` lines:

```dotenv
VAULT_ADDR=https://vault.example.com:8200
WORK_REGION=us-east-1
```

Values are literal; they are converted to each shell's native syntax without
evaluating shell expressions. A leading `export ` is accepted when migrating
an existing Bash profile.

For a secret that intentionally needs to be available to every process started
by your shell, create the separate machine-local file:

```sh
umask 077
touch ~/.home_weave_secrets
chmod 600 ~/.home_weave_secrets
$EDITOR ~/.home_weave_secrets
```

Use the same `NAME=VALUE` format. HomeWeave refuses to load this file when it is
a symlink, owned by another user, or not exactly mode `0600`; it never adopts,
backs up, commits, or records the file. Prefer a secret manager when a credential
should be exposed only to one command. Open a new shell after changing either
file.

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
  providerPackages = { };
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

Private work distributions can expose reviewed provider applications through
`providerPackages`, keyed by the provider name. HomeWeave inventories them,
shows the provider plan, and asks before each missing application is installed.
Provider trust and lifecycle policy are displayed separately from publisher
verification. Applications from a retain-policy MDM provider remain managed by
that MDM and are reported as retained during uninstall and nuke.

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

## Create or restore a portable snapshot

Export the active HomeWeave repository, resolved package/application inventory,
profiles, managed dotfiles, and canonical non-secret environment:

```sh
~/.home-weave/home-weave snapshot create ~/home-weave-snapshot
```

HomeWeave also inventories unrelated entries from the user's Nix profile, but
marks them informational and does not silently take ownership of or reapply
them. Shell `export NAME=VALUE` entries already present in the running
environment are converted into `.home_weave_profile`; machine-specific values
such as `PATH` are omitted.

Secret values are never copied. The snapshot contains only
`metadata/home_weave_secrets.example`, listing redacted variable names to
restore through an approved secret manager. On the same or a new machine:

```sh
home-weave snapshot restore ~/home-weave-snapshot \
  --root ~/.home-weave-restored
~/.home-weave-restored/home-weave plan
~/.home-weave-restored/home-weave apply
```

Restore requires an absent or empty target and does not activate by default.
Use `--apply` only when an interactive plan-and-confirm flow is desired.

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

Start with read-only diagnostics:

```sh
~/.home-weave/home-weave status
~/.home-weave/home-weave status --json
~/.home-weave/home-weave logs
~/.home-weave/home-weave logs --latest --tail 100
~/.home-weave/home-weave profile show development
nix profile list
```

Use your selected `--root` instead of `~/.home-weave` when applicable.
Operation logs are private local state under `.state/logs`, retain the latest
20 runs, and identify whether a failure occurred during providers, Nix
preflight, Home Manager, dotfile composition, Stow, or receipt creation.

### Apply reports an activation failure

Inspect the recorded phase and the end of the latest log before retrying:

```sh
~/.home-weave/home-weave status
~/.home-weave/home-weave logs --latest --tail 100
```

HomeWeave automatically reclaims dangling links only when their normalized
target exactly matches the file HomeWeave is about to manage. Unrelated or
mismatched links remain protected conflicts and are reported in the log.

### `nix-command` or flakes are disabled

Enable the features for that invocation:

```sh
nix --extra-experimental-features 'nix-command flakes' \
  run github:thoughtoinnovate/nix#home-weave -- setup
```

### The repository launcher does not exist

Setup was interrupted, rolled back, archived, or nuked before the launcher was
available. Confirm the root first:

```sh
ls -ld ~/.home-weave ~/.home-weave.uninstalled.* 2>/dev/null
```

Run setup again when the root is absent. Do not copy a launcher from another
profile because it is bound to its own repository root.

### Setup used `--no-apply`

This is not an error. It creates the repository without changing the active
environment. Continue later with:

```sh
~/.home-weave/home-weave plan
~/.home-weave/home-weave apply
```

### Plan says it is creating `.state/generated/flake.lock`

This is normal on the first plan for a generated local Home Manager consumer.
Review the pinned revisions shown in the output. Later plans reuse that lock
unless the profile is updated.

### Plan says `.state/generated/flake.nix` is not tracked by Git

Do not add `.state` to Git. Generated flakes, plans, receipts, and operation
state are intentionally ignored. This message means the repository launcher is
using an older HomeWeave release that passed a local directory to Nix as a
Git-filtered flake. It can affect `plan`, `apply`, `update`, or older
`uninstall`/`nuke` paths. Refresh setup from the current distribution, then
retry the operation.
Declining the optional initial Git commit is supported and is not the cause of
this error.

### An unfree package is refused

Repository trust and license freedom are separate. A verified upstream package
can still have an unfree license. Add only the reviewed package name to the
selected profile:

```nix
{
  nixPackages = [ "claude-code" ];
  allowUnfree = [ "claude-code" ];
}
```

Then run `plan` again. Do not enable every unfree package globally and do not
use `NIXPKGS_ALLOW_UNFREE=1` as a permanent workaround.

### Plan reports local builds

Home Manager generations, activation scripts, wrappers, and metadata are small
local derivations, so a nonzero count does not always mean a large source
compilation. Check the listed derivation names. HomeWeave asks for confirmation
when it detects a large download or substantial local toolchain build. Stop and
update the lock if Starship or another large Rust package unexpectedly lacks a
Darwin cache substitute.

Running `plan` repeatedly does not perform the build. Successful downloads from
an attempted `apply` remain cached for the next attempt.

### Activation fails

HomeWeave does not record the profile as active until Home Manager and Stow
both succeed. It restores the previous Home Manager generation, dotfile
generation, and adopted files after failure. Check status before retrying:

```sh
~/.home-weave/home-weave status
~/.home-weave/home-weave update
~/.home-weave/home-weave plan
```

Do not repeatedly apply the same lock when the plan shows a known failing large
local build.

### A dotfile destination conflicts

Setup offers these choices for existing configurations:

- `a`: adopt the local file into the private profile.
- `h`: use the HomeWeave version.
- `m`: merge with the local version winning conflicts.
- `s`: skip the destination.

HomeWeave saves adopted originals under `backup/`. Resolve the profile or
destination conflict and rerun `plan`; do not delete an unfamiliar file merely
to make Stow succeed.

### Packages are installed but commands are not found

Open a new terminal after a successful apply. HomeWeave intentionally does not
change the macOS login shell. Check both the receipt and command path:

```sh
~/.home-weave/home-weave status
command -v nvim
command -v starship
```

For POSIX shells, the Home Manager session variables can also be loaded with:

```sh
. "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
```

### Another HomeWeave operation is running

Setup, apply, update, profile switch, and uninstall are serialized per
repository. Wait for the displayed process to finish. HomeWeave removes a lock
automatically when its recorded process is no longer running; never delete a
lock while the process is active.

### Nix reports `database is busy` or `SQLITE_BUSY`

Treat it as transient only when Nix continues and finishes. If Nix exits, wait
for other Nix commands to complete and retry the same HomeWeave command. Never
rewrite the Nix database or restart the daemon automatically.

### Nuke confirmation does not match

Type the complete displayed phrase, including the absolute root path:

```text
DELETE /Users/name/.home-weave
```

Confirmation is checked before nuke changes anything. `--yes` cannot bypass
this protection.

### Commands remain after uninstall

First open a new terminal or run `rehash` in Zsh. Nuke removes active and
pending HomeWeave generations, but intentionally retains Nix and cached paths
in `/nix/store`. A cached package is harmless and is not active unless a
profile still references it.

For installations made by an older HomeWeave version, inspect ownership before
removing anything:

```sh
nix profile list
command -v home-weave
command -v claude
```

Run `home-manager uninstall` only when the remaining `home-manager-path` is
known to be the HomeWeave test environment. It removes the entire active Home
Manager environment and may otherwise remove unrelated user configuration.

HomeWeave state, receipts, generated configurations, and backups remain inside
the selected HomeWeave root. Keep credentials and secrets outside the profile
repository and dotfiles.
