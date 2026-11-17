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
- Do not merge the release PR until every required check is green, including
  both Windows legs, CodeQL and secret-scan.
- Do not force-move or delete a tag. The ruleset has no bypass; a bad tag means
  a new patch release, not a repaired history.
- Do not publish figures, screenshots or verification results you did not
  observe. The release notes are derived from the commit range.

## Before starting

- Read `RELEASING.md`, the target `docs/content/docs/roadmap/vX.Y.md` section,
  and the previous release's changelog page.
- Confirm the target version, previous tag, active integration branch, clean
  tree, signing key, `gpty-bot` token and a graphical session for screenshots.
- Run `./scripts/check-github-settings` (read-only; maintainer `gh`) before the
  release and after any ruleset or environment change.
- Run `./scripts/ci-check`; a green local run is the baseline, not proof of the
  Windows runtime legs.

## Agent checkpoints

- **Commit analysis:** run the range and `fix-forensics` once; classify each
  commit into the changelog/roadmap/blog table. Do not run a second analysis.
- **Cost table:** use `./scripts/build` and `./scripts/measure-cost --check`
  from a Linux GPU session; update the prose, ratio and stamp, then `--record`.
- **Screenshots:** use `scripts/screenshot-gpty` and the private sandbox. Run a
  vision sanity pass and fix real defects. Feature screenshots come from
  `--state` states, never from a GUT run. If capture is impossible, report it
  and ask the user for the image.
- **Review pause:** present the changelog, blog draft, screenshots and
  `/tmp/gpty-release-body.md`; wait for the user's explicit OK.
- **Release execution:** follow `RELEASING.md` §8–§10. Push the integration
  branch through `scripts/bot-push`, open the PR with `scripts/bot-pr`, wait for
  all required checks, approve and merge with a merge commit, then create and
  verify the signed tag.
- **Environment approval:** download `gpty-release-dist` (three archives plus
  `SHA256SUMS`) and measure the bytes before approving the `release`
  environment - `sha256sum -c`, both license files in every archive, `--version`
  from the linux binary, `scripts/check-macos-minos` on the macOS slices, and
  `zipinfo -l` on the macOS archive for one real dylib per FFmpeg library with
  the `<major>` and unversioned names as symlinks. Read the shipped archive,
  never the bundler's intent: v0.8.4's bundler created those aliases correctly
  and the artifact transport dereferenced them, so only the asset's own bytes
  are proof. `mcp-registry` uses the same environment.
- **Verification:** verify checksums, both license files in every archive, the
  attestation's subject digest by the asset's own SHA-256 (that command can
  print nothing and exit 0), the macOS 10.13/11.0 dylib floor with
  `scripts/check-macos-minos`, and the macOS alias shape from the previous
  checkpoint. Run the release tail (AUR, crates.io in dependency order, MCP
  registry dispatch, asset-set roadmap row); an AUR commit without the key on
  the machine is validated with `makepkg` and reported, never claimed as
  published.
- **A row only a release can prove stays open until the asset is measured.**
  Close it with the numbers from the shipped file (`zipinfo`, byte size,
  `--version`), not with the fix's description, and put the measurement in the
  row.

## Failure rules

- A red required check blocks the release; fix the source or prep and push
  again.
- `gh run watch` can exit non-zero on a transient API error. Confirm with
  `gh run view <id> --json status,conclusion` before calling a run failed.
- A workflow bug in the tagged tree is fixed by the next patch tag. Do not
  change `main` and assume the existing tag's workflow will pick it up.
- If a post-publish check fails, fix forward with a patch. The tag stays.
