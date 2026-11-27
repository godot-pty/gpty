---
name: commit
description: "Find untracked/unstaged changes, group related diffs into Conventional Commits, then push and confirm CI (with triage on red)."
---

# Commit Workflow

Find all uncommitted changes, analyze and group them, then commit with meaningful Conventional Commits messages.

## Procedure

### 1. Discover changes

Run `git status --short` and `git diff --stat` to see what's pending. Include untracked files.

```bash
git status --short
git diff --stat
git diff --stat --cached
```

### 2. Review each file

For every changed file, read the diff to understand the nature of the change:

```bash
git diff -- <path>       # unstaged changes
git diff --cached -- <path>  # staged changes
```

For new (untracked) files, read the file content directly:
```
read <path>
```

### 3. Group related changes

Identify logical groups of changes that should be committed together:
- A feature implementation spanning multiple files
- A bug fix with its test
- Refactoring that touches several modules
- Independent cleanup or docs

Each group becomes one commit. Unrelated changes go in separate commits.

### 4. Determine commit type and scope

Use Conventional Commits format: `type(scope): description`

Types:
- `feat` — new feature or capability
- `fix` — bug fix
- `refactor` — code restructure without behavior change
- `chore` — maintenance, build, deps
- `docs` — documentation only
- `test` — test additions or fixes
- `style` — formatting, whitespace

Scopes: match the project's approved scopes per AGENTS.md: `settings`, `terminal`, `layout`, `workspace`, `sidebar`, `ui`, `gdext`, `core`, `cli`, `ipc`, `profiles`, `concepts`, `icons`, `ci`, `ai`, `inspector`. For cross-cutting changes, use `core`.

### 5. Commit

Every commit needs a DCO `Signed-off-by` trailer; `git commit -s` adds it and `githooks/commit-msg` refuses a commit without one.

Commit each group separately with a meaningful message:

```bash
git add <files in group>
git commit -s -m "type(scope): description" -m "Additional body details if needed"
```

**Under OMP's harness, never `git add`/`git commit`**: the worktree is shared with other agents and the user, so the `commit` namespace (`commit.draft()` then `d.commit(subject, …)`) is what selects only your own lines. Five traps there, each of which costs a round of failures: the JS signature takes an **options object** - `d.commit("type(scope): x", { body: ["- …"] })` - so a positional array commits a subject-only message in silence; the helper does not add `-s`, so the `Signed-off-by: Name <email>` line must be the last entry of that body array (the hook sees the message it is handed, so the omission reads as "missing a DCO sign-off"); and a binary file reported as "its shared-index entry holds someone else's staged changes" can be committed while the shared index keeps a staged **deletion** of it (`git status` shows `D` plus an untracked `??`); and, in JS, `only()` with several positional globs selects only the first (measured: eleven paths, one kept), so split a multi-file commit with `drop("**")` then `take(path)` per file, and use `drop(path, { units: [...] })` for the hunks of a shared file. Selection is per hunk and per actor, not per line: two adjacent changed lines (neighbouring roadmap rows whose status cells both flip) are one unit and cannot be split, so when one session closes several rows, put the roadmap flips in their own `docs:` commit instead of trying to attach each row to its code commit - and `drop(grep=...)` on one row takes its neighbour with it. The commit's blob is right - verify `git hash-object <path>` equals `git rev-parse HEAD:<path>` - then repair only the index with `git update-index --add --cacheinfo <mode>,<blob>,<path>`, never `git add`/`git reset`. Take `<mode>` from `git ls-tree HEAD <path>`, not from this example: a file edited through bash (heredoc, sed, codegen) is the usual trigger, and hardcoding `100644` for an executable script (`scripts/record-demo` is `100755`) leaves `git status` showing `MM` with a zero-line diff until the mode is restored. The same entry on a path with no content change still counts - check `git status --porcelain` is empty afterwards, not just that the diff is.

A `fix` commit's message carries `Cause: <class>`, one value from
`docs/content/docs/agents/defect-classes.md` (`./scripts/fix-forensics --classes`
prints them). Under the OMP `commit` namespace the body array ends
`[…body, "Cause: <class>", "Signed-off-by: …"]` - the sign-off stays last.

### 6. Report

Summarize what was committed, in which groups, and why. Note any files deliberately left uncommitted and why.

## Validate end to end

Commit is the half you can check locally. When the project validates on a remote (CI runs on push or PR), a local pass is necessary, not sufficient — the run is the evidence the change works on the platforms and toolchains the project actually ships. This repo is trunk-based: day-to-day work branches from `main` and lands there through a pull request protected by a ruleset that requires an approval, last-push approval and the required checks. `release/vX.Y` branches are maintenance bases, not development branches. `scripts/pr push` pushes the work branch (splitting a workflow edit between the maintainer and the app), `scripts/pr open` opens the PR as `gpty-bot`, and `scripts/pr land <pr> --approve` posts the maintainer's approval, enqueues and waits.

1. **Local gate first.** `./scripts/ci-check` (full, not `--fast`) and the pre-push hook are the local half. Do not push on a red local gate.
2. **Push once per batch**, not once per commit: a **code PR** runs the full matrix (Rust, GUT, Windows, macOS, smoke) and is the remote gate. A **docs-only PR** (the `DOCS_PATTERNS` list in `scripts/ci-classes.env`: docs, Markdown, workflow YAML (lint-only), the five docs scripts `docs-check`/`check-capabilities`/`build-wiki`/`build-docs`/`roadmap`, and the generated knowledge/docs bundles) runs only `changes`, `lint-workflows`, `docs`, `commit-lint` and `ci-gate`; the heavy jobs are skipped and report success. A workflow-only PR is docs-only; `lint-workflows` still runs. CodeQL and Secret scan still run on every PR. A post-merge push to `main` runs no `ci.yml`; only `Docs` (matching paths), `Scorecard` and Secret scan fire, and release-branch pushes still run it. Report the workflows that actually fired or say none did. If the changes are not meant to land yet, hold the commits and say so; do not push for review you were not asked for.
3. **Identify the run for the pushed SHA and watch it**:

```bash
./scripts/pr push                # the split push; or git push origin HEAD with your key
gh run list --workflow=CI --limit 1 --json databaseId,headSha   # confirm headSha matches
gh run watch <id> --interval 20 --exit-status
gh run view <id> --json conclusion,jobs --jq '"run=" + .conclusion, (.jobs[] | "  \(.name): \(.conclusion)")'
```

A range that edits `.github/workflows/**` cannot be pushed by the app: the installation grants only `contents`, `metadata` and `pull_requests`, and GitHub refuses an App push that creates or updates a workflow ("refusing to allow a GitHub App to create or update workflow … without `workflows` permission") — measured 2026-11-17, after the whole pre-push gate had already run. `scripts/pr push` owns that split: it pushes the newest workflow-touching commit with the maintainer's `gh` token (through `GIT_ASKPASS`, never argv) and then pushes a final non-workflow commit as the app. It refuses when the newest commit is the workflow one, so add a non-workflow commit after it. Measured 2026-11-25: SSH dies with `SIGPIPE` (exit 141) right after the hook when the full gate keeps the connection idle for ~6 minutes; push that first range over HTTPS with the maintainer's `workflow`-scoped token instead - `gh auth token` into a 0600 file, `GIT_ASKPASS=scripts/git-askpass-token`, and `https://<login>@github.com/godot-pty/gpty.git` (the token stays out of argv). The later bot push is docs-only, so its hook is seconds. The app is the last pusher, so the maintainer's approval satisfies `main`'s last-push rule; `scripts/pr push` does both pushes, and `scripts/pr open` opens the PR. Do not grant the App Workflows write: a same-repository PR workflow runs with repository secrets before any human merges it.

**The last push must be a forward push by the bot, and the PR must be the bot's.** `main`'s ruleset also rejects an approval from the last pusher and has no bypass actors. A commit pushed with the maintainer's credential leaves the maintainer as the last pusher, so the approval cannot count - `gh pr merge` answers "New changes require approval from someone other than <login> because they were the last pusher" - and a later bot *force* push that rewrites that commit does not clear it; a forward bot push of a new commit does (measured 2026-11-22, dependabot PRs #18/#19). The new commit must change the diff: an empty bot commit is not a reviewable push, so the approval still reads "At least 1 approving review is required" (measured 2026-11-26, PR #58) - land a real non-workflow change as the bot's last push. A PR opened with the maintainer's credential can never be approved, because GitHub forbids approving a pull request you created: open it with `scripts/pr open` from the start, or close and recreate it as a bot PR, accepting that the closed original still counts in the merge-ratio metric (#22 -> #23).

A release PR from the `release-prep/vX.Y.Z` branch runs `CI`, `CodeQL` and `Secret scan` on the PR; watch those checks before the maintainer approves and merges it. A release's own runbook is `skill://release`.

4. **Land it.** Never click **Update branch** and never run `gh pr update-branch`. `scripts/pr land <pr> --approve` posts the maintainer's approval and enqueues the PR with `gh pr merge --auto --merge`, and the queue rebuilds it on the latest `main` and runs the required checks there. An approved PR that is `BEHIND` is not a problem — enqueue it. The queue half is `scripts/pr wait <pr>`: it polls the PR and its queue entry, fails fast on a failed merge-group run, and prints the merge commit plus every merge-group run's conclusion; use it instead of hand-built `gh run list` loops (the `gh event listen` hint `gh` prints is not enabled for this account). If the queue is unavailable (release branches), sync locally with a signed `git merge origin/main`, push through `scripts/pr push --base release/vX.Y`, and re-approve; do not let GitHub create the merge commit. After merge, the remote branch is deleted automatically; run `scripts/pr prune` for the local one and for any other branch already contained in `origin/main`.

5. **Report the run's conclusion and the SHA** with the work. Green on CI is part of the deliverable; "pushed" is not.

## When CI is red

Do not guess, and do not re-run until it passes by luck.

1. Read the failing **step** of the failing **job**, not the last line of the job:
   `gh run view <run> --job <job> --log-failed` (or `--log` for the whole job).
2. **Triage with the project's own procedure if one exists** — read the matching skill or doc before forming a hypothesis:
   - The Windows job (`windows`) and the macOS job (`macos`): `skill://gpty-windows-ci-triage` — it classifies ConPTY silence, cargo build failures, the `ETXTBSY` race, and cache regressions.
   - The gate itself (what runs, what a pass means): `docs/content/docs/agents/testing.md`.
3. **A green-but-slow run is usually a cache miss, not a code change.** Compare the step time to its warm value (this repo: Windows build 28 s warm / 150 s cold, media deps 0 s / ~105 s) and read the `Cache …` step for `Cache not found`. A miss right after a lockfile or build-script change is expected.
4. **Rerun only known transients**: `gh run rerun <run> --failed`. Never add retries to mask a deterministic failure — fix the cause.
5. **Fix the assertion first when the failure is a harness bug.** A step that cannot say whether its program ran is a defect in the step, and the next failure should explain itself.
6. Re-push the fix and confirm the new run green; the report names the final SHA.

## Rules

- NEVER commit files that are throwaway/test scripts, generated build artifacts, or editor temp files (`test_key.rs`, `*.tmp`, etc.)
- In Godot 4 projects, `.uid` files MUST be committed — they are essential for stable resource referencing across renames. Always pair a new `.gd` file with its `.uid`.
- NEVER commit `.godot/` or `.import/` directories unless explicitly asked
- Each commit MUST be self-contained and buildable
- Group by logical change, not by file type or directory
- If a file has both staged and unstaged changes, warn the user before staging
- Default to committing everything that looks intentional; ask only when genuinely ambiguous
- Before skipping a file, check if similar files are already tracked in the repo (`git ls-files`)
- **Check the index, not just your intent.** `git diff --cached --name-only` before committing: the index is shared with every other process touching this checkout (another agent, a script, a vendoring refresh), and work staged by someone else lands in your commit under your message. Stage explicit paths and confirm the staged list matches the commit's story; if it does not, unstage the extras or split them into their own commit.
- **README freshness**: Before committing, check if the change affects documentation. The README update MUST be in the same commit or an immediately following `docs(scope):` commit:
  - **API surface changes**: new/removed/renamed `#[func]` methods → update `crates/gpty-gdext/README.md` API table
  - **New/removed modules**: files added/removed from `src/` → update `crates/gpty-core/README.md` module table
  - **New GDScript files or autoloads**: → update `godot/README.md` structure section
  - **Feature completion**: phase checklist item marked done → update root `README.md` implementation phases
  - **Architecture changes**: data flow, concept system, new pitfalls → update root `README.md` and/or `AGENTS.md`
- **DCO**: every commit carries a `Signed-off-by` trailer (`git commit -s`); `githooks/commit-msg` refuses a commit without one. Existing commits are grandfathered.
- **Roadmap trailer**: a commit that advances a roadmap row carries `Roadmap: <ID>` (e.g. `Roadmap: GUI-188`) in the body; `./scripts/roadmap close <ID>` reads it to fill the row's `Commits:` line. No ID for work that is not a roadmap row.
- **Pre-commit gate**: the pre-commit hook runs `scripts/ci-check --fast`; the pre-push hook runs `scripts/ci-check --stamped` (the full suite on a changed tree; a repeated push of the same clean tree skips via the stamp). Both classify the changed paths (docs / tooling / code), so a docs edit or a measurement-script edit never buys the Rust, GUT and smoke jobs it cannot influence. Run `./scripts/ci-check --fast` before staging - it is seconds and it runs the cost gates - and let the hook do the full run when the tree changed; running the full suite by hand first doubles a 300 s suite the hook repeats immediately. Run the **full** suite up front only when the change edits a gate runner or an app driver (`scripts/ci-check`, `scripts/gut-check`, `scripts/smoke_pane_api.py`, `scripts/media-deps`, `scripts/lint-workflows`) or anything the classifier calls code: a gate is validated by run…
- **Done means both halves**: local gate green *and* the PR's required checks green. A post-merge push to `main` does not re-run CI, so there is no separate main run to wait for. Never report a task complete while the PR's CI is red or never run.
