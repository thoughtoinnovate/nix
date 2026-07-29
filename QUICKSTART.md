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

Start with the public distribution and generate a reviewable local profile:

```sh
DIST='github:thoughtoinnovate/nix'
nix --accept-flake-config \
  --extra-experimental-features 'nix-command flakes' \
  --refresh \
  run "${DIST}#home-weave" -- \
  setup --root "$HOME/.home-weave" --profile development --no-apply
```

For an organization profile, point the same entry point at its SSH flake URL.
This example uses placeholder coordinates; use the URL and profile supplied by
your organization:

```sh
DIST='git+ssh://git@example.org/team/home-weave-distribution.git?ref=main'
nix --accept-flake-config \
  --extra-experimental-features 'nix-command flakes' \
  --refresh \
  run "${DIST}#home-weave" -- \
  setup --root "$HOME/.company-home-weave" --profile work --no-apply
```

`DIST` identifies the parent distribution, `--root` is the local child
repository, and `--profile` selects the inherited profile. `--no-apply`
generates files without changing the active HomeWeave package generation. The
bootstrap-only `--refresh` asks Nix to refresh remote input metadata; omit it
from routine local plan and apply commands. Private SSH distributions require
working Git credentials.

Setup summarizes those choices before generating files and then prints a
numbered guide for reviewing the delta, validating configuration, planning,
applying, opening a fresh shell, and committing when desired. It detects the
invoking or login shell unless an explicit comma-separated `--shell` override
is supplied.

To publish the generated profile into an existing private repository, provide
the remote and target branch during setup:

```sh
nix --accept-flake-config --refresh run github:thoughtoinnovate/nix#home-weave -- setup \
  --remote git@example.org:team/home-profile.git \
  --branch home-weave \
  --no-apply
```

HomeWeave never creates the remote project. If the branch is missing, it is
configured as `origin`, but generated changes remain local and uncommitted by
default. Interactive setup offers publication with a default of no. Use the
explicit `--publish` option for a deliberate non-interactive commit and normal
push; `--yes` alone never publishes. Existing remote content is fetched and
shown before replacement, replacement requires an exact typed confirmation,
and HomeWeave never force-pushes. Local `.state`, backups, secret files, and
machine receipts are not published.

```sh
nix --accept-flake-config --refresh run github:thoughtoinnovate/nix#home-weave -- setup \
  --profile development --no-apply --yes
```

Use an explicit comma-separated `--shell` only to override detection.

`--accept-flake-config` applies HomeWeave's visible cache-signature and build
sandbox policy to this first invocation. Generated repository launchers export
the same policy directly, so later `home-weave` commands do not rely on a
silently trusted global cache.

## 2. Review the plan

Enter the generated repository and use its local launcher before activation:

```sh
cd "$HOME/.home-weave"
./home-weave config validate
./home-weave config show development
./home-weave plan
```

The plan does not activate anything. It reports downloads, expanded size,
binary-cache substitutions, local builds, and any unfree or unsupported
packages. Review unexpected local builds before continuing.

## 3. Apply the configuration

```sh
cd "$HOME/.home-weave"
./home-weave apply --yes
```

HomeWeave records the profile as active only after the dedicated package
profile and Stow both succeed. Open a new terminal when activation completes.
The login shell is not changed automatically.

Check what HomeWeave installed:

```sh
home-weave status
home-weave status --json
```

After a successful apply, open a fresh shell. The inherited
`home-weave-cli` package places `home-weave` on `PATH`, so routine commands can
use `home-weave plan`, `home-weave apply --yes`, and `home-weave status` from
any directory. Until then, keep using `./home-weave` from the profile root.

The inherited development profile supplies Bash, Fish, Zsh, Nushell, OpenCode,
the Java/Gradle SDKMAN toolchain, and the checksum-pinned NVM loader for Bash
and Zsh. HomeWeave removes that managed loader during
uninstall, but deliberately retains user-installed Node versions and aliases
under `~/.nvm`. Fish and Nushell use the profile's Nix-managed Node.js package.

## Configure shared environment variables

HomeWeave provides one shell-neutral source for Bash, Zsh, Fish, and Nushell.
Put non-secret values in the managed `~/.home_weave_profile` file using strict
`NAME=VALUE` lines:

```dotenv
VAULT_ADDR=https://vault.example.com:8200
EXAMPLE_REGION=us-east-1
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
`~/.home-weave/home-weave.json`:

```json
"work": {
  "extends": "development",
  "shells": ["zsh"],
  "primaryShell": "zsh",
  "exclude": {},
  "packageGroups": ["python", "go", "cloud"],
  "dotfiles": [],
  "packages": {
    "nix": [
      {"name": "terraform", "allowUnfree": true}
    ]
  }
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

To remove inherited content without editing its parent, use strict exclusions:

```json
"exclude": {
  "dotfiles": ["nvim"],
  "packageGroups": ["cloud"],
  "packages": {
    "nix": ["kubectl"],
    "homebrew": {"formulae": [], "casks": []}
  },
  "plugins": ["example-provider"]
}
```

Every excluded name must exist in the inherited profile. Use `"extends": null`
when a profile should inherit no selected packages or dotfiles.

Private work distributions can expose reviewed provider applications as
plugins. Select groups and individual applications under
`platforms.<os>.plugins`, keyed by the plugin name:

```json
"plugins": {
  "example-provider": {
    "enabled": true,
    "groups": ["essentials"],
    "items": ["approved-editor"]
  }
}
```

HomeWeave inventories them, shows the provider plan, and asks before each
missing application is installed.
Provider trust and lifecycle policy are displayed separately from publisher
verification. Applications from a retain-policy MDM provider remain managed by
that MDM and are reported as retained during uninstall and nuke.

The public SDKMAN plugin is enabled with an explicit reviewed candidate set.
It never runs `curl | bash`:

```json
"plugins": {
  "sdkman": {
    "enabled": true,
    "storage": "nix-store",
    "allowRuntimeChanges": true,
    "candidates": {
      "java": [
        {"version": "11.0.31-amzn", "default": false},
        {"version": "17.0.19-amzn", "default": false},
        {"version": "21.0.11-amzn", "default": true},
        {"version": "26.0.1-amzn", "default": false}
      ],
      "gradle": [{"version": "9.6.1", "default": true}]
    }
  }
}
```

`allowRuntimeChanges` permits later interactive `sdk install` commands in the
isolated plugin state. Those mutable additions are outside the pinned Nix
closure and are removed with plugin state during final uninstall.

## Add packages, applications, and dotfiles later

`home-weave.json` is the source of truth. Put cross-platform command-line
packages in its `packages.nix` field, select large public toolchains with
`packageGroups`, and declare OS-specific software under `platforms`:

```json
"work": {
  "extends": "development",
  "shells": ["fish"],
  "primaryShell": "fish",
  "exclude": {},
  "packageGroups": ["python"],
  "dotfiles": ["custom"],
  "packages": {
    "nix": ["bat", "jq"]
  },
  "platforms": {
    "macos": {
      "packages": {
        "homebrew": {"formulae": ["shellcheck"], "casks": ["firefox"]}
      },
      "plugins": {
        "example-provider": {"enabled": true, "groups": [], "items": ["approved-app"]}
      }
    },
    "linux": {
      "distributions": {
        "ubuntu": {"packages": {"apt": ["ripgrep"]}},
        "arch": {"packages": {"pacman": ["ripgrep"]}}
      }
    }
  }
}
```

Use only providers registered by the distribution. Raw URLs, third-party taps,
and `curl | sh` commands do not belong in a profile manifest; add them through
a reviewed provider with checksum/signature verification and a removal policy.

Dotfile components follow normal GNU Stow layout. The first directory is the
component name, and everything below it is the final path relative to `$HOME`:

```text
dotfiles/custom/.config/git/config  -> ~/.config/git/config
dotfiles/custom/.config/nvim/init.lua -> ~/.config/nvim/init.lua
dotfiles/custom/.local/share/example/data.json -> ~/.local/share/example/data.json
dotfiles/custom/.example-config    -> ~/.example-config
```

Select the component with `"dotfiles": ["custom"]`. Edit the source under the
repository's `dotfiles/` directory—not the live home path when `readlink` shows
that it points into `.state/dotfiles/current`. That directory is a generated
composition and can be replaced by the next activation.

For a repository created by setup, the normal edit loop is:

```sh
cd ~/.home-weave
$EDITOR home-weave.json
$EDITOR dotfiles/custom/.config/example/config
./home-weave plan
./home-weave apply
git diff
./home-weave sync
```

`sync` scans for secrets, shows the changes, and can commit/push when the
repository has a Git remote. Without a remote, use normal `git add`, `commit`,
and `push` after configuring one. Never commit `.home_weave_secrets`, cloud
credentials, SSO caches, `.state`, or backups.

Central distribution maintainers should edit and commit the distribution's
source component. To preview a dotfile-only change quickly without repeating
package downloads, copy that component into a disposable installed root and
apply it:

```sh
rsync -a --delete /path/to/source/dotfiles/custom/ \
  ~/.home-weave-test/dotfiles/custom/
~/.home-weave-test/home-weave plan
~/.home-weave-test/home-weave apply
```

When package selections are unchanged, Nix reuses its store and HomeWeave only
recomposes the dotfiles and refreshes Stow links. Rerun setup from the published
revision when verifying the complete installation that other users will get.

## Work with multiple profiles

```sh
~/.home-weave/home-weave profile list
~/.home-weave/home-weave profile create work --extends development
~/.home-weave/home-weave profile diff work
~/.home-weave/home-weave profile work
~/.home-weave/home-weave profile switch work
```

`profile switch` shows a plan first and records the new profile only after a
successful activation.

`profile NAME` is the shorter guided form of `profile switch NAME`. To remove
a locally defined profile and reconcile its active software back to the parent:

```sh
~/.home-weave/home-weave profile remove work
```

Inherited profiles cannot be deleted from a child repository. Switch away from
them or change the parent distribution instead. Pre-existing and
provider-retained applications remain owned by their provider.

Inspect package counts and retained disk usage for all profiles or one profile:

```sh
~/.home-weave/home-weave status
~/.home-weave/home-weave status --profile=work
```

Status never builds an inactive profile merely to calculate size. A profile
without a retained activation store path displays no disk size.

Validate the canonical manifest and inspect its Stow mappings at any time:

```sh
~/.home-weave/home-weave config validate
~/.home-weave/home-weave config show work
```

Dotfiles use the standard GNU Stow package layout. A component mirrors the
home directory, so `dotfiles/neovim/.config/nvim/init.lua` maps to
`~/.config/nvim/init.lua`. Select components with a short array such as
`"dotfiles": ["neovim", "starship"]`; no target registry is needed.

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

For a complete fresh reset, preview and then run the same command without
`--dry-run`:

```sh
~/.home-weave/home-weave uninstall --nuke --dry-run
~/.home-weave/home-weave uninstall --nuke
```

This scoped nuke removes the proven HomeWeave package profile, active Stow
generation, links owned by that root, recorded removable applications, restored
adoption backups, receipts, generated state, and the HomeWeave root. It retains
Nix, shared store paths, unrelated links and packages, and applications whose
provider retains lifecycle ownership. No uninstall mode performs global Nix
store garbage collection.

For an out-of-box reset of all user Nix state and all HomeWeave-owned external
artifacts, use the broader command instead:

```sh
~/.home-weave/home-weave nuke-all --dry-run
~/.home-weave/home-weave nuke-all
```

`nuke-all` also removes HomeWeave's config/data/state/cache namespaces,
dedicated HomeWeave profile generations, and recognizable legacy or dangling
HomeWeave links. It retains unrelated dotfiles and provider-managed apps whose
lifecycle is external.

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
preflight, package-profile activation, dotfile composition, Stow, or receipt creation.

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
  --refresh \
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

This is normal on the first plan for a generated local package consumer.
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

```json
"packages": {
  "nix": [
    {"name": "claude-code", "allowUnfree": true}
  ]
}
```

Then run `plan` again. Do not enable every unfree package globally and do not
use `NIXPKGS_ALLOW_UNFREE=1` as a permanent workaround.

### Plan reports local builds

HomeWeave package environments, wrappers, and metadata are small
local derivations, so a nonzero count does not always mean a large source
compilation. Check the listed derivation names. HomeWeave asks for confirmation
when it detects a large download or substantial local toolchain build. Stop and
update the lock if Starship or another large Rust package unexpectedly lacks a
Darwin cache substitute.

Running `plan` repeatedly does not perform the build. Successful downloads from
an attempted `apply` remain cached for the next attempt.

### Activation fails

HomeWeave does not record the profile as active until the HomeWeave package profile and Stow
both succeed. It restores the previous HomeWeave package generation, dotfile
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

HomeWeave-managed Bash, Zsh, Fish, and Nushell configuration adds the dedicated
package profile automatically. To use it in the current POSIX shell before
opening a new terminal, run:

```sh
export PATH="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave/bin:$PATH"
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
DELETE <the absolute HomeWeave root displayed above>
```

Confirmation is checked before nuke changes anything. `--yes` cannot bypass
this protection.

### Commands remain after uninstall

First open a new terminal or run `rehash` in Zsh. Nuke removes active and
pending HomeWeave generations, but intentionally retains Nix and cached paths
in `/nix/store`. A cached package is harmless and is not active unless a
profile still references it.

Current HomeWeave requires a schema-v2 receipt whose recorded dedicated package
generation and store target match the active HomeWeave package profile. It
removes that exact owned profile before deleting the root. A mismatch stops
nuke so ownership evidence is not destroyed.

Older Home Manager-based installations are unsupported. A new HomeWeave plan
or apply stops without changing state while an active legacy profile exists.
Inspect it before upgrading:

```sh
readlink "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
```

HomeWeave state, receipts, generated configurations, and backups remain inside
the selected HomeWeave root. Keep credentials and secrets outside the profile
repository and dotfiles.
