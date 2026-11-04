# Support

## Where to ask

- **Bug reports and feature requests**: open an issue with the matching form.
- **Security vulnerabilities**: do not open a public issue; follow [SECURITY.md](SECURITY.md).
- **Usage questions and design discussions**: use GitHub Discussions.

## What is supported

- The latest release and `main` receive correctness and security fixes; see the supported-versions table in [SECURITY.md](SECURITY.md).
- Linux is the primary target. macOS and Windows 11 builds are shipped, but are less exercised than Linux.
- Third-party CLIs, editors, agents and plugins that run inside a pane are supported by their own projects.

## What is not supported

- Backports to older minor versions, except a critical fix where feasible.
- Sandboxing: a pane runs as your user with your permissions. See the threat model in [SECURITY.md](SECURITY.md).
- Platform code signing; releases ship `SHA256SUMS` and build-provenance attestations instead.
