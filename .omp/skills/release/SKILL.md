---
name: release
description: "Cut a gPTY release: execute the canonical process in RELEASING.md, including the agent-specific checkpoints, user approval gate, screenshot pass, and release verification."
---

# gPTY Release Execution

`RELEASING.md` at the repository root is the canonical release process. Read it
end to end before changing anything. This skill is the agent execution layer: it
records the checkpoints an agent must not skip, not a second runbook.

## Hard rules

- Do not commit or tag before the final review pause in `RELEASING.md` §7, and
  do not proceed without an explicit user OK.
- Do not merge the release PR until every required check is green: `ci-gate`,
  Secret scan and the four CodeQL analysis jobs on `main`; on a maintenance
  branch, its CI, CodeQL and Secret-scan runs.
- Do not force-move or delete a tag. The ruleset has no bypass; a bad tag means
  a new patch release, not a repaired history.
- Do not publish figures, screenshots or verification results you did not
  observe. The release notes are derived from the commit range.

## Before starting

- Read `RELEASING.md`, the target `docs/content/docs/roadmap/vX.Y.md` section,
  and the previous release's changelog page.
- Confirm the target version, previous tag, whether the line is active (`main`)
  or in maintenance (`release/vX.Y`), clean tree, signing key, `gpty-bot` token
  and a graphical session for screenshots.
- Confirm each of the four crates (`gpty-core`, `gpty-ipc`, `gpty-plugin`,
  `gpty`) carries a crates.io Trusted Publisher config for `godot-pty/gpty`,
  workflow `release.yml` and environment `release`; without it
  `publish-crates` fails before publishing anything.
- Run `./scripts/check-github-settings` (read-only; maintainer `gh`) before the
  release and after any ruleset or environment change.
- Run `./scripts/ci-check`; a green local run is the baseline, not proof of the
  Windows runtime legs.

## Agent checkpoints

- **Commit analysis:** run the range and `fix-forensics` once; classify each
  commit into the changelog/roadmap/blog table. Do not run a second analysis.
- **Cost table:** `./scripts/measure-cost --check` and `--record` need a Linux
  GPU session and a `./scripts/build` app. Run them when that hardware is
  available; the CI gate is `./scripts/measure-cost --stamp`, which requires the
  README to name the newest build in `docs/data/cost-history.json`, not the
  current crate version. The weekly `Bench` workflow reports the llvmpipe
  trend; it is telemetry, never a release gate.
- **Screenshots:** use `scripts/screenshot-gpty` and the private sandbox. Run a
  vision sanity pass and fix real defects. Feature screenshots come from
  `--state` states, never from a GUT run. If capture is impossible, report it
  and ask the user for the image.
- **Review pause:** present the changelog, blog draft, screenshots and
  `/tmp/gpty-release-body.md`; wait for the user's explicit OK.
- **Release execution:** follow `RELEASING.md` §8–§10. Push the release-prep
  branch through `scripts/bot-push`, open the PR with `scripts/bot-pr --base
  main` (or the maintenance branch), wait for the active line's required checks
  (on a maintenance branch, for its CI, CodeQL and secret-scan runs) to be
  green, approve, then `gh pr merge --auto --merge` (the merge queue) or
  `gh pr merge --merge` before the queue exists. Never click **Update branch**
  and never run `gh pr update-branch`. Then create and verify the signed tag on
  `main` (or on the maintenance branch), and push it over **HTTPS with the bot
  token**, not the SSH origin: git opens the remote connection before the
  pre-push hook, and the ~6-minute gate outlives GitHub's SSH idle timeout, so
  the SSH push dies with SIGPIPE (exit 141) after the hook passes. Confirm the
  tag with `git ls-remote --tags origin $RELEASE`.
- **Environment approval:** download `gpty-release-dist` (three archives plus
  `SHA256SUMS`) and measure the bytes before approving the `release`
  environment - `sha256sum -c`, both license files in every archive, `--version`
  from the linux binary, `scripts/check-macos-minos` on the macOS slices, and
  `zipinfo -l` on the macOS archive for one real dylib per FFmpeg library with
  the `<major>` and unversioned names as symlinks. Read the shipped archive,
  never the bundler's intent: v0.8.4's bundler created those aliases correctly
  and the artifact transport dereferenced them, so only the asset's own bytes
  are proof. Three jobs use the `release` environment now: `publish`,
  `publish-crates` and the chained `mcp-registry`; review the staged artifact
  before the first approval.
- **Verification:** verify checksums, both license files in every archive, the
  attestation's subject digest by the asset's own SHA-256 (that command can
  print nothing and exit 0), the macOS 10.13/11.0 dylib floor with
  `scripts/check-macos-minos`, and the macOS alias shape from the previous
  checkpoint. The tag now publishes the four crates through crates.io trusted
  publishing and chains the MCP registry; verify the four versions on crates.io
  and the registry entry instead of running `cargo publish` or
  `gh workflow run mcp-registry.yml` by hand. The AUR tail stays manual: an AUR
  commit without the key on the machine is validated with `makepkg` and
  reported, never claimed as published. Close the asset-set roadmap row.
- **A row only a release can prove stays open until the asset is measured.**
  Close it with the numbers from the shipped file (`zipinfo`, byte size,
  `--version`), not with the fix's description, and put the measurement in the
  row.

## Failure rules

- A red required check blocks the release; fix the source or prep and push
  again.
- A `publish-crates` failure with `400 ... No Trusted Publishing config found
  for repository` means a per-crate crates.io config is missing. Add it for all
  four crates, then re-run the failed job; do not `cargo publish` by hand.
- `gh run watch` can exit non-zero on a transient API error. Confirm with
  `gh run view <id> --json status,conclusion` before calling a run failed.
- A workflow bug in the tagged tree is fixed by the next patch tag. Do not
  change `main` and assume the existing tag's workflow will pick it up.
- If a post-publish check fails, fix forward with a patch. The tag stays.
