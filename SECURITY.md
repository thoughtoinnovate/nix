# Security policy

## Credentials

Do not report or commit real credentials. If a credential is accidentally
committed, revoke it immediately and remove it from Git history before making
the repository public.

This flake intentionally does not read `~/.secrets`, `.env`, cloud credential
files, SSH private keys, or tool login databases. Authentication remains local
to each provisioned machine.

## Supply chain

The lock file pins flake inputs. Review changes to `flake.lock`, overlays,
Homebrew taps, and substituter keys before merging updates. Downstream private
repositories should not publish build outputs containing internal material to
public binary caches.
