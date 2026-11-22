# Security Policy

## Supported versions

Only the newest official release of LP (marked **Latest** on the project's GitHub **Releases**
page) gets security fixes. Releases marked **Pre-release** are betas, published for testing before
a version becomes official; a problem found in one is fixed in the next beta. Earlier releases stay
on the page so you can go back.

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

- when the repository is public, use GitHub's **Security → Report a vulnerability** (private
  vulnerability reporting);
- until then, contact the maintainer (LTF-Git-Dev) through GitHub.

Say what you found, how to reproduce it, and what it could let someone do. You'll get a reply as
soon as possible, and credit in the release notes if you'd like it.

## How LP protects you

- **Sandboxed** by macOS: LP can reach only the folder you chose and files you pick in open and
  save panels.
- **Nothing in a note runs:** links to apps, scripts or installers are shown in Finder instead of
  opened, links to other apps ask first, and paths from notes can't reach outside your workspace —
  not even through a folder that is a link elsewhere.
- **Secrets stay in the Keychain:** calendar and GitHub tokens are never written to files or logs.
  Sign-in uses PKCE in a private window; LP contains no client secrets.
- **Least privilege:** each connected service gets only the permissions LP needs
  ([docs/CONNECTED_ACCOUNTS.md](docs/CONNECTED_ACCOUNTS.md)); disconnecting removes LP's access.
- **Shared pages** are only updated or deleted when this Mac published them or you allowed it; a
  record found in a workspace folder is never trusted on its own.
- **Release builds** use the hardened runtime and carry no debugging entitlement. Before an app is
  published, the release script checks that its signature shows no email address and that nothing
  in it looks like a token or private key.
- **Polite with the services you connect:** when Google, Microsoft or GitHub asks LP to slow down,
  LP waits as long as asked (at most an hour) and says until when.
- **A checklist before every version:** secrets, who may change what, stored data, untrusted input,
  payments, rate limits, and a test that someone else can't change what is yours —
  [docs/SECURITY_CHECKLIST.md](docs/SECURITY_CHECKLIST.md), with the results for each version.

More detail: the security section of [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
