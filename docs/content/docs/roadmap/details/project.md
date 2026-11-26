---
title: "Roadmap details - PROJECT"
weight: 900
build:
  list: never
---

Every PROJECT row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## PROJECT-1

**Rebranding & positioning** - README, docs landing, and CLI copy reposition gPTY as an ADE
("graphical ADE: a PTY foundation with a public API"). De-OMP the shipped defaults: "OMP Workspace"
profile renamed to "Agent Workspace"; `@gpty/omp-events` remains the first adapter, not the
identity. Name stays `gpty` (positioning, not renaming); display name is `gPTY`. Same commit:
updated every "OMP Workspace" reference in AGENTS.md (structure comment + Inspector/Reasoning
section) and the docs site.

Commits: d17bac7

## PROJECT-2

**Relicensed to GPL-3.0-or-later** - the core is GPLv3 with two section-7 additional permissions
covering the parts that must stay permissive (bundled plugins and extensions ship MIT, and the
shipped `godot/*.json` data defaults are Apache-2.0), so third-party plugins, adapters and pane
types are not forced to be GPLv3. `LICENSE-EXCEPTIONS.md` states both permissions, every crate and
package declares `GPL-3.0-or-later`, the release workflow stages both license files into every
archive (GPLv3 §4/§6), and the docs site renders the license text and the exceptions. Shipped
without a roadmap item - recorded here because the section is the release's record.

Commits: d17bac7

## PROJECT-3

**Nothing measures which defect classes recur, so each one is re-learned from `pitfalls.md`** - shipped
2026-11-15 (build 0.8.4). 402 of 1440 commits across all refs are fixes (401 of 1255 on `main`) and
nothing aggregated their causes: `docs/content/docs/agents/defect-classes.md` names 14 mechanisms
and pairs each with the control that catches it (6 have one, 8 are prose today),
`githooks/commit-msg` requires a `Cause:` trailer on every `fix`, and `scripts/fix-forensics` counts
classes, hotspots and undeclared fixes over a range (`--check` in the release step).
`skill://gpty-defect-review` owns the procedure. The retrospective baseline and the first control it
produced (the grid caps, declared in three places and now compared by
`the_grid_caps_are_declared_once`) are in `TEMP/fix-forensics-baseline.md`.

Commits: 29d3538

## PROJECT-4

**DCO sign-off is enforced** - added 2026-11-04: `githooks/commit-msg` refuses a commit without a
`Signed-off-by` trailer while keeping the Conventional Commits check; CONTRIBUTING documents
`git commit -s` and the PR template carries the checklist. Existing commits are grandfathered (the
hook applies to new commits). Tested with a missing-trailer message (refused) and a signed message
(accepted). OSPS LE-01.01.

Commits: 25adc85

## PROJECT-5

**Maintainer, governance and code-owner files** - added 2026-11-04:
[MAINTAINERS.md](https://github.com/godot-pty/gpty/blob/main/MAINTAINERS.md) records the maintainer,
the organization-owner and repository-admin access, the organization's 2FA requirement, how access
is granted, reviewed and revoked, and the succession rule;
[GOVERNANCE.md](https://github.com/godot-pty/gpty/blob/main/GOVERNANCE.md) records roles,
decision-making, access changes and the security escalation path;
[.github/CODEOWNERS](https://github.com/godot-pty/gpty/blob/main/.github/CODEOWNERS) assigns every
path to [@1nv1n](https://github.com/1nv1n), which makes the branch protection's code-owner
requirement meaningful. Linked from CONTRIBUTING and README. Verified against the live settings: one
organization owner/admin and org 2FA `true`. `python3 scripts/docs-check` passes. Closes OSPS
GV-01.01/02 and GV-04.01.

Commits: e986c20

## PROJECT-6

**Code of conduct, issue/PR templates and SUPPORT.md** - added 2026-11-04: `CODE_OF_CONDUCT.md`
(Contributor Covenant 2.1, with the private-advisory contact),
`.github/ISSUE_TEMPLATE/bug_report.yml` and `feature_request.yml`
(version/platform/reproduction/logs and problem/proposal), `.github/PULL_REQUEST_TEMPLATE.md`
(ci-check, test, docs, security checklist, DCO) and `SUPPORT.md` (where to ask, supported versions,
what is not supported). Both issue forms parse as YAML and the community profile now has the code of
conduct, contributing guide and templates.

Commits: 25adc85

## PROJECT-7

**The entry is discoverable where people actually browse** - the official registry is
machine-readable; humans search aggregators. Find which ones ingest the registry automatically
(PulseMCP, Glama, mcp.so, Smithery) and submit to the rest, and open one PR to `awesome-mcp-servers`
- same descriptor, no new claim to make. Free, permanent, and aimed at people already looking for
exactly this. Verification: the listing URLs, recorded here.

## PROJECT-8

**A release announces itself** - every release is announced nowhere; promotion is a manual act that
has already been skipped for fourteen tags. Fix: an `announce` workflow on `release: published` that
posts the changelog page for the tag to r/gPTY (the subreddit stays as the community channel) with
the release link and the demo cut, the body generated from
`docs/content/docs/changelog/v<version>.md` so an announcement cannot disagree with the release
notes, and the Reddit credential (script app: client id, secret and refresh token) held as an
Environment secret restricted to release tags, per the registry workflow's secret-handling rule.
Failure must not fail the release: the release is published before the post is attempted, so the job
reports and can be re-run by hand.

## PROJECT-9

**Dual-licensing framework and commercial proprietary exception** - the project is currently
licensed under GPL-3.0-or-later with Section 7 additional permissions (`LICENSE-EXCEPTIONS.md`);
enterprise adoption is blocked by corporate legal policies that forbid copyleft terms on developer
workstations and internal plugin ecosystems. Structure a dual-licensing model: the community edition
remains GPL-3.0-or-later, while a commercial enterprise license provides proprietary exemptions for
internal extensions, closed plugins, and proprietary deployment. Update `LICENSE-EXCEPTIONS.md` and
`README.md` with explicit commercial exception text and licensing contact guidance; add an automated
license header and SPDX tag validation test in CI to ensure third-party embedded components remain
compliant across both editions.

## PROJECT-10

**Community infrastructure** - plugin registry live, examples repo, community channel.

## PROJECT-11

**Launch criteria** - first-class agent adapters, example plugins, the reference workflow demo
(agent runs tests in a pane while the user watches in the GUI), and a working headless reattach
story - all verified before the public launch post.

## PROJECT-12

**Opt-in launch telemetry is the only install signal GitHub cannot provide** - the release badge
sums every asset's cumulative download count with no timestamps, uniques, referrers or geo, so it
counts the `SHA256SUMS` beside each archive, CI and mirror pulls, `gh release download`
confirmations and v0.7.0's 36-asset multiplication. Measured 2026-11-09: 431 across all releases,
while v0.8.0 (published 2026-11-06) showed 2 Linux, 0 macOS, 0 Windows and 0 checksum downloads - a
documented-path human verifies the sum, so those 2 are self or bot - and the repository drew 53
unique viewers and 3 releases-page views in 14 days (2,758 clones against 376 workflow runs are CI,
not people). Fix: move the existing startup update check (`update_checker.gd`, already one request
per launch) to an endpoint we own that returns the latest-release JSON, with a separate default-off
`cfg_telemetry` switch: when on, the request carries a locally generated, resettable UUIDv4 install
id plus app version, OS, arch and event name; when off, no id, and the update request is unchanged.
No IP, no machine id, no pane content; TLS with the existing timeout and body caps; aggregate
retention only; a privacy note in the settings UI and docs. Serverless (Cloudflare Worker + D1/KV
free tier) also stops every install spending GitHub's per-IP API rate limit. Answers what nothing
else does: unique installs, DAU/WAU, version and OS split, update adoption, and
download-to-first-launch conversion. Not scheduled because it creates an endpoint we must own and a
consent/privacy design; evidence to start: a decision that needs the number (a grant or application,
a launch retrospective, or a release whose download delta is cited).
