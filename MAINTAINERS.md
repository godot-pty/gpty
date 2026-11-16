# Maintainers

gPTY is maintained by one person. This file is the maintainer roster that LFX Insights and the OpenSSF Baseline assessment read.

| Name | GitHub | Role | Scope |
| --- | --- | --- | --- |
| Neil Pathare | [@1nv1n](https://github.com/1nv1n) | Maintainer and administrator | Repository, organization, releases, security reports |

## Access

- The maintainer holds the **organization owner** and **repository admin** roles for `godot-pty/gpty`.
- The organization requires two-factor authentication for every member.
- Repository write access is granted, reviewed and revoked by the organization owner. There are no other maintainers or members with write access today.
- Security reports arrive through GitHub private vulnerability reporting; see [SECURITY.md](SECURITY.md) for the scope and response targets.

## Automation app

| App | Installation | Permissions | Purpose |
| --- | --- | --- | --- |
| `gpty-bot` (app ID 5789319) | `godot-pty/gpty` (selected repositories) | Contents: write; Pull requests: write; Metadata: read (plus `repository_license_policy: read`; remove) | Pushes the `0.<minor>.x` integration branch and opens the release pull request against `main`; it cannot bypass `main` protection and never approves or merges. |

The app is an installation, not a maintainer or collaborator: the release flow needs contents write, pull-request write and metadata read, with no administration permission and no organization-owner access. The installation is restricted to `godot-pty/gpty`; one extra permission (`repository_license_policy: read`) remains, and `scripts/bot-token --check` warns about it. Remove it in the app settings. Its private key is stored outside the repository (local: `~/.config/gpty/gpty-bot.pem`, mode 0600; Actions: the `GPTY_BOT_PRIVATE_KEY` secret), rotated from the app's settings, and removed by uninstalling the app. The organization owner installs and removes it.

## Adding or removing a maintainer

A second maintainer is added by the organization owner after sustained contributions and review, and is recorded in this file before repository access changes. A maintainer who steps down, or who is inactive for 90 days, is removed from the GitHub teams and this table by the organization owner.

## Succession

The maintainer names a successor in this file before granting them write access. If the maintainer is unavailable for more than 90 days and no successor is named, the project is archived rather than left drifting; the last release remains available and the repository history is the handover record. [AGENTS.md](AGENTS.md), [ROADMAP.md](ROADMAP.md), [CHANGELOG.md](CHANGELOG.md), [RELEASING.md](RELEASING.md) and the agent execution checklist at `.omp/skills/release/SKILL.md` are the operating record.
