# Private HomeWeave distribution

This flake extends `github:thoughtoinnovate/nix` without forking it. Change
`distributionUrl` and `distributionName` in `flake.nix`, add company profiles
under `profile-overlay/nix`, then register versioned software providers in the
`providers` list.

An extension manifest uses schema version 1, an executable store path, and a
capability list. Provider capabilities are `inventory`, `search`, `install`,
`update`, and `remove`. Add `command` to expose work-only behavior through
`home-weave extension <name> ...`. HomeWeave displays provider plans and asks
before lifecycle changes.

Provider inventory/search items may declare `publisher` and
`publisherVerified`. Set `publisherVerified = true` only when the organization
provider has actually verified the vendor identity; HomeWeave never infers
official status from a package name.

Employees authenticate to GitLab over SSH and run:

```sh
nix run 'git+ssh://git@gitlab.com/company/nix.git#home-weave' -- setup
```

Keep credentials and secrets outside this repository.
