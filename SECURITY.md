# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities responsibly. **Do not** open a public GitHub issue.

Email: `security@example.com` <!-- replace with your security contact -->

Include where possible:

- A description of the vulnerability and its impact
- Steps to reproduce
- Affected versions, components, or commit

## Response

- Acknowledgment within 48 hours of receipt
- Initial assessment within 5 business days
- Fix timeline based on severity; critical issues are prioritized immediately

## Security principles

- **No custom cryptography** — audited libraries only (aws-lc-rs, rustls). See
  [docs/crypto.md](docs/crypto.md).
- **No secrets in the repo** — configuration via environment / `.env` (gitignored).
- **Dependencies pinned and scanned** — exact versions in `Cargo.toml`, enforced by
  `cargo-deny`, Dependabot, and dependency-review in CI.
