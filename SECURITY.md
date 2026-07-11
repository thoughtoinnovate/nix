# Security policy

## Credentials

Do not report or commit real credentials. If a credential is accidentally
committed, revoke it immediately and remove it from Git history before making
the repository public.

This flake intentionally does not read `~/.secrets`, `.env`, cloud credential
files, SSH private keys, or tool login databases. Authentication remains local
to each provisioned machine.

The bootstrap script downloads the Nix installer only from
`https://nixos.org/nix/install`, requires TLS, and asks before executing it.
Review the script before running it in managed organization environments.

## Supply chain

The lock file pins flake inputs. Review changes to `flake.lock`, overlays,
Homebrew taps, and substituter keys before merging updates. Downstream private
repositories should not publish build outputs containing internal material to
public binary caches.

The installer composes the bundled sanitized dotfile template and performs a
Stow simulation before linking. It never adopts or overwrites conflicting
files. Home Manager packages and Homebrew casks are community distribution
definitions; review their source and hashes rather than assuming vendor
endorsement.

Profile flakes and Nix-backed components are copied into the Nix store during
evaluation. Never commit or reference secret values from a profile. Schema 2
private Git components are cloned outside the Nix store, but they still must
contain private settings only—not passwords, tokens, or keys. The
provider-neutral bootstrap uses ordinary Git authentication already configured
on the machine and does not persist credentials itself.
