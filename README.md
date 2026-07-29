```text

██╗  ██╗ ██████╗ ███╗   ███╗███████╗██╗    ██╗███████╗ █████╗ ██╗   ██╗███████╗
██║  ██║██╔═══██╗████╗ ████║██╔════╝██║    ██║██╔════╝██╔══██╗██║   ██║██╔════╝
███████║██║   ██║██╔████╔██║█████╗  ██║ █╗ ██║█████╗  ███████║██║   ██║█████╗
██╔══██║██║   ██║██║╚██╔╝██║██╔══╝  ██║███╗██║██╔══╝  ██╔══██║╚██╗ ██╔╝██╔══╝
██║  ██║╚██████╔╝██║ ╚═╝ ██║███████╗╚███╔███╔╝███████╗██║  ██║ ╚████╔╝ ███████╗
╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝ ╚══╝╚══╝ ╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝

/\/\  reproducible homes, layered cleanly
```

# HomeWeave

Reusable Nix profiles, overlays, and activation tools for a consistent terminal and
development environment on Linux and macOS.

New user? Start with the [HomeWeave quick-start guide](./QUICKSTART.md).

Supported systems are `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`, and
`x86_64-darwin`. The primary pin is the official `nixpkgs-unstable` branch.
Because upstream 26.11 removed Intel Darwin, that one system uses the final
official, security-maintained `nixpkgs-26.05-darwin` branch.
Darwin currently also takes Starship from that official 26.05 pin because the
July 11 unstable linker fix has not yet reached `cache.nixos.org`; this narrow
fallback prevents local Rust/linker compilation and can be removed after a
reviewed unstable output is verifiably substituted.

This repository is the public base layer. Personal and organization-specific
repositories should consume it as a flake input and add their own overlays or
modules. Credentials and proprietary source code do not belong here.

The base includes a shell-neutral `~/.home_weave_profile` template for managed
non-secret environment variables and an optional, machine-local
`~/.home_weave_secrets` convention. `home-weave-env` safely renders their
literal `NAME=VALUE` entries for Bash, Zsh, Fish, or Nushell and requires the
secrets file to be user-owned, non-symlinked, and mode `0600`. HomeWeave never
adopts or records that secrets file; see the quick-start guide for usage.

## Profiles

- `base`: HomeWeave, selected shells, Git, Stow, Starship, Neovim, and its
  minimal editor/runtime dependencies.
- `development`: everything in `base`, all four supported shells, `jq`, tmux,
  lazygit, ShellCheck, shfmt, OpenCode, NVM, and the Java/Gradle SDKMAN toolchain.
- opt-in groups: `ai`, `python`, `data-jupyter`, `go`, `rust`, `java`, `web`,
  `cloud`, and `desktop`. Profiles merge inherited `packageGroups` and
  `packages.nix` uniquely.
- `darwin`: nix-darwin integration and optional Homebrew installation of the
  Ghostty macOS application.

`home-weave.json` is the only user-facing profile source. Common Nix packages
and dotfiles stay at profile level; native package managers and reviewed
providers are explicit under the target platform:

```json
{
  "$schema": "https://raw.githubusercontent.com/thoughtoinnovate/nix/main/schemas/home-weave-v4.schema.json",
  "schemaVersion": 4,
  "distribution": {"name": "my-home-weave"},
  "defaults": {"profile": "work"},
  "profiles": {
    "work": {
      "extends": "development",
      "shells": ["fish", "zsh"],
      "primaryShell": "fish",
      "exclude": {"dotfiles": [], "packageGroups": [], "plugins": [], "packages": {"nix": []}},
      "dotfiles": ["neovim", "starship"],
      "packages": {"nix": ["jq", "vault"]},
      "platforms": {
        "macos": {
          "packages": {"homebrew": {"formulae": ["example"], "casks": []}},
          "plugins": {
            "example-provider": {"enabled": true, "groups": [], "items": ["approved-app"]}
          }
        },
        "linux": {
          "distributions": {
            "ubuntu": {"packages": {"apt": ["example"]}},
            "arch": {"packages": {"pacman": ["example"]}}
          }
        }
      }
    }
  }
}
```

The public `base`, lean `development`, internal tool bundles, and optional
group package selections have one canonical source at
`catalogs/packages.json`. Its versioned schema is
`schemas/package-catalog-v1.schema.json`. Nix modules and overlays interpret
that catalog; they do not maintain separate copies of the package lists. This
is the only supported catalog format; legacy Nix package-list catalogs are not
loaded.

Each package has exactly one declared source; HomeWeave never silently falls
back to another manager or raw installer. Prefer a Nixpkgs package or a
declarative, checksum-pinned official vendor artifact. The declarative package
catalog supports archives, raw executables, and macOS DMGs, so those artifacts
remain immutable Nix-store packages with normal profile rollback and removal.
Use providers only when an external lifecycle owner such as enterprise MDM
must perform the installation or the software cannot be represented as an
immutable package.

Every profile declares `extends`; use `null` for a standalone profile. A child
can strictly exclude inherited dotfiles, groups, Nix packages, native packages,
or provider item IDs through `exclude`. Misspelled and non-inherited exclusions
stop evaluation. Excluding and adding the same dotfile component explicitly
replaces the inherited component.

Dotfiles use native GNU Stow package structure. For example,
`dotfiles/neovim/.config/nvim/init.lua` maps to
`~/.config/nvim/init.lua`. The profile only names `"neovim"`; HomeWeave
composes inherited components and uses `$HOME` as the Stow target.

On macOS, Ghostty can be selected explicitly from the official Homebrew cask;
the nix-darwin module can manage the same cask declaratively. Linux users may
add Ghostty explicitly. Default configuration comes from the sanitized dotfile
template bundled in this repository.

## Test the base

```sh
nix flake show
nix flake check
nix develop .#java21
```

Development shells never modify dotfiles, change the login shell, or launch a
different interactive shell automatically.

CI exercises all four supported systems on native GitHub Actions runners.
macOS coverage runs on native Apple Silicon and Intel runners, not in Docker.
Debian, Ubuntu, and Arch Linux additionally run the complete setup, apply,
status, and uninstall lifecycle in isolated containers.

Run one Linux fixture locally, or omit `--distro` to run all three:

```sh
bash tests/containers/run-e2e.sh --distro ubuntu
bash tests/containers/run-e2e.sh
```

The container fixtures require a running Docker daemon.

## Bootstrap a machine

Generate a reviewable personal child directly from GitHub:

```sh
DIST='github:thoughtoinnovate/nix'
nix --accept-flake-config \
  --extra-experimental-features 'nix-command flakes' \
  --refresh \
  run "${DIST}#home-weave" -- \
  setup --root "$HOME/.home-weave" --profile development --no-apply
```

The command creates one user-owned, private Git repository:

```text
~/.home-weave/
├── .gitignore, README.md, SECURITY.md
├── flake.nix and flake.lock # pinned parent distribution
├── home-weave               # local launcher used before activation
├── home-weave.json          # this child's profile delta
├── packages.json            # optional local package definitions
├── overlay.nix              # optional local Nix overrides
├── dotfiles/custom/         # local additions or replacements only
├── .state/                 # generated and Git-ignored
└── backup/<timestamp>/     # local and Git-ignored
```

Use another root when personal and work editions must coexist:

```sh
home-weave setup --root ~/.company-home-weave
```

Non-interactive choices can be supplied explicitly:

```sh
home-weave setup --profile development \
  --package awscli2 --package terraform --no-apply
```

When `--shell` is omitted, HomeWeave detects the invoking shell (falling back
to the login shell), makes it primary, and retains the profile's other declared
shells. An explicit comma-separated `--shell` remains an override.

Setup detects the platform, resolves named profile inheritance, shows inherited
packages, supports multi-select and pinned Nixpkgs search, scans selected
dotfiles, and preflights Stow before activation. Existing roots are replaced
only after confirmation and are retained under `backup/<timestamp>`; failures
restore the original root.

When setup is interactive, selecting an existing profile offers to use it
directly or create a child profile. New profiles extend `base` by default;
enter `development` at the parent prompt to inherit the lean development
profile. Non-interactive setup uses `--profile NAME --extends base|development`.

When setup starts from an organization distribution, the generated repository
contains one delta profile extending the selected parent profile. Parent
dotfiles and packages remain in their pinned flake input and are materialized
through the Nix store during evaluation; they are not copied into the child.
Run the launcher directly from that minimal repository with:

```sh
cd "$HOME/.home-weave"
./home-weave config validate
./home-weave plan
./home-weave apply --yes
```

After a successful apply and a fresh shell, the inherited CLI is on `PATH`, so
use `home-weave plan`, `home-weave apply --yes`, and `home-weave status` from
any directory. For an explicit local flake invocation, use
`nix run .#home-weave -- plan --root "$PWD" --profile development`; a shell
path such as `/some/profile#home-weave` is not an executable command.

Add a child dotfile component only for a new or overridden home-relative path.
Parent layers compose first, so a child file at the same destination is the
intentional final override. Secrets remain outside every layer in the local
`~/.home_weave_secrets` file.

The optional-package checklist uses arrow keys to move, Space to toggle any
number of entries, and Enter to confirm the selected set.

The preceding package-group checklist uses the same controls. Select `skip`
to add no optional toolchain groups. Supplying one or more `--group NAME`
options bypasses that interactive group chooser.

Nixpkgs search results show the declared upstream homepage, Nixpkgs maintainer
handles, license, and description in a preview panel. Nixpkgs repository trust
does not by itself verify the upstream publisher. HomeWeave shows a green
publisher label only when the package name, pinned metadata, source provenance,
and a reviewed rule in `lib/reviewed-publishers.json` match. The preview and
final confirmation show the reviewed evidence; all other publishers remain
red and unverified.
Users may search multiple keywords in one setup session; selections accumulate
across searches and are shown in one final provenance table for confirmation
before the profile is changed. Packages already supplied by the selected
profile (including inherited base/development defaults and selected shells)
are identified as already included, omitted from the selector, and are not
written to `packages.nix` again.

Build without activation, apply, update inputs, restore, or synchronize Git:

```sh
home-weave plan
home-weave apply --yes
home-weave update
home-weave profile list
home-weave profile show development
home-weave profile create work --extends development
home-weave profile diff work
home-weave profile work
home-weave profile switch work
home-weave profile remove work
home-weave status
home-weave status --profile=development
home-weave status --json
home-weave logs
home-weave logs --latest --tail 100
home-weave snapshot create ~/home-weave-snapshot
home-weave snapshot restore ~/home-weave-snapshot --root ~/.home-weave-restored
home-weave restore git@example.org:owner/home-weave-profile.git
home-weave sync
home-weave uninstall
```

During interactive `setup`, select `base`, `development`, an existing custom
profile, or `+ create custom profile`. Non-interactively, a new profile can be
created with `setup --profile work --extends development`. To preview and then
switch an existing repository to another profile:

```sh
~/.home-weave/home-weave plan --profile work
~/.home-weave/home-weave apply --profile work
```

`plan` performs a Nix dry-run and reports compressed download size, expanded
closure size, substitutions, local builds, unfree packages, and unsupported
packages. Downloads over 1 GiB and local compilation require confirmation.
Operations that mutate a repository are serialized with a per-root lock.

`plan` never changes the active selection. A successful `apply --profile NAME`
records that profile as active, so later `plan` and `apply` commands use it by
default. Profiles configure the same user account and home directory; switching
replaces the dedicated HomeWeave package generation and reconciles the generated Stow links.
Receipts under `.state/receipts/` record packages, applications, dotfiles,
changes, cache/build decisions, and rollback generations; `latest` references
the most recent successful activation.

`install.sh` is the internal activation backend. Users should use the
`home-weave` command.

After a successful apply, HomeWeave installs a small user-local launcher at
`~/.local/bin/home-weave`. It records the selected setup root, so plain
`home-weave plan`, `apply`, and `update` target that profile even when setup
used a custom root. An explicit `--root` or `HOME_WEAVE_ROOT` still takes
precedence.

`home-weave profile` lists every available profile. `home-weave profile NAME`
is a guided shorthand for `home-weave profile switch NAME`: it plans first and
asks before activation. `home-weave profile remove NAME` switches an active
local profile to its parent, reconciles profile-owned packages, applications,
and dotfiles, and then removes its local definition. Inherited profiles remain
defined by their parent distribution, while pre-existing or provider-retained
applications remain under that provider's lifecycle.

`home-weave status` shows all available profiles, declared and last-installed
package counts, and retained Nix closure size without building inactive
profiles. Use `home-weave status --profile=NAME` for one profile. Closure sizes
include shared dependencies and therefore must not be added together as
exclusive disk usage.

The launcher remembers one active repository root. Within that repository,
select a named profile explicitly, for example `home-weave apply --profile
development`. When working with another HomeWeave repository, use
`home-weave apply --root /path/to/other-root --profile NAME`; `--root` takes
precedence without changing the active-root launcher.

`home-weave uninstall`, `uninstall --profile NAME`, `uninstall --all`, and
`uninstall --nuke` can remove the dedicated HomeWeave package profile, unlink only
the active HomeWeave Stow generation, restore missing pre-adoption files,
and remove only applications proven by HomeWeave receipts. Normal and `--all`
keep the repository; `--nuke` requires typed confirmation and removes only the
HomeWeave root. These scoped uninstall modes do not remove Nix or run global
garbage collection. Every mode supports `--dry-run`. Uninstall also removes dangling symlinks whose
normalized targets belong to the selected root's `.state/dotfiles/current`;
active and unrelated links are retained. Use `uninstall --nuke --dry-run` to
preview a complete reset and `uninstall --nuke` to perform it.

For an intentionally broader reset, preview the separate command first:

```sh
~/.home-weave/home-weave nuke-all --dry-run
~/.home-weave/home-weave nuke-all
```

`nuke-all` removes the selected HomeWeave root and its recorded effects, clears
HomeWeave-owned external config/data/state/cache directories, removes dedicated
HomeWeave package-profile links, and removes recognizable managed or legacy
HomeWeave dotfile links (including dangling links restored from an older
adoption backup). It then clears the current user's default modern or legacy
Nix profile, deletes its
old generations, removes `~/.cache/nix`, `~/.nix-channels`,
`~/.nix-defexpr`, and `~/.nix-profile`, and finally runs
`nix-collect-garbage -d`. If `XDG_CACHE_HOME` or `XDG_STATE_HOME` is set,
their corresponding Nix paths are used too.

Unrelated dotfiles and symlinks are retained. Provider-managed applications
whose lifecycle is external are also retained; `nuke-all` removes HomeWeave's
receipts and local state for them, not the applications themselves.

This operation can remove Nix packages unrelated to HomeWeave and permanently
removes rollback generations. It always displays the resolved paths and
requires typing `NUKE ALL USER NIX STATE` exactly; `--yes` cannot bypass
that confirmation. It does not uninstall the Nix daemon, delete `/nix`, or
remove the Nix installer. If the selected HomeWeave root has an activation
receipt that does not own the current HomeWeave package generation, cleanup stops
before deleting that root or the receipt evidence.

## Create a personal or work profile

Personal users normally let `home-weave setup` create the repository. To build
a redistributable private work edition, initialize the distribution template:

```sh
nix flake new -t github:thoughtoinnovate/nix#distribution company-home-weave
cd company-home-weave
nix flake lock
```

Change `distributionUrl` in the generated flake, add company profiles under
`profile-overlay`, and register private plugins. Employees with
GitLab SSH authentication can then run:

```sh
nix --accept-flake-config --refresh run 'git+ssh://git@example.org/owner/home-weave-distribution.git#home-weave' -- setup
```

The work edition pins this public core, supplies work profiles and plugins,
and re-exports the same CLI. Employees do not run personal setup first. The
versioned provider contract supports inventory, search, install, update, and
remove operations with a displayed plan and explicit confirmation. Enterprise
MDM implementations and catalogs belong only in private repositories; the
public core contains only the generic provider interface.

## Plugins and lifecycle ownership

Plugins are versioned distribution descriptors, while profile selection stays
in `home-weave.json`. A child can enable a plugin, replace its inherited
selection, disable it with `enabled: false`, or exclude it by name. The plugin
descriptor—not the child profile—owns two lifecycle policies: whether packages
are removed or retained, and whether plugin state is removed or retained.
Successful receipts persist those policies and `uninstall`, `--all`, and
`--nuke` enforce them.

The inherited `development` profile enables the public `nvm` plugin. It pins
the official `nvm-sh/nvm` release by SHA-256, loads its implementation directly
from the immutable HomeWeave profile in Bash and Zsh, and keeps mutable Node
versions and aliases under `~/.nvm`. Upstream NVM does not support Fish or
Nushell; those shells continue using the profile.s Nix-managed
Node.js package. Uninstall removes HomeWeave's managed loader but retains
user-created Node versions and aliases under `~/.nvm`.

The public `sdkman` plugin is cross-platform and uses only fixed, reviewed
official artifacts in the Nix store. The inherited development selection seeds
Corretto 11/17/21/26 and Gradle. Profiles that need the reviewed full toolchain
may explicitly add Coursier, sbt, Scala, and Scala CLI. Mutable SDKMAN state is isolated below
`~/.local/share/home-weave/<profile>/plugins/sdkman` and removed on final
uninstall. No SDKMAN bootstrap script is piped from the network. Use
`home-weave plugin list`, `plugin show sdkman`, and `plugin status sdkman` to
inspect availability and active lifecycle metadata.

Provider manifests may set `failurePolicy = "best-effort"` for optional
software whose operational failures must not block the remaining profile.
Missing items and plan/install failures are recorded as degraded warnings and
retried on a later plan or apply. The default is `strict`. Invalid manifests,
unsafe identifiers, malformed or ambiguous inventory, and required publisher
verification failures always remain fatal. Set
`requirePublisherVerification = true` when every installed item from that
provider must retain verified publisher evidence.

Child flakes call `lib.mkHomeWeaveDistribution`. The constructor resolves
parent profiles, creates reproducible per-profile package environments, inherits parent
adapters, and exports the standard apps and checks. Exact vendor archives and
macOS DMGs can use `schemas/declarative-packages-v1.schema.json`; the builder
enforces HTTPS URLs, reviewed hosts, fixed SHA-256 hashes, and declarative
installation layouts. Use `macos-app` for GUI applications and `macos-cli-app`
for CLI tools shipped inside an app bundle; the CLI layout retains resources under
`libexec` without exposing a GC-sensitive top-level `.app`. Declare platform-independent source archives once under
`artifacts.default`. Use `artifacts.<nix-system>` for native binaries that
differ by OS or CPU. Nix selects the exact system entry first and otherwise
uses `default`; the former `platforms` package-catalog field is unsupported.

The built-in `native-official` provider supports official Homebrew
formulae/casks on macOS, configured official Debian/Ubuntu APT repositories,
and official Arch Pacman repositories. Unknown Linux distributions remain
Nixpkgs-only. Third-party taps, AUR, and third-party APT/Pacman repositories
are rejected; privileged plans print the exact command before confirmation.
When Homebrew is present, the shared shell configuration loads its official
`shellenv` output (with equivalent Nushell environment setup). This makes
declared Homebrew formulae available in Bash, Zsh, Fish, and Nushell without
requiring a terminal-specific PATH configuration.

For software whose vendor documents `curl ... | sh`, use the reusable
`home-weave-verified-installer` framework instead of copying that pipeline.
An immutable distribution catalog must pin the HTTPS URL and SHA-256, list the
reviewed official hosts and publisher, and record its review date. The helper
downloads to a temporary file, verifies it, supports content inspection, uses
a sanitized environment, refuses root execution, and requires an explicit
provider approval token before `apply`. It never pipes network content to a
shell. Distributions can consume `lib.verifiedInstaller.program` or the
`home-weave-verified-installer` package from this flake.

The same framework accepts declarative `macos-dmg-app` catalog entries for
vendor applications published through a checksum manifest. The generic
provider verifies the selected artifact hash and configured Apple Team ID,
installs only to a reviewed per-user destination, and reports the application
through the normal provider receipt lifecycle. Product URLs, selectors, paths,
and publisher identities remain catalog data; product-specific shell handlers
are not required.

GUI applications launched from Finder, Spotlight, or a desktop menu generally
do not source interactive shell files. Configure those applications with an
explicit Nix executable path or wrapper instead of relying on `.zshrc` or an
equivalent file. Keep credentials and tokens in a local credential store or
secret manager, never in a dotfile component.

Profile defaults live in `lib.setup.defaults`; `--shell` and `--profile`
override them. Dotfile layers are composed in their declared order before Stow
links one generated tree. Later regular files override earlier files,
directories merge, and file/directory type conflicts stop setup. The previous
linked generation is restored if activation fails.

Schema version 2 supports tool-specific components. Each ordered layer has a
`nix`, `path`, or `git` source and one or more `{ from, to, mode }` entries.
`merge` overlays files; `replace` clears a non-root target such as
`.config/nvim` first. Private Git sources require an exact 40-character commit
and are cloned outside the Nix store. This allows a work profile to retain all
public dotfiles while replacing only Neovim or another tool from GitLab.

`./setup.sh` reapplies locked versions. Profile owners use
`./setup.sh --update` to refresh public inputs, review and commit `flake.lock`,
and separately update exact private component SHAs. Consumers receive reviewed
changes through Git pull or central bootstrap.

## Consume the overlays

```nix
{
  inputs.nix-base.url = "github:thoughtoinnovate/nix";
  inputs.nixpkgs.follows = "nix-base/nixpkgs";

  outputs = { nix-base, nixpkgs, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          nix-base.overlays.base
          nix-base.overlays.development
        ];
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "vscode" ];
      };
    in
    {
      devShells.${system}.default = pkgs.mkJava21DevShell { };
    };
}
```

Downstream work repositories should apply overlays in this order:

```text
base -> development -> work
```

Use the same model for dotfiles. This repository owns the sanitized common,
shell, terminal, and editor defaults, while a personal or organization Git
component merges or replaces selected targets. Manual
multi-repository Stow remains available for additive, non-conflicting files:

```sh
stow --dir="$HOME/.work-dotfiles" --target="$HOME" --no-folding work
```

A downstream installer wrapper should run this base installer first, then
clone its own pinned work-dotfiles repository and simulate its Stow operation.
If two layers claim the same path, Stow stops; make an explicit downstream fork
when replacement rather than extension is required.

## Dedicated package profile

HomeWeave resolves each profile into one immutable Nix package environment and
activates it through the dedicated profile at
`${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-weave`. This
profile is separate from the user's general `~/.nix-profile`, so rollback and
uninstall remain scoped to packages owned by HomeWeave.

Package activation and Stow dotfile activation are one HomeWeave transaction.
A later failure restores both the previous package generation and the previous
dotfile generation. Bash, Zsh, Fish, and Nushell prepend the stable HomeWeave
profile `bin` directory while preserving host operating-system paths.

Home Manager modules and consumers are intentionally unsupported. An active
legacy `home-manager` profile must be removed before plan or apply; HomeWeave
will stop without changing state when it detects one.

## Version pinning and package sources

`flake.lock` pins one Nixpkgs snapshot, so all packages are reproducible as a
set. Do not separately pin each package unless a documented compatibility or
security issue requires it. Inspect critical versions with:

```sh
nix eval --raw .#packages.$(nix eval --impure --raw --expr builtins.currentSystem).neovim.version
```

At this repository's current lock, Neovim is `0.12.4`. Updating `flake.lock`
updates the package snapshot and must be reviewed like a dependency upgrade.

Nixpkgs packages are maintained build recipes, not a guarantee that each
vendor publishes or endorses the Nix package. OpenCode is instead pinned from
its official fixed-hash release artifacts for every supported system. Other CLI
packages such as Codex and Claude Code should be reviewed in Nixpkgs before each
lock update. Ghostty's optional Linux package comes from Nixpkgs; its macOS application
comes from Homebrew's official cask. HomeWeave controls package-profile installation and activation but does not change the upstream source selected by Nixpkgs.

## Dotfiles and secrets

The bundled `dotfiles/` directory contains the complete sanitized default,
including Neovim. It must remain free of usernames, machine-specific home
paths, hostnames, credentials, and organization-only configuration. Store
secrets locally in platform credential stores or a secret manager and load
them explicitly only on machines that need them.

## macOS

Import `nix-base.darwinModules.default` in a nix-darwin configuration:

```nix
{
  imports = [ nix-base.darwinModules.default ];

  homeWeave.darwin = {
    enable = true;
    primaryUser = "alice";
    installGhostty = true;
  };
}
```

Homebrew must already be installed. Automatic Homebrew update, upgrade, and
cleanup are disabled so activation does not unexpectedly change unrelated
applications.

## Security

- Commit `flake.lock` and review lock-file updates. Public inputs are accepted
  only from the reviewed NixOS, nix-darwin, flake-utils, and
  nix-systems repositories, with an exact revision and `narHash`.
- HomeWeave Nix invocations use only `https://cache.nixos.org/`, require the
  official `cache.nixos.org-1` signature, keep `require-sigs = true`, and
  request sandboxed local builds. Generated launchers and distribution
  templates apply the same policy before evaluating their flakes.
- Direct vendor packages require HTTPS, an explicitly reviewed official host,
  an exact version, and a fixed SHA-256. Mutable URLs and third-party binary
  caches are rejected.
- Never put tokens, passwords, private keys, or credential contents in Nix
  expressions. Evaluated values can enter the world-readable Nix store.
- Authenticate to GitHub, cloud providers, and AI tools after provisioning a
  machine.
- Keep organization-only packages and settings in a private downstream repo.
- Use only reviewed overlays, flake inputs, Homebrew taps, and binary caches.

These controls protect package provenance, integrity, and build isolation; they
cannot prove that upstream or Nixpkgs code is vulnerability-free. Lock updates
still require source review and security-advisory checks before deployment.

`sandbox`, `require-sigs`, and trusted-key changes are restricted daemon
settings. HomeWeave requests the secure values, but a non-trusted user cannot
override a weaker system daemon configuration. Administrators should set
`sandbox = true`, `require-sigs = true`, and the official cache key in
`/etc/nix/nix.conf`; HomeWeave still fixes its own substituter list to the
official cache.

## License

HomeWeave is available under the [MIT License](./LICENSE).

## Lifecycle

The supported package outputs are `terminal-tools` and `development-tools`. The installer
automates safe Stow linking from public and private configuration components.
