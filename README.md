# HomeWeave

Reusable Nix overlays and Home Manager modules for a consistent terminal and
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
- `development`: everything in `base`, plus `jq`, tmux, lazygit, ShellCheck,
  and shfmt.
- opt-in groups: `python`, `data-jupyter`, `go`, `rust`, `java`, `web`,
  `cloud`, and `desktop`. Profiles merge inherited `packageGroups` and
  `nixPackages` uniquely.
- `darwin`: nix-darwin integration and optional Homebrew installation of the
  Ghostty macOS application.

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

## Bootstrap a machine

Start the interactive personal setup directly from GitHub:

```sh
nix run github:thoughtoinnovate/nix#home-weave -- setup
```

The command creates one user-owned, private Git repository:

```text
~/.home-weave/
├── flake.nix and flake.lock
├── nix/<profile>/profile.nix
├── dotfiles/custom/<home-relative-path>
├── .state/                 # generated and Git-ignored
└── backup/<timestamp>/     # local and Git-ignored
```

Use another root when personal and work editions must coexist:

```sh
home-weave setup --root ~/.company-home-weave
```

Non-interactive choices can be supplied explicitly:

```sh
home-weave setup --profile development --shell fish,zsh \
  --package awscli2 --package terraform --no-apply
```

Setup detects the platform, resolves named profile inheritance, shows inherited
packages, supports multi-select and pinned Nixpkgs search, scans selected
dotfiles, and preflights Stow before activation. Existing roots are replaced
only after confirmation and are retained under `backup/<timestamp>`; failures
restore the original root.

When setup is interactive, selecting an existing profile offers to use it
directly or create a child profile. New profiles extend `base` by default;
enter `development` at the parent prompt to inherit the lean development
profile. Non-interactive setup uses `--profile NAME --extends base|development`.

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
written to `nixPackages` again.

Build without activation, apply, update inputs, restore, or synchronize Git:

```sh
home-weave plan
home-weave apply
home-weave update
home-weave profile list
home-weave profile show development
home-weave profile create work --extends development
home-weave profile diff work
home-weave profile switch work
home-weave status
home-weave status --json
home-weave logs
home-weave logs --latest --tail 100
home-weave snapshot create ~/home-weave-snapshot
home-weave snapshot restore ~/home-weave-snapshot --root ~/.home-weave-restored
home-weave restore git@gitlab.com:group/my-home-weave.git
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
replaces the Home Manager generation and reconciles the generated Stow links.
Receipts under `.state/receipts/` record packages, applications, dotfiles,
changes, cache/build decisions, and rollback generations; `latest` references
the most recent successful activation.

`install.sh` remains the compatibility activation backend. New users should use
the `home-weave` command.

`home-weave uninstall`, `uninstall --profile NAME`, `uninstall --all`, and
`uninstall --nuke` can remove the Home Manager environment, unlink only
the active HomeWeave Stow generation, restore missing pre-adoption files,
and remove only applications proven by HomeWeave receipts. Normal and `--all`
keep the repository; `--nuke` requires typed confirmation and removes only the
HomeWeave root. No mode removes Nix or runs global garbage collection. Every
mode supports `--dry-run`.

## Create a personal or work profile

Personal users normally let `home-weave setup` create the repository. To build
a redistributable private work edition, initialize the distribution template:

```sh
nix flake new -t github:thoughtoinnovate/nix#distribution company-home-weave
cd company-home-weave
nix flake lock
```

Change `distributionUrl` in the generated flake, add company profiles under
`profile-overlay/nix`, and register private software providers. Employees with
GitLab SSH authentication can then run:

```sh
nix run 'git+ssh://git@gitlab.com/company/nix.git#home-weave' -- setup
```

The work edition pins this public core, supplies work profiles and extensions,
and re-exports the same CLI. Employees do not run personal setup first. The
versioned provider contract supports inventory, search, install, update, and
remove operations with a displayed plan and explicit confirmation. IRU code
belongs only in the private work repository; the public core contains the
generic provider interface.

The built-in `native-official` provider supports official Homebrew
formulae/casks on macOS, configured official Debian/Ubuntu APT repositories,
and official Arch Pacman repositories. Unknown Linux distributions remain
Nixpkgs-only. Third-party taps, AUR, and third-party APT/Pacman repositories
are rejected; privileged plans print the exact command before confirmation.

For software whose vendor documents `curl ... | sh`, use the reusable
`home-weave-verified-installer` framework instead of copying that pipeline.
An immutable distribution catalog must pin the HTTPS URL and SHA-256, list the
reviewed official hosts and publisher, and record its review date. The helper
downloads to a temporary file, verifies it, supports content inspection, uses
a sanitized environment, refuses root execution, and requires an explicit
provider approval token before `apply`. It never pipes network content to a
shell. Distributions can consume `lib.verifiedInstaller.program` or the
`home-weave-verified-installer` package from this flake.

GUI applications launched from Finder, Spotlight, or a desktop menu generally
do not source interactive shell files. Configure those applications with an
explicit Nix executable path or wrapper instead of relying on `.zshrc` or an
equivalent file. For example, an AWS-backed Claude Desktop MCP server can set
`AWS_PROFILE` explicitly while the AWS SDK reads `~/.aws/config`, the local
credentials file, or the AWS SSO cache. Keep AWS credentials and tokens in
those local stores or a secret manager, never in a dotfile component.

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

## Home Manager

The quickest starting point is the included template:

```sh
nix flake init -t github:thoughtoinnovate/nix
```

Reusable modules are exported as:

```nix
nix-base.homeModules.base
nix-base.homeModules.development
```

Enable the development profile in a Home Manager configuration:

```nix
{
  imports = [ nix-base.homeModules.development ];
  homeWeave.development.enable = true;
}
```

The module installs only the shells selected through
`homeWeave.base.shells`, plus common packages and fonts. Home Manager
does not write shell, Starship, Ghostty, Git, or Neovim configuration; Stow is
the final owner of the composed files. Bash and Zsh both source a portable common
file rather than sourcing one shell's startup file from the other. Credential
files are not loaded automatically.

```nix
homeWeave.base = {
  enable = true;
  shells = [ "fish" ];
};
```

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
vendor publishes or endorses the Nix package. In particular, CLI packages such
as Codex, Claude Code, and OpenCode should be reviewed in Nixpkgs before each
lock update. Ghostty's optional Linux package comes from Nixpkgs; its macOS application
comes from Homebrew's official cask. Home Manager controls installation and
activation but does not change the upstream source selected by Nixpkgs.

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

- Commit `flake.lock` and review lock-file updates.
- Never put tokens, passwords, private keys, or credential contents in Nix
  expressions. Evaluated values can enter the world-readable Nix store.
- Authenticate to GitHub, cloud providers, and AI tools after provisioning a
  machine.
- Keep organization-only packages and settings in a private downstream repo.
- Use only reviewed overlays, flake inputs, Homebrew taps, and binary caches.

## Existing consumers

Compatibility package names such as `base`, `base-devshell`,
`terminal-tools`, and `development-tools` remain available. The installer
automates safe Stow linking from public and private configuration components.
