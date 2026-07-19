# HomeWeave profile: `@PROFILE@`

This repository is a small personal layer over the inherited `@PROFILE@`
profile. The parent distribution, its packages, plugins, scripts, and dotfiles
stay pinned by `flake.lock`; they are not copied here.

Generated from the selected `@PROFILE@` profile.

## How inheritance works

Nix downloads the parent distribution automatically from the URL and revision
recorded in `flake.lock`. You do not need to download or copy its dotfiles,
scripts, plugins, or package declarations into this repository.

`home-weave.json` stores only the child delta. Inherited values remain active
unless this profile explicitly adds or excludes something. Omitting `shells`
and `primaryShell` preserves the parent's shell configuration; passing
`--shell` during setup records an intentional local override. Parent updates
arrive only when you review and update `flake.lock`.

## Create another inherited profile

Create another delta without copying the current profile's resolved content:

```sh
./home-weave profile create new-tooling --extends @PROFILE@
vi home-weave.json
./home-weave config validate
./home-weave profile diff new-tooling
./home-weave profile switch new-tooling
```

## First run

Review the local delta, then plan and apply it with the repository launcher:

```sh
./home-weave config validate
./home-weave config show @PROFILE@
./home-weave plan
./home-weave apply --yes
```

Open a fresh shell after a successful apply. The inherited
`home-weave-cli` package then makes these shorter commands available:

```sh
home-weave status
home-weave plan
home-weave apply --yes
```

`--yes` confirms normal apply prompts. It never publishes Git changes and it
never bypasses the exact typed confirmation required by `nuke-all`.

## What to edit

- `home-weave.json` contains only this layer's profile delta. Add packages or
  exclude inherited entries here.
- `packages.json` defines checksum-pinned local packages that Nixpkgs and the
  parent distribution do not provide.
- `overlay.nix` contains local Nix overrides, including reviewed package
  version overrides.
- `dotfiles/custom/` contains only local, non-secret dotfile additions or
  replacements, using paths relative to the home directory. For example,
  `dotfiles/custom/.config/tool/config` becomes `~/.config/tool/config`.

### Replace an inherited package version

Use a unique local attribute and explicitly exclude the inherited attribute. For
example, replace inherited `jq` with `jq-homeweave` in the profile delta:

```json
"exclude": {
  "packages": {
    "nix": ["jq"]
  }
},
"packages": {
  "nix": ["jq-homeweave"]
}
```

Define that unique attribute in `overlay.nix`:

```nix
final: prev: {
  jq-homeweave = prev.jq.overrideAttrs (_old: {
    version = "VERSION";
    src = final.fetchFromGitHub {
      owner = "jqlang";
      repo = "jq";
      rev = "REVISION";
      hash = "sha256-HASH";
    };
  });
}
```

Replace the version, revision, and hash with reviewed upstream release values.
Using a new attribute avoids silently replacing the parent's package; the
explicit exclusion makes the effective package change visible in
`./home-weave profile diff @PROFILE@`.

An inherited dotfile component can be excluded in `home-weave.json` and a
local component can be added in its place. Keep passwords, access tokens,
private keys, account identifiers, and machine-specific secret values outside
this repository and the Nix store. Use a local credential store or approved
secret manager instead.

After editing, validate and preview before activation:

```sh
./home-weave config validate
./home-weave plan
./home-weave apply --yes
```

## Git workflow

Setup can configure `origin`, but leaves generated files uncommitted unless
you explicitly choose publication. Review before committing:

```sh
git status --short
git diff -- home-weave.json packages.json overlay.nix
git add .
git commit -m "Configure HomeWeave profile"
git push -u origin HEAD
```

Never commit `.state`, backups, result links, credentials, or secret files.
Use `./home-weave sync` for the later review-and-publish workflow when a remote
is configured.

## Recovery and removal

Preview the broad reset separately before confirming it interactively:

```sh
home-weave nuke-all --dry-run
home-weave nuke-all
```

`nuke-all` requires typing its displayed confirmation phrase exactly. It can
remove user Nix profile history, so use the narrower `home-weave uninstall`
commands when that is sufficient.

For complete setup, profile, and recovery guidance, see the public
[HomeWeave quick-start guide](https://github.com/thoughtoinnovate/nix/blob/main/QUICKSTART.md).
