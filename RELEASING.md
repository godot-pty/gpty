# Releasing gPTY

This is the canonical release process. It is written for the maintainer and for
anyone preparing a release under their direction. The agent execution checklist
is `.omp/skills/release/SKILL.md`; it follows this page and records only the
agent-specific checkpoints, not a second runbook. Release authority is in
[MAINTAINERS.md](https://github.com/godot-pty/gpty/blob/main/MAINTAINERS.md).

A release is a pull request from the active integration branch (`0.8.x` for the
0.8 line) to `main`, the maintainer's approval, a merge commit, and a signed
annotated `vX.Y.Z` tag on `main`. `main` is release-only: feature pull requests
land on the integration branch.

## Preconditions

- A configured signing key (`git tag -v` must work) and the public key on
  GitHub. The tag ruleset has no bypass: every tag must be a signed annotated
  tag, and a bad tag cannot be moved or deleted. Cut the next patch instead.
- The `gpty-bot` app installed on `godot-pty/gpty` and
  `GPTY_BOT_PRIVATE_KEY` set; `./scripts/bot-token --check` passes. The bot
  pushes the integration branch and opens the release PR; it never approves or
  merges.
- A clean tree, the current integration branch, and the release's roadmap rows
  closed. Anything unshipped moves to the next chain in priority position with
  `(Deferred from vX.Y.Z.)`.
- `./scripts/ci-check` passes. Its Windows step cross-compiles only; the
  runtime legs (`windows-smoke`, GUT on Windows) exist only in CI and must be
  green on the release PR's head. Also run the
  [manual pre-release checklist](docs/content/docs/overview/testing.md#manual-pre-release-checklist)
  against a real GUI; it covers the renderer, input and live-session paths that
  headless tests cannot.
- A graphical session for the home screenshot and, on Linux with a GPU, the
  cost-table measurement. Both have documented fallbacks.

## 1. Analyze the commit range

Release notes come from the commit history, never from memory. Set the previous
release tag and inspect the range:

```bash
PREV=$(git describe --tags --abbrev=0 --match 'v*' HEAD^)
git log "$PREV"..HEAD --oneline
./scripts/fix-forensics --check --since "$PREV"
```

Classify every commit once into a single table: changelog bucket (`Added`,
`Changed`, `Fixed`), roadmap feature bullet (blank for non-features), and skip
marks. That one pass feeds the changelog, the roadmap and the blog. Skip
debug-logging churn, revert commits, lockfile/gitignore chores, and
agent-facing `AGENTS.md` edits. A fix saga gets one bullet describing the net
user-visible result. Note which commits produced user-visible UI changes; that
list is the feature-screenshot queue.

`fix-forensics` must exit 0. It checks every `fix` commit carries exactly one
`Cause:` trailer naming a class from the defect-class guide. The release
workflow runs the same check, so a missed trailer also stops the tag.

For the very first release, use `./scripts/fix-forensics --check`; there is no
previous tag.

## 2. Write the changelog

The release notes live on one page, `docs/content/docs/changelog/vX.Y.Z.md`,
with front matter (`title: "vX.Y.Z - YYYY-MM-DD"`, `weight`) and the compare
link `[Release on GitHub](https://github.com/godot-pty/gpty/compare/vPREV...vX.Y.Z)`.
`CHANGELOG.md` is an index only; prepend the link
`- [X.Y.Z - YYYY-MM-DD](docs/content/docs/changelog/vX.Y.Z.md)` in the same
commit.

Use the Keep a Changelog buckets and write from step 1's classification. If the
release's roadmap DOCS row names the user-facing summary, use it as a
checklist: every item it names must appear, and the commit range catches the
ones it forgot.

`weight` is a ladder with one slot per release, newest smallest, in steps of
10. The smallest slot is 10; `weight: 0` is unset to Hugo. If the next page
would land on 10, or the ladder already holds a duplicate, shift every existing
page up one step (`10` → `20`, …) in one descending `sed -si` pass. Check:

```bash
grep -H '^weight' docs/content/docs/changelog/v0.*.md \
  | sed 's/.*weight: //' | sort -n | uniq -d
```

It must print nothing. `scripts/docs-check` holds the index and the page
directory in bijection: an unlinked page and a link with no page both fail.

## 3. Update the README and docs

The install table uses a `<version>` placeholder, so it needs no version edit.
Update any count, name or implementation-phase checklist item the release
changed; grep rather than assuming.

The cost paragraph, the Trade-offs table and the chart are a published claim
stamped with a build:

```bash
./scripts/build
./scripts/measure-cost --check
./scripts/measure-cost --record
```

`--check` re-measures the five published rows from a release build and fails
past 10% on a row, past the run-to-run noise on the scrollback delta, or when
the Forward+/OpenGL3 ratio falls below the prose's claim. Update the table, every
figure the paragraph repeats, the "Nx lighter" ratio, and the stamp line's
version. `--record` appends or replaces the release in
`docs/data/cost-history.json` and redraws `docs/static/images/cost-history.svg`.
`--check` needs Linux with a GPU; `scripts/ci-check` runs `--stamp` (no GPU) and
fails when the crate version moves and the table still names the old build.

The site's home page carries exactly one image: the current release's
`vX.Y.Z_1.png`. Feature screenshots belong only in the blog entry.

Check the docs mirrors and links before committing:

```bash
python3 scripts/docs-check
./scripts/check-capabilities
python3 scripts/build-wiki --check
```

## 4. Close the roadmap

`ROADMAP.md` is the index; `docs/content/docs/roadmap/vX.Y.md` holds the chain.
A shipped row is closed when the work lands, with its evidence, tests and
measured numbers. Verify no `⬜` remains in the release's section. Anything
unshipped moves to the next chain's page in priority position, keeps its
wording, and is tagged `(Deferred from vX.Y.Z.)`. A chain stays `in progress`
until its last planned release ships.

The release's DOCS row (the changelog page) is release-time work and is checked
off after the page exists. A row whose work closes on its own tag (the asset-set
row) is closed in a post-release commit with the published list measured.

## 5. Bump the versions

`gpty version` reports `env!("CARGO_PKG_VERSION")`, so every workspace crate and
the GUI's project version must match the tag:

- Every crate under `crates/*` (`gpty-ai`, `gpty-cli`, `gpty-core`,
  `gpty-gdext`, `gpty-ipc`, `gpty-media`, `gpty-plugin`).
- `server.json`: both `version` and `packages[0].version` are the published
  crate version, not the tag. `scripts/mcp-registry check` fails on drift with
  `crates/gpty-cli`.
- `godot/project.godot`'s `config/version`. `ci-check`'s crate-versions step
  fails when it is stale.
- Both lockfiles: `Cargo.lock` and `fuzz/Cargo.lock`. The fuzz workspace is not
  a repository member, so `cargo check --workspace` does not touch it;
  `cargo metadata --format-version 1 --manifest-path fuzz/Cargo.toml` rewrites
  its version lines.

The bump is a per-file edit. `sed -i` with multiple files treats them as one
stream without GNU sed's `-s`; use `sed -si` or loop per file. Then:

```bash
cargo check --workspace
cargo build -p gpty-gdext
cargo package -p gpty-core
```

`cargo package` runs the packaged tarball's verify build, which is the only
local check that catches a crate embedding a file from outside its own
directory. The other crates cannot verify locally before their path dependency
is on the index; check their tarball file lists with
`cargo package -p <crate> --no-verify --list`.

## 6. Screenshots and blog entry

Capture the home screen:

```bash
scripts/screenshot-gpty docs/static/images/vX.Y.Z_1.png godot --path godot
```

The script creates a private user-data/runtime sandbox, waits for first frames,
captures and tears down. It needs XWayland for Godot's window; on a pure-Wayland
session it cannot find the window. Report that and ask the user for the image;
that is the fallback, not a routine gate.

Run a vision sanity pass on the capture: giant overlays, clipped controls,
overlapping sections. Fix anything real; note cosmetic issues for the user.

For feature screenshots, ask the user which features deserve one. Stage each
with `--state <name>` and re-capture with the same script, naming the file
`vX.Y.Z_<n>.png`. `scripts/ui-capture --list` prints the available states. Do
not stage through GUT: a non-headless GUT run captures the runner panel rather
than the app. Size the window to a physical screen; a multi-monitor desktop
size can produce a clipped off-screen window. Check every referenced image
exists under `docs/static/images/` before committing.

Create `docs/content/blog/vX.Y.Z/index.md` using the established front matter
and body shape (see an earlier `vX.Y.Z/index.md`), with the home screenshot
first and feature screenshots next to the features they show. A patch release
with no visual changes may reuse the previous home screenshot, but a fresh
capture is preferred.

## 7. Final review pause

All preparation ends here. Do **not** commit or tag yet. Present to the user:

- the changelog summary;
- the blog draft path and text;
- the captured screenshots;
- `/tmp/gpty-release-body.md`, the release PR body (one paragraph on the
  release's user-facing story plus the changelog link).

Wait for an explicit OK. The user may rewrite the blog, replace images, or ask
for more screenshots. Iterate, then proceed only on their go-ahead.

## 8. Commit, open the release PR, and tag

Run the full local gate once more:

```bash
./scripts/ci-check
git switch 0.8.x
git pull --ff-only
```

Stage the release commit and sign it:

```bash
git add CHANGELOG.md README.md ROADMAP.md server.json godot/project.godot \
  crates/*/Cargo.toml Cargo.lock fuzz/Cargo.lock \
  docs/content/docs/changelog/vX.Y.Z.md \
  docs/content/blog/vX.Y.Z \
  docs/static/images/vX.Y.Z_*.png
git commit -s -m "docs: finalize vX.Y.Z release"
```

Push the integration branch and open the release PR as `gpty-bot`:

```bash
./scripts/bot-push 0.8.x
./scripts/bot-pr --base main --title "vX.Y.Z" --body-file /tmp/gpty-release-body.md
```

Wait until all required checks on the release PR are green: the CI jobs
(including both Windows legs), `docs`, `commit-lint`, CodeQL and secret-scan.
Do not merge a partially green PR. Approve it as the maintainer, then merge with
a merge commit so the integration branch remains ancestral to `main`:

```bash
gh pr review --approve <number>
gh pr merge --merge <number>
git switch main
git pull --ff-only
```

Tag from `main` and verify the signature before pushing:

```bash
git tag -s vX.Y.Z -m "vX.Y.Z"
git tag -v vX.Y.Z
git push origin vX.Y.Z
```

The tag push runs the `pre-push` hook's full `ci-check`, so it can take a couple
of minutes. Confirm the tag reached the remote with
`git ls-remote --tags origin vX.Y.Z` rather than assuming. Tags are immutable:
do not force-move one to include a late fix.

After the merge, bring the integration branch to the release commit:

```bash
git switch 0.8.x
git merge --ff-only main
git push origin 0.8.x
```

## 9. Understand the release workflow

The tag starts `.github/workflows/release.yml`, split so no write or OIDC
privilege is present while project code runs:

- **`release-gate`** is read-only. It validates the tag format (`vX.Y.Z`, no
  pre-release suffix), verifies the tag is a signed annotated tag through the
  GitHub API, checks it is an ancestor of `main`, compares the crate and
  `server.json` versions with the tag, runs `mcp-registry check`, checks both
  lockfiles with `cargo metadata --locked`, checks the defect-class trailers,
  and runs the docs, capability and knowledge-bundle gates.
- **`export`** is read-only. It stamps `godot/project.godot`, installs Godot and
  the export templates, asserts the four GDExtension files exist, exports
  Linux, Windows and macOS, writes `SHA256SUMS`, and uploads the three archives
  plus the sums as `gpty-release-dist`.
- **`publish`** is the only write/OIDC job. It downloads the staged artifact,
  attests the four assets, and creates the GitHub release. It does not check
  out the repository and runs no project code. It waits on the `release`
  environment's required reviewer.

Review the `gpty-release-dist` artifact (three archives plus `SHA256SUMS`)
before approving the environment. The same environment protects the
`mcp-registry` publish job.

## 10. Verify the published release

A tag is not a finished release. Download and verify the assets:

```bash
mkdir -p /tmp/gpty-release
gh release download vX.Y.Z --pattern 'SHA256SUMS' --dir /tmp/gpty-release
gh release download vX.Y.Z --pattern 'gpty-vX.Y.Z-*' --dir /tmp/gpty-release
cd /tmp/gpty-release
sha256sum -c --ignore-missing SHA256SUMS
```

Each archive must carry `LICENSE` and `LICENSE-EXCEPTIONS.md` next to the
binaries (GPLv3 §4/§6). Check with `tar -tzf` for the tarball and `unzip -l`
for the zips. Verify the build-provenance attestation by its **subject digest**,
not by the exit code: `gh attestation verify <asset> --repo godot-pty/gpty
--format json` can print nothing and exit 0 for a file with no matching
attestation; confirm the statement's subject digest equals the downloaded
file's SHA-256.

For the macOS archive, verify the new deployment floor and the dylib layout:

```bash
scripts/check-macos-minos --x86_64 10.13 --arm64 11.0 \
  <unpacked>/gPTY.app/Contents/Frameworks/*.dylib
```

Every FFmpeg dylib and GDExtension slice must report at most macOS 10.13 on
x86_64 and 11.0 on arm64. `zipinfo -l` must show one real
`libavcodec.63.1.102.dylib` (and its siblings) with the `.63` and unversioned
aliases as symlinks, not three real copies per library. The v0.8.3 asset did
not meet this floor; the first release after the fix is the proof.

## 11. Release tail

- **AUR.** Update `dist/aur/PKGBUILD` (`pkgver`/`pkgrel`, the tarball's
  `sha256sums`, and the bundle layout: the CLI as `gpty`, the GUI as `gpty-gui`
  with `gpty-gui.pck` and `libgpty_gdext.linux.x86_64.so`, both on `PATH`).
  Validate in a temp directory with `makepkg --noconfirm` (building in the tree
  leaves untracked `src/`, `pkg/` and package files), then publish to the AUR
  when the account can.
- **crates.io.** From the release commit with a clean tree, publish in
  dependency order: `gpty-core`, wait for the index, then `gpty-ipc`,
  `gpty-plugin`, `gpty`. `cargo publish` runs the packaged verify build; the
  later crates cannot verify locally because their path dependency is not on
  the index until the earlier one publishes.
- **MCP registry.** After the four crates are live, dispatch
  `gh workflow run mcp-registry.yml` on `main`. It validates `server.json`
  against the CLI crate, refuses a version crates.io does not have, verifies
  the publisher tarball, and publishes over OIDC. It uses the same `release`
  environment.
- **Record.** Close the release's asset-set roadmap row in a post-release
  commit with the published list measured. The changelog page and the release
  assets are the release record; do not rewrite a released page.

## Failure handling

- A red required check blocks the release. Fix the source or the release prep
  and push again; do not merge around it.
- A transient failure in the release workflow may be re-run. A workflow bug in
  the tagged tree cannot be fixed by changing `main`; cut the next patch so the
  fixed workflow is in the tagged tree.
- A bad tag is permanent. The tag ruleset blocks moving and deleting tags, and
  there is no bypass. Do not disable the ruleset to rescue a release; cut the
  next patch version and say what happened in its notes.
- If `publish` creates a partial or incorrect release, correct the assets or
  notes if GitHub allows it, but do not move the tag. Fix forward with a patch.

## Gotchas

- **`cargo package --no-verify` hides the packaging bug that matters.** The
  verify step compiles the tarball cargo would upload. Anything `include_str!`d
  into a published crate must live inside that crate's directory; a path
  reaching above it compiles in the workspace and fails at publish. This is why
  the agent skill lives at `crates/gpty-cli/skills/gpty/SKILL.md`.
- **Windows behavior is only proven in CI.** `ci-check`'s Windows step is a
  cross-compile; `windows-smoke` and the Windows GUT run are the runtime proof.
- **Screenshots need XWayland.** `scripts/screenshot-gpty` finds Godot's window
  through the X tree; on pure Wayland, report the failure and ask for the
  image. Its capture backend falls back from ffmpeg to ImageMagick;
  `SCREENSHOT_CAPTURE=import` skips a known-bad ffmpeg stall.
- **Docs mirrors are generated.** `docs/assets/repo/`, `docs/data/` and
  `docs/.cache/` are gitignored. `docs/setup.sh` copies the root docs into the
  site; a new root document needs its copy line and a `RELEASING.md`-style
  `readfile` page. Never commit the generated copies.
- **Hugo tarballs clobber the repo.** The Hugo release tarball contains
  `README.md` and `LICENSE`; extract only the `hugo` member or into a temp
  directory.
- **The docs versions dropdown is cached.** `docs/setup.sh` fetches release
  tags from the GitHub API with a one-hour cache; new releases appear after it
  expires, with no manual edit.
- **`gh run watch` can fail on a transient API error** while the run is still
  going. Confirm with `gh run view <id> --json status,conclusion` before
  calling a run failed.
- **No `dev/v*` branches.** The integration branch is long-lived; feature
  branches are short-lived and PR back to it, not to `main`.
