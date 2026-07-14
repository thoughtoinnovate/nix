# Public HomeWeave Agent Guide

## Scope

This repository is the reusable public HomeWeave framework. Keep company,
personal, machine, account, credential, private-provider, and private-repository
data out of it. Extensions own their provider catalogs and organization policy.

## Package source review

Review every newly added package before choosing its provider. Use this order:

1. A publisher-maintained official Nix package or flake, when the upstream
   publisher owns and supports that Nix definition.
2. An exact, versioned artifact from the publisher's official HTTPS host,
   declared through HomeWeave's fixed-artifact framework.
3. An official operating-system repository: Homebrew core/casks on macOS, or
   the configured official APT/Pacman repositories on Linux.
4. A pinned Nixpkgs recipe that fetches official upstream source or artifacts
   when none of the preceding publisher-owned channels is suitable.

Presence in the official Nixpkgs repository does not mean the upstream
publisher maintains the Nix package. Report repository trust, upstream
publisher identity, packaging ownership, provider, version, license, URL, and
verification evidence separately.

For direct artifacts, require an exact version, an allow-listed official host,
a fixed SHA-256, supported platform metadata, and the strongest available
publisher evidence such as a signed checksum, release signature, or Apple Team
ID. Do not use mutable `latest` URLs in a committed profile. Never execute
`curl | sh`, `curl | bash`, `wget | sh`, or equivalent. Download first, verify,
show the operation, request approval when state outside the Nix store changes,
and record ownership in the receipt lifecycle.

Third-party Homebrew taps, AUR, third-party APT repositories, unsigned vendor
installers, and unreviewed binary caches are not trusted defaults. Unfree
packages require an explicit package-scoped allow-list after license review.

## Public-data safety

Never commit usernames, home paths, hostnames, organization names, internal
URLs, account IDs, credentials, secrets, private repository URLs, or real secret
values. Test fixtures must use unmistakably synthetic values.

## Verification

Validate affected schemas and shell scripts, run `git diff --check`, run the
relevant focused tests, and run:

```sh
nix --extra-experimental-features 'nix-command flakes' flake check path:.
```

For a direct package, also build the exact package and run its non-mutating
version command. Confirm the resulting URL and checksum match publisher-owned
release evidence.
