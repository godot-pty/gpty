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

Scopes: match the project's approved scopes per AGENTS.md: `settings`, `terminal`, `layout`, `sidebar`, `gdext`, `core`, `cli`, `ipc`, `profiles`, `concepts`, `icons`, `ci`. For cross-cutting changes, use `core`.

### 5. Commit

Commit each group separately with a meaningful message:

```bash
git add <files in group>
git commit -m "type(scope): description" -m "Additional body details if needed"
```

### 6. Report

Summarize what was committed, in which groups, and why. Note any files deliberately left uncommitted and why.

## Validate end to end

Commit is the half you can check locally. When the project validates on a remote (CI runs on push or PR), a local pass is necessary, not sufficient — the run is the evidence the change works on the platforms and toolchains the project actually ships. This repo is main-only with CI on push, no PR review flow.

1. **Local gate first.** `./scripts/ci-check` (full, not `--fast`) and the pre-push hook are the local half. Do not push on a red local gate.
2. **Push once per batch**, not once per commit: each push starts a full validation run (~4-5 minutes here). If the changes are not meant to land yet, hold the commits and say so; do not push for review you were not asked to do.
3. **Identify the run for the pushed SHA and watch it**:

```bash
git push origin HEAD
gh run list --workflow=CI --limit 1 --json databaseId,headSha   # confirm headSha matches
gh run watch <id> --interval 20 --exit-status
gh run view <id> --json conclusion,jobs --jq '"run=" + .conclusion, (.jobs[] | "  \(.name): \(.conclusion)")'
```

4. **Report the run's conclusion and the SHA** with the work. Green on CI is part of the deliverable; "pushed" is not.

## When CI is red

Do not guess, and do not re-run until it passes by luck.

1. Read the failing **step** of the failing **job**, not the last line of the job:
   `gh run view <run> --job <job> --log-failed` (or `--log` for the whole job).
2. **Triage with the project's own procedure if one exists** — read the matching skill or doc before forming a hypothesis:
   - Windows jobs (`windows-smoke`, `rust-windows`): `skill://gpty-windows-ci-triage` — it classifies ConPTY silence, cargo build failures, the `ETXTBSY` race, and cache regressions.
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
- **Pre-commit gate**: `scripts/ci-check` runs automatically in the pre-commit hook (fast checks: fmt, workflow lint, clippy). The pre-push hook runs the full suite. Run `./scripts/ci-check` explicitly before staging to avoid amend churn. The hooks are the enforcement layer; this skill is the guided workflow that should produce passing commits.
- **Done means both halves**: local gate green *and* the pushed run green (when the project has CI). Never report a task complete while its CI is red or never run.
