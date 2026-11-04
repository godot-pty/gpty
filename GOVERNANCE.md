# Governance

## Roles

| Role | Who | Responsibilities |
| --- | --- | --- |
| Maintainer and administrator | Neil Pathare ([@1nv1n](https://github.com/1nv1n)) | Final decisions, repository and organization access, releases, security response |
| Contributor | anyone | Bug reports, documentation and pull requests under the terms in [CONTRIBUTING.md](CONTRIBUTING.md) |

The maintainer roster and access rules are in [MAINTAINERS.md](MAINTAINERS.md).

## Decisions

- The maintainer makes the final decision and records product work in [ROADMAP.md](ROADMAP.md).
- Changes land through a pull request where practical. The repository's branch protection asks for a code-owner review and signed commits; because a solo maintainer cannot approve their own pull request, the maintainer's direct push is the current trunk-based path and is recorded here rather than hidden.
- Security reports and their handling follow [SECURITY.md](SECURITY.md). A confirmed vulnerability is fixed on `main`, shipped in the next release, and disclosed in a private advisory published with the fix.
- A disagreement about a change is resolved in the issue or pull request; if it cannot be, the maintainer decides and gives the reason in the thread.

## Access

- The organization requires two-factor authentication.
- The maintainer holds organization-owner and repository-admin access; there are no other members with write access today.
- Access is granted by the organization owner after a period of sustained contribution and review, recorded in [MAINTAINERS.md](MAINTAINERS.md), and revoked when the person steps down or is inactive for 90 days.
- The `v*` tag ruleset and the `main` branch protection are the release and review gates. The repository settings are the source of truth when this page and the settings disagree.

## Succession

The maintainer names a successor in [MAINTAINERS.md](MAINTAINERS.md) before granting them write access. If the maintainer is unavailable for more than 90 days and no successor is named, the project is archived rather than left unmaintained; the last release remains available and the repository history is the handover record.
