# Private HomeWeave distribution

This flake extends `github:thoughtoinnovate/nix` without forking it. Change
`distributionUrl` in `flake.nix` and the distribution name in
`profile-overlay/home-weave.json`, then add profiles to that JSON manifest.
The flake stays small because `lib.mkHomeWeaveDistribution` resolves inherited
profiles, exports the normal apps/checks, and inherits parent adapters.

A provider descriptor uses schema version 2, an executable store path, a
removal policy, supported platforms, and a capability list. Capabilities may
include `catalog`, `inventory`, `search`, `install`, `update`, `remove`,
`status`, `snapshot`, and `command`. `catalog` lets setup offer optional groups
and individual items without provider-specific code in the public core.
HomeWeave displays provider plans and asks before lifecycle changes.

Provider inventory/search items may declare `publisher` and
`publisherVerified`. Set `publisherVerified = true` only when the organization
provider has actually verified the vendor identity; HomeWeave never infers
official status from a package name.

Users authenticate to their private Git host and run:

```sh
nix run 'git+ssh://git@example.org/owner/home-weave-distribution.git#home-weave' -- setup
```

Keep credentials and secrets outside this repository.

Every profile must declare `extends`; use `null` for a standalone profile.
Use the strict `exclude` object to remove inherited dotfiles, package groups,
Nix/Homebrew/APT/Pacman packages, or provider item IDs. An unknown exclusion
fails evaluation instead of silently doing nothing.

Exact vendor artifacts may be described in a private `packages.json` and
passed as `packageDefinitions`. The generic public builder accepts only
reviewed HTTPS hosts and fixed per-system hashes; product URLs and publisher
metadata remain private distribution data.
