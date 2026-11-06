---
name: release
description: "Release workflow for gpty: commit-range analysis, CHANGELOG, README, ROADMAP, crate versions, automated screenshots, blog entry, user approval gate, tagging, CI verification, post-release assets and AUR recipe."
---

# gpty Release Process

Trunk-based releases on `main`. Releases are triggered by pushing a `v*` tag.

## Pre-release Checklist

- [ ] `./scripts/ci-check` passes (fmt, lint, clippy, tests, GUT, audit, crate versions, Windows cross-check)
- [ ] CI is green on the pushed `main` for the commit that will be tagged — the `ci.yml` run, **including the Windows legs** (`windows-smoke`, the GUT suite on Windows). Those exist only in CI: `ci-check`'s xwin step compiles the Windows arms without running a Windows pane, and the tag fires `release.yml` off this commit
- [ ] All planned ROADMAP items for the version are `[x]` done
- [ ] Doc consistency — grep AGENTS.md/README for names and strings changed this version (e.g. "OMP Workspace", the MCP tool count); stale references are updated in the same release commit
- [ ] No uncommitted changes: `git status --short`

## Release Steps

### 1. Commit Analysis

Release notes are derived from the actual commit history — never from memory:

```bash
git log v<PREVIOUS_TAG>..HEAD --oneline
```

- Classify every commit ONCE into a single table: CHANGELOG bucket (`Added` / `Changed` / `Fixed`), ROADMAP feature bullet (blank for non-features), and skip marks. This one pass feeds both step 2 and step 4 — never run two separate analyses, they drift.
- Skip noise: debug-logging churn, revert commits, lockfile/gitignore chores, agent-facing AGENTS.md edits.
- Fix sagas (multiple commits converging on one bug): write one bullet describing the net user-visible result.
- Note which commits produced user-visible UI changes — this list feeds the feature-screenshot question in step 6.

### 2. CHANGELOG

Files: `CHANGELOG.md` (an index) and one page per release under `docs/content/docs/changelog/`.

- There is no `## [X.Y.Z] — Unreleased` section to reconcile: `CHANGELOG.md` holds the opening text and a newest-first link list, and each release's notes live in `docs/content/docs/changelog/vX.Y.Z.md` with front matter (`title: "vX.Y.Z - YYYY-MM-DD"`, `weight`). Write the page from step 1's classification under `## Added` / `### Changed` / `### Fixed` (Keep a Changelog buckets) and open it with the compare link `[Release on GitHub](https://github.com/godot-pty/gpty/compare/vPREVIOUS...vX.Y.Z)`.
- `weight` is a ladder with one slot per release and the newest smallest, in steps of 10: today 180 (`v0.1.0`) down to 10 (`v0.8.0`), so the next release takes the next lower slot (0 after 10) - **except that 0 is not a slot**: Hugo reads `weight: 0` as *unset*, so a page there still renders (the section body is `CHANGELOG.md`) but drops out of the changelog section's own navigation, sorted after every weighted page. The smallest slot is 10. When the next page would land on 0, shift every existing page up one step first (`10` → `20`, …, `170` → `180`) in one `sed -si` pass, descending order in a single `-e` chain so a shift cannot be applied twice, then write the new page at 10. v0.8.0 is the first release to need the shift, and it took two: the first wrote the page at 0 and shipped without the sidebar entry until a docs build caught it - so verify the built site lists the new page first in the section nav, not only in the body.
- Prepend the link to `CHANGELOG.md`'s list in the same commit: `- [X.Y.Z - YYYY-MM-DD](docs/content/docs/changelog/vX.Y.Z.md)`. `scripts/docs-check` holds the index and the page directory in bijection - a page nobody links, and a link with no page, both fail the gate.
- If a roadmap row kept the user-facing summary (the release's DOCS row does), it is the checklist for that page: every item it names must appear, and the commit range is what catches the ones it forgot. Never reconstruct from memory.

### 3. README

File: `README.md`

- The install table uses a `<version>` placeholder (`gpty-v<version>-linux-x86_64.tar.gz`, …), so a release edits **nothing** there. Check it still matches the current bundle layout (the CLI as `gpty`, the GUI as `gpty-gui` and its pack) rather than editing a version into it.
- What a release does touch in the README is the implementation-phase checklist when the release completes a phase, and any count or name the release changed. Grep for both instead of assuming.
- `docs/content/_index.md` currently embeds no image, so there is no landing screenshot to repoint. If one is added, it shows the current release's `vX.Y.Z_1.png` and nothing else.

**Home page image rule (inviolable):** the website home page has exactly ONE image — the home-screen screenshot of the most recent release (`vX.Y.Z_1.png`). Feature screenshots (`vX.Y.Z_2.png`, …) appear ONLY inside the blog entry, never on the home page.

### 4. ROADMAP

Files: `ROADMAP.md` (an index over the chains) and `docs/content/docs/roadmap/vX.Y.md` (the release chain pages).

- Nothing is filled in at release time: a shipped row is closed when the work lands, with its evidence, tests and measured numbers, and that text is the release record. `ROADMAP.md` only carries the per-chain status (`released` / `in progress` / `planned` / `unscheduled`) — update that word for the release's chain.
- Verify no `⬜` is left in the release's section, then mark the chain released. Anything unshipped moves to the next chain's page in priority position, keeping its wording and tagged `(Deferred from vX.Y.Z.)`; a released section never keeps an open row and nothing is dropped silently.
- A release whose last row closes on its own tag (the asset-set row) carries that closer in a post-release commit and says in the row what the published list measured.

### 5. Crate Versions

`gpty version` reports `env!("CARGO_PKG_VERSION")` — the released binary must match the tag.

- Bump **every workspace crate** (`crates/*`) to X.Y.Z — currently `gpty-ai`, `gpty-cli`, `gpty-core`, `gpty-gdext`, `gpty-ipc`, `gpty-media`. They are internal, path-referenced crates with no external semver consumers — uniform release-versioning avoids drift (gpty-core/gpty-gdext once froze at 0.1.0 for three releases while the app shipped 0.2.0/0.3.0).
- Bump `server.json` (the MCP registry descriptor) in the same pass: its `version` and `packages[0].version` are the *published crate* version, not the tag. `scripts/mcp-registry check` runs in `ci-check` and fails on any drift with `crates/gpty-cli`.
- New workspace crates join the uniform bump automatically; `./scripts/ci-check` (step "crate versions") fails on any drift. Don't trust `grep '^version' crates/*/Cargo.toml` alone — dependency tables also match.
- The bump is a **per-file** edit: `sed -i '0,/^version = "…"$/s//…/' crates/*/Cargo.toml` treats all files as ONE stream without GNU sed's `-s`, so only the first file's first match is replaced. Use `sed -si` (or loop per file), then re-check every crate.
- Refresh the lockfile: `cargo check --workspace` (updates `Cargo.lock` entries for the path deps).
- Rebuild the gdext lib: `cargo build -p gpty-gdext` (keeps the local dev binary current).

### 6. Screenshots & Blog Entry

#### Home-screen screenshot (automated)

No manual screenshot step and no user gate — capture it:

```bash
scripts/screenshot-gpty docs/static/images/vX.Y.Z_1.png godot --path godot
```

If a GUI is already running on the desktop, wrap that command in the private runtime sandbox from Gotchas — the script sandboxes user data but not `XDG_RUNTIME_DIR`/`GPTY_SOCKET`, so the capture otherwise shows the second-instance refusal.

The script launches the app in a sandboxed user-data dir (fresh home screen), finds its window on XWayland, waits for first frames, captures, and tears down. Requires ImageMagick `import` + python3-Xlib + a graphical session. If it fails on the current machine (no XWayland window, missing tooling), report the failure and ask the user for the image — that is the exception path, not a routine gate.

Then run a **vision sanity pass** on the capture (harness vision Q&A on the PNG): ask for defects only — giant overlays, clipped controls, overlapping sections. Fix anything real before proceeding; note anything cosmetic for the user.

#### Feature screenshots (user-steered)

From the commit analysis' visible-UI list, ask the user which features deserve a screenshot in the blog. For each: stage it with `--state <name>` and re-capture via `scripts/screenshot-gpty` (name the file `vX.Y.Z_<n>.png`), or the user supplies the image. The home page still gets only `vX.Y.Z_1.png` (see step 3).

**Staging a UI state.** Every captured frame is whatever the window is showing at capture time, so a state that needs clicks has to be opened for you:

- `scripts/screenshot-gpty <out.png> --state <name> godot --path godot` runs the committed driver (`godot/tests/bench/ui_capture.gd`) and waits for it to report the state ready before the grab. `scripts/ui-capture --list` prints the states; the table covers first launch, the overlays, the three window sizes and the wiki, link-graph, concept-editor, plugin-review and trust surfaces. A feature that needs a state the table lacks gets one there (then run `scripts/ui-capture-check`) instead of a temporary scene.
- Do **not** stage through GUT: a non-headless `-s addons/gut/gut_cmdln.gd` run shows GUT's own runner panel, so the capture comes back as the test UI rather than the app.
- Size the window to something that fits the *physical* screen (`DisplayServer.screen_get_size()` can report a multi-monitor desktop much larger than any single screen; an off-screen window captures clipped), and zoom/fit the content so nothing is cut off — a state-specific zoom (the concept canvas needed `_graph.zoom = 0.6` for five rule rows) belongs in its `STATES` entry.
- `SCREENSHOT_WAIT=<seconds>` raises the settle time when the staged frame arrives later than a plain startup; check the result with the vision pass (below) before wiring it into the blog.

#### Blog entry

Create: `docs/content/blog/vX.Y.Z/index.md`

Follow the established pattern (see `v0.2.0/index.md`):

```markdown
---
title: gpty vX.Y.Z
date: YYYY-MM-DD
---

Brief intro line.

<!--more-->

![Screenshot](/images/vX.Y.Z_1.png)

**Feature heading.** Description of key features.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/vX.Y.Z).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#XYZ--YYYY-MM-DD).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
```

- Reference feature screenshots in the body as `![…](/images/vX.Y.Z_<n>.png)` next to the feature they show.
- Confirm every referenced image exists under `docs/static/images/` before proceeding — a broken image must never deploy.
- A patch release with no visual changes may reuse the previous home screenshot (`cp docs/static/images/vPREV_1.png docs/static/images/vX.Y.Z_1.png`) — but a fresh capture is preferred since it's now automated.

### 7. Final Review Pause — STOP

All prep work ends HERE. Do NOT commit or tag yet. Present to the user:

- The CHANGELOG summary for the version
- The blog draft path (and its text)
- The captured screenshots

Wait for an explicit OK. The user may re-word the blog entry, replace images, or request additional feature screenshots. Iterate on their feedback, then proceed only on their go-ahead.

### 8. Commit and Tag

```bash
# Run final ci-check
./scripts/ci-check

git add CHANGELOG.md README.md ROADMAP.md docs/content/blog/vX.Y.Z/ docs/static/images/vX.Y.Z_*.png docs/content/_index.md crates/*/Cargo.toml Cargo.lock
git commit -m "docs: finalize vX.Y.Z release — CHANGELOG date, README links, ROADMAP, crate versions, blog entry"

# Push commits
git push origin main

# STOP: wait for the ci.yml run on that push to finish green — Windows legs
# included — before tagging. release.yml builds the artifacts from the tagged
# commit, so tagging first means shipping whatever that run would have caught.

# Tag and push (triggers release workflow). The tag is signed: the repository's
# `tag` ruleset requires a signature for every non-bypass actor, and the tag is
# the release's identity. Configure a key first (`user.signingkey`, or
# `gpg.format ssh` plus the public-key path), and `git tag -v` must verify
# before the push - being the admin bypasses the rule, not the reason for it.
git tag -s vX.Y.Z -m "vX.Y.Z"
git tag -v vX.Y.Z
git push origin vX.Y.Z
```

The tag push also runs the `pre-push` hook (the full `ci-check`), so expect it to take a couple of minutes and to survive being backgrounded — the push lands after the hook finishes. Verify with `git ls-remote --tags origin vX.Y.Z` rather than assuming.

### 9. Verify CI

Four workflows can fire:

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Push to `main` | Rust tests, clippy, fmt, GUT tests, Windows compile check |
| `release.yml` | Tag `v*` | Build GDExtension per platform, export standalone apps, create GitHub Release |
| `docs.yml` | Docs changes | Build Hugo site, deploy to GitHub Pages |
| `mcp-registry.yml` | Release published (and `workflow_dispatch`) | Publish `server.json` to the official MCP registry over OIDC; no secret |

- All workflows use `${{ github.ref_name }}` — no hardcoded version numbers
- Release artifacts are named: `gpty-vX.Y.Z-linux-x86_64.tar.gz`, `gpty-vX.Y.Z-windows-x86_64.zip`, `gpty-vX.Y.Z-macos.zip`
- The docs build verifies the mirrored README actually baked into the overview before deploying — a wrong mirror fails the deploy rather than shipping silently.
- `gh run watch` can exit non-zero on a transient API error while the run is still going; confirm with `gh run view <id> --json status,conclusion` before treating anything as a failure.

### 10. Release Tail (after the tag's workflow finishes)

The release is not finished when the tag is pushed:

- **Verify the assets.** Three archives, each carrying `LICENSE` and `LICENSE-EXCEPTIONS.md` next to the binaries (GPLv3 §4/§6 requires giving recipients a copy — a missing copy is a license violation, not a cosmetic gap), plus the `SHA256SUMS` asset covering every upload and the build-provenance attestation. Concretely: `gh release download` the sums + archives, `sha256sum -c --ignore-missing SHA256SUMS`, `tar -tzf` / `unzip -l` for the two license files in each archive, and for the attestation **compare the subject digest** — `gh attestation verify <asset> --repo godot-pty/gpty --format json` (gh 2.102.0 prints nothing and **exits 0 even for a file with no matching attestation**, so the exit code proves nothing) and check that `verificationResult.statement.subject[0].digest.sha256` equals the asset's own SHA-256 and that `signature.certificate.buildSignerURI` names `release.yml@refs/tags/vX.Y.Z`.
- **Update the AUR recipe** (`dist/aur/PKGBUILD`) for the release: `pkgver`/`pkgrel`, the tarball's `sha256sums` line from the release's `SHA256SUMS` asset (the two local-file sums stay), and the bundle's current layout (the CLI as `gpty`, the GUI as `gpty-gui` with `gpty-gui.pck` + `libgpty_gdext.linux.x86_64.so`, both on PATH, the desktop entry pointing at `gpty-gui`, and the icon from `godot/icon.png`). Validate before committing: copy `PKGBUILD` + `gpty.desktop` + `gpty.png` to a temp dir and run `makepkg --noconfirm` there (it downloads the released tarball and checks the sums; building in-tree would leave untracked `src/`/`pkg/`/package files). Publishing to `aur.archlinux.org` is a separate step that needs an AUR-registered SSH key — probe with `ssh -T aur@aur.archlinux.org` and report if there is no access.
- **Publish the crates to crates.io** (the CLI ships there now, so this is part of the release, not an extra). From the release commit with a clean tree, in dependency order — the order is enforced, not conventional: `gpty-ipc` cannot even be packaged until `gpty-core` is in the index.

  ```bash
  cargo publish -p gpty-core
  cargo search gpty-core            # wait until the new version lists
  cargo publish -p gpty-ipc
  cargo publish -p gpty
  ```

  `cargo publish` runs the packaged tarball's verify build, so run `cargo package -p <crate>` (no `--no-verify`) before tagging; a file the crate embeds from outside its own directory fails there. A version can be published only once: if `gpty-core` lands and `gpty-ipc` fails, fix the cause and publish only the rest. Token: `cargo login` on the maintainer's machine — do **not** put a crates.io token in CI while any repository writer can push a `v*` tag (the v0.7.1 tag-ruleset row), because that turns a tag push into a crate published under the project's name.
- **Publish the MCP registry entry** once the crates are live. `.github/workflows/mcp-registry.yml` already does this: it fires on `release: published` (skipping prereleases), refuses to run when `server.json` does not name the released version or the crate is missing from crates.io, verifies the `mcp-publisher` tarball against its Sigstore bundle, then publishes over OIDC — no secret. Check that the entry appears; do not publish by hand. For a version whose release already ran, or a descriptor fix, run it by hand on the ref that carries the descriptor: `gh workflow run mcp-registry.yml`. A local run needs a PAT with `read:org` (`mcp-publisher login github --token …`) because the device flow cannot publish to the org namespace.

## Gotchas

- **`cargo package --no-verify` hides the packaging bug that matters.** The verify step compiles the tarball cargo would upload; without it a crate that only builds in the workspace looks ready. Anything `include_str!`d into a published crate must live **inside that crate's directory** — `cargo package` copies only the package, so a path reaching above `crates/<crate>/` compiles in the workspace and fails at publish (this is why the agent skill lives at `crates/gpty-cli/skills/gpty/SKILL.md`).
- **`ci-check` must pass before tagging.** Run `./scripts/ci-check` explicitly. The pre-push hook also enforces this.
- **Windows behavior is only proven in CI.** `ci-check`'s Windows step is a cross-compile; the runtime legs (`windows-smoke`, GUT on Windows) live in `ci.yml`. A release whose Windows jobs have not run green on the tagged commit is unverified on that platform.
- **GDExtension rebuilds.** After changing `#[func]` signatures or adding methods in Rust, rebuild with `cargo build -p gpty-gdext` and restart Godot. CI does this automatically.
- **`.uid` files must be committed.** Godot 4 `.uid` files are essential for stable resource referencing — always commit them alongside `.gd` files.
- **Screenshot capture.** `scripts/screenshot-gpty` needs XWayland (Godot's window visible in the X tree) — on a pure-Wayland session the window won't be found; report and ask the user. The vision sanity pass is advisory: it catches gross breakage, but its text readings need source verification. The grab itself is a list of backends tried in turn under `CAPTURE_TIMEOUT` (`SCREENSHOT_TIMEOUT`, default 20 s): ffmpeg's `x11grab -window_id` can attach to nothing and print nothing (measured on this XWayland session, 2026-11-06), so a timeout hands over to ImageMagick's `import` instead of failing the run — `SCREENSHOT_CAPTURE=import` skips the stall when you know ffmpeg cannot grab here.
- **Screenshot sandbox.** `scripts/screenshot-gpty` creates its own private sandbox (`scripts/ui-sandbox`: `HOME`, `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME`/`XDG_RUNTIME_DIR`, `GPTY_TEST_USER_DIR`, `GPTY_SOCKET`, `GPTY_SECRET` cleared), so a GUI already running on the desktop can no longer own the control socket and turn the capture into "Another gPTY window is already running — this one will close.". `--state <name>` stages a committed UI state (`scripts/ui-capture --list`) and waits for it to report ready before the grab; use it for feature screenshots that would otherwise need a hand-driven interaction.
- **Tag immutability.** If you need to move a tag (e.g., to include a last-minute fix), use `git tag -f -s vX.Y.Z -m "vX.Y.Z" && git push -f origin vX.Y.Z`, then `git tag -v` it again. The release workflow will re-run.
- **Docs mirrors are build artifacts.** `docs/assets/repo/`, `docs/data/`, `docs/.cache/` are gitignored; `docs.yml` runs `docs/setup.sh` to regenerate them from the root files on every docs-touching push. Never commit them.
- **Tool tarballs clobber repo files.** The Hugo release tarball ships `README.md` and `LICENSE`; extracting it in the workspace root overwrites the repo's copies before the docs mirror step reads them (this shipped Hugo's README as our docs for several deploys). Always extract with the member name (`tar -xzf …tar.gz hugo`) or into a temp dir.
- **Docs workflow trigger paths.** `.github/workflows/docs.yml` itself is NOT in its own `paths` filter — workflow-only changes don't fire the docs build. Trigger it with a docs-touching change or `workflow_dispatch`.
- **Docs versions dropdown.** `docs/setup.sh` fetches release tags from the GitHub API (cached 1 hour). New releases appear automatically after cache expiry — no manual edit.
- **CHANGELOG link format.** The version link at the bottom uses anchor format matching the heading: `#030--2026-08-09` for `## [0.3.0] — 2026-08-09`. Punctuation is stripped. Version-link definitions sit in a block right after their version's section (`[0.5.6]: …/compare/v0.5.5...v0.5.6`).
- **No `dev/v*` branches.** Trunk-based development on `main` only. Feature branches are short-lived.
