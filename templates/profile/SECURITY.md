# Personal profile security

Do not commit passwords, tokens, API keys, private keys, cloud credentials,
database connection strings, `.env` files, or machine login databases. This
applies even when the repository is private.

Keep credentials in the operating-system keychain, AWS SSO or credentials
store, `aws-vault`, an organization-approved secret manager, or another local
credential store. Committed configuration may refer to a profile or secret
name but must not contain its value.

Before publishing changes, review `git diff --cached` and the complete list
from `git status`. If a secret is committed, revoke it immediately before
rewriting Git history.
