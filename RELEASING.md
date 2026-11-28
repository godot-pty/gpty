# Releasing gPTY

This is the canonical release process. It is written for the maintainer and for
anyone preparing a release under their direction. The agent execution checklist
is `.omp/skills/release/SKILL.md`; it follows this page and records only the
agent-specific checkpoints, not a second runbook. Release authority is in
[MAINTAINERS.md](https://github.com/godot-pty/gpty/blob/main/MAINTAINERS.md).

A release is a short-lived release-prep pull request against `main` for the
active line, or against `release/vX.Y` for a line in maintenance, the
maintainer's approval, a merge commit, and a signed annotated `vX.Y.Z` tag on
the merge result. `main` is the trunk: feature pull requests land there.

## Branches

`main` is the trunk. Every change lands through a pull request against it;
feature branches are short-lived.

A line that has stopped receiving features has a long-lived maintenance branch
`release/vX.Y`, created from `main` at the line's last release commit (the
`vX.Y.Z` tag) when development moves to the next minor. It receives only
cherry-picked fixes. It is never a development branch, and the active line's
tags come from `main`.

The remote is the inventory; nothing needs to list the branches by hand:

```bash
git branch -r --list 'origin/release/v*'
git describe --tags --abbrev=0 origin/release/v0.7   # the line's last release
```

A line that closed before its branch existed is created at that line's last
release tag, so it contains the release's changelog page, version bump and blog
entry - not the commit before them:

```bash
git switch -c release/v0.7 v0.7.2
git push origin release/v0.7
```

An archived branch may carry one later policy-only commit
(`chore(ci): trigger on release branches`, which makes a backport PR run the CI
that shipped with that tree). The tag, not the branch tip, is the shipped tree.

Do not type the branch into a command; derive it from the tag being cut. The
rest of this page uses `$BRANCH`:

```bash
RELEASE=vX.Y.Z
BRANCH="release/${RELEASE%.*}"   # v0.8.6 -> release/v0.8
```

Tags:

- The active line: tag `main` after the release PR merges.
- A line in maintenance: tag `release/vX.Y` after the backport PR merges.
- Never tag a release-prep or feature branch.

The tag gate accepts a tag reachable from `main` or from the `release/vX.Y`
derived from the tag. `release/v0.1` through `release/v0.7` are the closed
lines. `release/v0.8` does not exist yet: the 0.8 line is still active through
0.8.7, and the branch is cut from the last 0.8 tag when 0.9 development starts.
Creating it now would freeze it behind 0.8.6/0.8.7 and force a branch-sync PR
per release.

## Preconditions

- A configured signing key (`git tag -v` must work) and the public key on
  GitHub. The tag ruleset has no bypass: every tag must be a signed annotated
  tag, and a bad tag cannot be moved or deleted. Cut the next patch instead.
- The `gpty-bot` app installed on `godot-pty/gpty` and its key at the
  conventional `~/.config/gpty/gpty-bot.pem` (or `GPTY_BOT_PRIVATE_KEY`);
  `./scripts/bot-token --check` passes. `scripts/pr push`/`open` push the
  release-prep branch and open the release PR; the app never approves or
  merges.
- A crates.io Trusted Publisher config for each of `gpty-core`, `gpty-ipc`,
  `gpty-plugin` and `gpty` when the tagged workflow runs `publish-crates`:
  repository owner `godot-pty`, repository `gpty`, workflow filename
  `release.yml`, environment `release`. The crates must already exist, and the
  account adding the config must be an owner. Without them the OIDC exchange
  fails before any crate is published.
- A clean tree, `main` for the active line (the maintenance branch for a
  maintenance release), and the release's roadmap rows closed. Anything
  unshipped moves to the next chain in priority position with
  `(Deferred from vX.Y.Z.)`.
- `./scripts/check-github-settings` passes. It is read-only and needs a
  maintainer-authenticated `gh`: it reads back the rulesets, classic protection,
  the merge-queue parameters, auto-merge/head-branch deletion, the `release`
  environment, SHA-pinning and sign-off flags instead of trusting the settings
  to stay put.
- `./scripts/ci-check` passes. Its Windows step cross-compiles only; the
  runtime legs (`windows`, GUT on Windows) exist only in CI and must be green
  on the release PR's head. Also run the
  [manual pre-release checklist](docs/content/docs/overview/testing.md#manual-pre-release-checklist)
  against a real GUI; it covers the renderer, input and live-session paths that
  headless tests cannot.
- A graphical session for the release screenshot and, on Linux with a GPU, the
  cost-table measurement. Both have documented fallbacks.

## 1. Analyze the commit range

Release notes come from the commit history, never from memory. Set the tag and
derive its branch; start on `main` for the active line or on the derived
`$BRANCH` for a maintenance release, then inspect the range:

```bash
RELEASE=vX.Y.Z
BRANCH="release/${RELEASE%.*}"   # vX.Y.Z -> release/vX.Y
git switch main                  # or: git switch "$BRANCH"
git pull --ff-only
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
with front matter (`title: "vX.Y.Z - YYYY-MM-DD"`, `date: YYYY-MM-DD`) and the
compare link `[Release on GitHub](https://github.com/godot-pty/gpty/compare/vPREV...vX.Y.Z)`.
`CHANGELOG.md` is an index only; prepend the link
`- [X.Y.Z - YYYY-MM-DD](docs/content/docs/changelog/vX.Y.Z.md)` in the same
commit.

Use the Keep a Changelog buckets and write from step 1's classification. If the
release's roadmap DOCS row names the user-facing summary, use it as a
checklist: every item it names must appear, and the commit range catches the
ones it forgot.

The page carries `date: YYYY-MM-DD` matching the title; do **not** add a
`weight`. Hextra's sidebar sorts the section by date, newest first, so a
maintenance release authored later appears above the newer minor - which is
correct. `scripts/docs-check` requires the date on every changelog page and
holds the index and the page directory in bijection: an unlinked page and a
link with no page both fail.

On a maintenance release, author this page on `release/vX.Y`; after the tag,
port the page, its `CHANGELOG.md` link, the blog entry and its images to `main`
(step 8) so the site publishes them.

## 3. Update the README and docs

The install table uses a `<version>` placeholder, so it needs no version edit.
Update any count, name or implementation-phase checklist item the release
changed; grep rather than assuming.

The cost paragraph, the Trade-offs table and the chart are a published claim
stamped with a build. When a Linux GPU session is available:

```bash
./scripts/build
./scripts/measure-cost --check
./scripts/measure-cost --record
```

`--check` re-measures the published rows from a release build and fails past 10%
on a row, past the run-to-run noise on the scrollback delta, or when the
Forward+/OpenGL3 ratio falls below the prose's claim. `--record` appends or
replaces the release in `docs/data/cost-history.json` and redraws
`docs/static/images/cost-history.svg`; then update the table, every figure the
paragraph repeats, the "Nx lighter" ratio, and the stamp line's version.

Hardware is no longer a release gate. `scripts/measure-cost --stamp` is the
GPU-free check: it requires the README stamp to name the newest release in
`docs/data/cost-history.json`, not the current crate version. So a release
without a GPU session reuses the last measured build and leaves the ledger and
SVG untouched. The weekly `Bench` workflow reports the llvmpipe trend as
telemetry; it never blocks a release.

The home page carries the demo clips, not a release screenshot. The release's
`vX.Y.Z_1.png` belongs to its blog entry (`docs/content/blog/vX.Y.Z/index.md`);
feature screenshots sit beside their features there. Do not add a release
screenshot to `docs/content/_index.md`.

Check the docs mirrors and links before committing:

```bash
python3 scripts/docs-check
./scripts/check-capabilities
python3 scripts/build-wiki --check
```

These three are the active line's list. On a maintenance branch run the subset
that tree carries (v0.7.2 has `docs-check` and `build-wiki --check` but no
`check-capabilities`) and say which gates were unavailable rather than skipping
them silently.

## 4. Close the roadmap

`ROADMAP.md` is the index; `docs/content/docs/roadmap/vX.Y.md` holds the queue,
and each row's record is its `## <ID>` section on `details/<area>.md`. A shipped
row is closed when the work lands, with its evidence, tests and measured
numbers in that section; `./scripts/roadmap close <ID>` writes the status and
the `Commits:` line from the `Roadmap: <ID>` trailers. Verify the release's
section with `./scripts/roadmap release-check vX.Y.Z` - no `⬜` remains and every
`✅` has a `Commits:` line; `--strict` also rejects `unrecorded`. Anything
unshipped moves to the next chain's page in priority position, keeps its ID,
and is tagged `(Deferred from vX.Y.Z.)`. A dropped row is `🚫` and a won't-fix row is `❌`, each with the reason
in its detail. A chain stays `in progress` until its last planned release ships.

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

The bump is one command:

```bash
./scripts/release-prepare X.Y.Z
```

It edits every `crates/*/Cargo.toml` (package version and internal pins), both
lockfiles, `server.json` and `godot/project.godot`, then refuses a lockfile diff
wider than the workspace-crate version lines. `--check` is the CI gate that
validates the same files, and `--print-version` prints the uniform version.
Pending docs/blog work does not block the bump, but the bump targets themselves
must be clean, and the branch must be `main`, `release/vX.Y` or
`release-prep/*`. Then:

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

The bump is on the branch being released: `main` for the active line,
`release/vX.Y` for a maintenance release. `main` keeps the active line's
version; do not port a maintenance bump to it.

## 6. Screenshots and blog entry

Capture the app's main screen:

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
and body shape (see an earlier `vX.Y.Z/index.md`), with the release screenshot
first and feature screenshots next to the features they show. A patch release
with no visual changes may reuse the previous release screenshot, but a fresh
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
```

A release-prep branch never edits `.github/workflows/**`: the `gpty-bot` app
cannot create or update a workflow file. Land a workflow change in its own PR
before the release.

For the active line, create the prep branch from `main`, push it through the
bot, and open the PR against `main`:

```bash
git switch main
git pull --ff-only
git switch -c "release-prep/$RELEASE"
```

For a maintenance line, start from the line's branch and target it instead:

```bash
git switch "$BRANCH"
git pull --ff-only
git switch -c "release-prep/$RELEASE"
```

Stage the release commit and sign it. When a GPU session was available, the list
includes the cost ledger and chart that `measure-cost --record` wrote; without
them the README names the new build while the published chart stops at the
previous release. If no GPU session was available, leave the ledger, chart and
README cost figures at the last measured build and omit those paths - the
`--stamp` check accepts the newest recorded build.

```bash
git add CHANGELOG.md README.md ROADMAP.md server.json godot/project.godot \
  crates/*/Cargo.toml Cargo.lock fuzz/Cargo.lock \
  docs/content/docs/changelog/vX.Y.Z.md \
  docs/content/blog/vX.Y.Z \
  docs/static/images/vX.Y.Z_*.png \
  docs/data/cost-history.json docs/static/images/cost-history.svg
git commit -s -m "docs: finalize $RELEASE release"
```

Push it and open the release PR as `gpty-bot`. The base is `main` for the
active line and `$BRANCH` for a maintenance release:

```bash
./scripts/pr push "release-prep/$RELEASE"
./scripts/pr open --base main --title "$RELEASE" --body-file /tmp/gpty-release-body.md
# maintenance: --base "$BRANCH" on both commands
```

Wait until the PR's checks are green: on the active line the required checks are
`ci-gate`, secret-scan and the four CodeQL analysis jobs (`Analyze (actions)`,
`Analyze (javascript-typescript)`, `Analyze (python)`, `Analyze (rust)`); on a
maintenance branch its CI, CodeQL and secret-scan runs. The branch's suite is the suite that shipped with it; if a
pinned action or runner has retired so the suite cannot start, record the
failing job and the equivalent local gate in the PR, and do not merge a real
failure. Do not merge a partially green PR. Approve it as the maintainer, then
enqueue it; the merge queue tests the group on the latest `main` and merges it
without an **Update branch** click:

```bash
gh pr review --approve <number>
gh pr merge --auto --merge <number>
# before the merge queue exists: gh pr merge --merge <number>
```

Tag the result and verify the signature before pushing. The active line tags
`main`; a maintenance release tags `$BRANCH`:

```bash
git switch main                  # or: git switch "$BRANCH"
git pull --ff-only
git tag -s "$RELEASE" -m "$RELEASE"
git tag -v "$RELEASE"
# Push over HTTPS with the bot token, not the SSH origin (see below).
tmp=$(mktemp); chmod 600 "$tmp"
./scripts/bot-token > "$tmp"
GPTY_BOT_TOKEN_FILE="$tmp" GIT_ASKPASS="$PWD/scripts/git-askpass-token" \
  GIT_TERMINAL_PROMPT=0 git push \
  https://x-access-token@github.com/godot-pty/gpty.git \
  "refs/tags/$RELEASE:refs/tags/$RELEASE"
rm -f "$tmp"
```

The tag push runs the `pre-push` hook's full `ci-check` (about six minutes;
measured 2026-11-23). Push it over HTTPS as above: git opens the remote
connection before the hook, and the SSH origin's connection does not survive
the gate - the push dies with SIGPIPE (exit 141) after the hook has passed.
Confirm the tag reached the remote with
`git ls-remote --tags origin "$RELEASE"` rather than assuming. Tags are
immutable: do not force-move one to include a late fix.

After a maintenance tag, port only the user-facing docs to `main` so the site
(which deploys from `main`) publishes them:

```bash
git switch main
git pull --ff-only
git switch -c "docs/$RELEASE"
git checkout "$RELEASE" -- docs/content/docs/changelog/vX.Y.Z.md \
  docs/content/blog/vX.Y.Z 'docs/static/images/vX.Y.Z_*.png'
# add the CHANGELOG.md link by hand
git commit -s -m "docs: publish the $RELEASE notes"
./scripts/pr push "docs/$RELEASE"
./scripts/pr open --base main --title "docs: publish $RELEASE" --body-file /tmp/gpty-release-docs-body.md
```

Do not port the version bump, `Cargo.lock`, `server.json`,
`godot/project.godot`, or the old line's roadmap edits to `main`.

## 9. Understand the release workflow

The tag starts `.github/workflows/release.yml`, split so no write or OIDC
privilege is present while project code runs:

- **`release-gate`** is read-only. It validates the tag format (`vX.Y.Z`, no
  pre-release suffix), verifies the tag is a signed annotated tag through the
  GitHub API, checks it is reachable from `main` or from the `release/vX.Y`
  derived from the tag, checks the tag equals
  `./scripts/release-prepare --print-version` and runs
  `./scripts/release-prepare --check` (manifests, both lockfiles, `server.json`,
  `godot/project.godot`), runs `mcp-registry check`, checks both lockfiles with
  `cargo metadata --locked`, checks the defect-class trailers, and runs the
  docs, capability, knowledge-bundle and docs-bundle gates.
- **`build`** calls `.github/workflows/release-build.yml`, the same definition a
  `workflow_dispatch` on `main` runs. It carries the platform jobs
  (`build-linux`, both `build-macos` arches, `build-windows`, `bundle-macos`,
  `export`) and restores the caches a run on `main` wrote: the FFmpeg prefix
  (Windows under `ci.yml`'s key; Linux under an image-scoped
  `Linux-ubuntu22-ffmpeg-*` key, because the release builds on 22.04 for the
  bundle's glibc floor while `ci.yml` builds on 24.04 and a 24.04-built
  `libav*.so` needs GLIBC_2.38), the Windows vcpkg tree on every build (the
  compile needs its headers and import libraries even when the prefix supplies
  the DLLs), and the release-profile `target` under a
  `cargo-release-<os>-<arch>-<lock>` key kept apart from the debug caches. A
  tag run only restores: an entry it saves is tag-scoped, unreadable by the
  next tag, and would evict CI's caches from the 10 GB budget. `export` stamps
  `godot/project.godot` with the version input, installs Godot and the export
  templates through `scripts/install-godot` from `scripts/godot-version.json`,
  asserts the four GDExtension files exist, exports Linux, Windows
  and macOS, writes `SHA256SUMS`, and uploads the three archives, the SBOM and
  the sums as `gpty-release-dist`. It also extracts the three archives and stages the
  fonts and colour schemes the export compiles into `gpty-gui.pck`, then runs
  `scripts/bundle-sbom` over that tree: `gpty-<version>.spdx.json` names the
  bundle's components (gPTY, Godot, FFmpeg, DejaVu Sans Mono, Phosphor Icons,
  the colour schemes) and digests every shipped file. The SBOM is a line in
  `SHA256SUMS` and ships in the same artifact.

  `workflow_dispatch` on that file is how the caches are filled and how the
  build definition is proved before it is used by a tag:

  ```bash
  gh workflow run release-build.yml --ref main -f version=vX.Y.Z
  ```

  Run it once on the release commit; it publishes nothing and writes
  `gpty-release-dist` as a run artifact. On `main` it also saves the FFmpeg
  prefix, the Windows vcpkg tree and the release-profile cargo cache, so the
  next pull request and tag restore them. A dispatch on a cold key is the cold
  measurement; the next one (or the tag run after it) is the warm one. Read the
  step timings with `gh run view <id> --json jobs`.
- **`publish`** writes the GitHub release. It downloads the staged artifact,
  attests the archives, the SBOM and `SHA256SUMS`, stages the provenance bundle
  as `gpty-<tag>.intoto.jsonl`, signs an SBOM attestation and creates the
  release. It does not check out the repository and runs no project code. It
  waits on the `release` environment's required reviewer.
- **`publish-crates`** checks out the signed tag and publishes `gpty-core`,
  `gpty-ipc`, `gpty-plugin` then `gpty` with crates.io trusted publishing:
  OIDC only, no stored token. It runs `cargo publish`'s packaged verify build,
  so it does run project code, but holds only `contents: read` plus
  `id-token: write`. A version already on crates.io is skipped, so a partial
  failure is rerunnable. Trusted publishing needs a per-crate config on
  crates.io (repository owner `godot-pty`, repository `gpty`, workflow filename
  `release.yml`, environment `release`). Without one the OIDC exchange fails
  with `400 ... No Trusted Publishing config found for repository
  'godot-pty/gpty'` before any crate is published; add the four configs, then
  re-run the failed job.
- **`mcp-registry`** is called after both `publish` and `publish-crates`. It
  validates the descriptor at the tag against `main`'s validator and publishes
  over OIDC. It also uses the `release` environment.

Review the `gpty-release-dist` artifact (three archives, the SBOM and
`SHA256SUMS`) before approving the first environment; the same environment
protects `publish-crates` and the chained `mcp-registry`, so expect three
approvals.

### Nightly builds

`.github/workflows/nightly.yml` runs at `17 5 * * *` and on demand, and is the
same build call with three differences: `build_version` carries
`<crate>-nightly.<YYYYMMDD>+g<sha>` into `gpty-core`'s build script (so
`gpty version`, the About tab and the IPC `version` reply all name the build),
`artifact_retention_days: 1` keeps the between-job artifacts overnight rather
than three days, and its publish job renames the three archives to
`gpty-<platform>` before uploading. It is the only writer of the release caches:
`release-build.yml` saves on `refs/heads/main`, and a tag run restores.

The release is created once and never deleted - assets are replaced with
`gh release upload --clobber`, then the tag ref is force-moved and the notes
rewritten with the commit and build date. A day whose head equals the release's
current target skips after one job; a failed platform build leaves the previous
nightly downloadable because `publish` needs `build`. The nightly publishes its
own `.intoto.jsonl` bundle because Scorecard counts a prerelease among the five
most recent releases.

The names are permanent, so `--clobber` is the wrong tool for a rename: it
replaces files in place and never deletes, and a dropped asset would keep
answering on the permanent URL. Remove one with
`gh release delete-asset nightly <name>` in the same change that renames it.

```bash
gh workflow run nightly.yml --ref main
gh release view nightly --json isPrerelease,targetCommitish,assets
curl -fL -o /tmp/n.json https://api.github.com/repos/godot-pty/gpty/releases/latest
jq -r .tag_name /tmp/n.json   # still the last stable tag
```

## 10. Verify the published release

A tag is not a finished release. The tag's `publish-crates` job publishes the
four crates and the chained `mcp-registry` job publishes the descriptor; check
that they did, rather than publishing by hand:

```bash
for crate in gpty-core gpty-ipc gpty-plugin gpty; do
  curl -fsS -o /dev/null "https://crates.io/api/v1/crates/${crate}/${RELEASE#v}" \
    && echo "${crate}: ${RELEASE#v} live" \
    || echo "${crate}: MISSING"
done
```

A missing version means the job failed: re-run the failed job, not `cargo
publish`; the pre-check skips crates already on the index. Then download and
verify the assets:

```bash
mkdir -p /tmp/gpty-release
gh release download vX.Y.Z --pattern 'SHA256SUMS' --dir /tmp/gpty-release
gh release download vX.Y.Z --pattern 'gpty-vX.Y.Z-*' --dir /tmp/gpty-release
gh release download vX.Y.Z --pattern 'gpty-vX.Y.Z.spdx.json' --dir /tmp/gpty-release
cd /tmp/gpty-release
sha256sum -c --ignore-missing SHA256SUMS
```

The release page lists exactly six assets: the three archives, `SHA256SUMS`, the
SBOM (`gpty-vX.Y.Z.spdx.json`) and the provenance bundle
(`gpty-vX.Y.Z.intoto.jsonl`). The bundle is deliberately absent from
`SHA256SUMS`, because it attests that file. Verify the SBOM attestation on any
archive:

```bash
gh attestation verify gpty-vX.Y.Z-linux-x86_64.tar.gz --repo godot-pty/gpty \
  --predicate-type https://spdx.dev/Document
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

### Backfilling a release's attestation bundle

Releases published before the bundle asset existed carry attestations only in
the API, so Scorecard's provenance probe sees nothing for them (it scores the
five most recent releases, and only assets count). The bundles are still
retrievable; one operator run over the last four stable tags lifts the score
from 2 (one release with a bundle) to 10:

```bash
for tag in v0.8.5 v0.8.4 v0.8.3 v0.8.2; do
  w="$(mktemp -d)"
  gh release download "$tag" -R godot-pty/gpty -D "$w"
  ( cd "$w" && for asset in *; do
      [ "$asset" = SHA256SUMS ] && continue
      gh attestation download "$asset" -R godot-pty/gpty --limit 1 \
        || echo "no attestation for $asset (skipped)"
    done )
  if compgen -G "$w/sha256-*.jsonl" >/dev/null; then
    cat "$w"/sha256-*.jsonl > "gpty-$tag.intoto.jsonl"
    gh release upload "$tag" "gpty-$tag.intoto.jsonl" -R godot-pty/gpty
    rm -f "gpty-$tag.intoto.jsonl"
  else
    echo "no attestations on $tag; nothing to backfill"
  fi
  rm -rf "$w"
done
```

`gh attestation download` writes `sha256-<digest>.jsonl` into the working
directory; concatenating them is what the action's own `bundle-path` contains
when several subjects are attested at once. Confirm each upload with
`gh release view "$tag" --json assets`.

## 11. Release tail

- **AUR.** Update `dist/aur/PKGBUILD` (`pkgver`/`pkgrel`, the tarball's
  `sha256sums`, and the bundle layout: the CLI as `gpty`, the GUI as `gpty-gui`
  with `gpty-gui.pck` and `libgpty_gdext.linux.x86_64.so`, both on `PATH`).
  Validate in a temp directory with `makepkg --noconfirm` (building in the tree
  leaves untracked `src/`, `pkg/` and package files), then publish to the AUR
  when the account can.
- **Crates and registry.** The tag's `publish-crates` and chained
  `mcp-registry` jobs publish them; verify the four crate versions and the
  registry entry in §10. If a job failed, re-run it: the publish pre-check
  skips versions already on crates.io.
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
  cross-compile; the `windows` job and the Windows GUT run are the runtime proof.
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
- **No long-lived development branches.** `main` is the trunk; feature branches
  are short-lived and PR to `main`. `release/vX.Y` is maintenance-only, created
  at stabilization; it receives cherry-picked fixes, never feature work. An
  archived line's tag is the shipped tree; its branch may carry a later
  CI-trigger commit.
- **A release-prep branch never edits a workflow.** `scripts/pr push` hands the
  workflow commit to the maintainer and the final commit to the app, which
  cannot create or update `.github/workflows/**`; land a workflow change in its
  own PR first.
- **An archived line runs the workflow that shipped with it.** A maintenance
  tag's tree starts the release workflow in that tree, not the current one;
  review it before the tag. The tag ruleset still requires a signed annotated
  tag and has no bypass.
