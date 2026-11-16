# Governance

## Roles

| Role | Who | Responsibilities |
| --- | --- | --- |
| Maintainer and administrator | Neil Pathare ([@1nv1n](https://github.com/1nv1n)) | Final decisions, repository and organization access, releases, security response |
| Contributor | anyone | Bug reports, documentation and pull requests under the terms in [CONTRIBUTING.md](CONTRIBUTING.md) |

The maintainer roster and access rules are in [MAINTAINERS.md](MAINTAINERS.md).

## Decisions

- The maintainer makes the final decision and records product work in [ROADMAP.md](ROADMAP.md).
- `main` is the release branch. Day-to-day work lands on the active integration branch (`0.8.x` for the 0.8 line, `0.9.x` for 0.9); every commit on `main` arrives through a release pull request from that branch, the maintainer approves it, and the release is tagged from `main`. The `gpty-bot` GitHub App opens the release pull request and may push the integration branch; it cannot bypass `main` protection.
- Security reports and their handling follow [SECURITY.md](SECURITY.md). A confirmed vulnerability is fixed on `main`, shipped in the next release, and disclosed in a private advisory published with the fix.
- A disagreement about a change is resolved in the issue or pull request; if it cannot be, the maintainer decides and gives the reason in the thread.

## Access

- The organization requires two-factor authentication.
- The maintainer holds organization-owner and repository-admin access. The `gpty-bot` GitHub App is installed on `godot-pty/gpty` (selected repositories) and the release flow needs only contents write, pull-request write and metadata read. One extra permission (`repository_license_policy: read`) remains; `scripts/bot-token --check` warns about it and it should be removed. The app has no administration permission and no bypass on `main`.
- Access is granted by the organization owner after a period of sustained contribution and review, recorded in [MAINTAINERS.md](MAINTAINERS.md), and revoked when the person steps down or is inactive for 90 days. The app's private key is stored outside the repository and rotated from the app's settings; the app is not a collaborator and has no organization-owner access.
- The `v*` tag ruleset, the `main` branch ruleset and classic branch protection are the release and review gates. The repository settings are the source of truth when this page and the settings disagree.

## Succession

The maintainer names a successor in [MAINTAINERS.md](MAINTAINERS.md) before granting them write access. If the maintainer is unavailable for more than 90 days and no successor is named, the project is archived rather than left unmaintained; the last release remains available and the repository history is the handover record.
