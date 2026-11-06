---
name: gpty-session-wrap-up
description: "Close a gpty working session: audit the documentation mirrors the work touched, verify the wiki bundle, decide whether a skill or memory should capture a lesson, and leave no loose thread. Use when asked whether anything needs wrapping up before closing a session, or whether docs, wiki or skills need updates from the work just finished."
---

# gpty session wrap-up

`skill://gpty-roadmap-task` closes a *row*; `skill://commit` owns the commit, push and remote gate. This page closes a *session*: the fan-out a change rippled into, the lessons worth keeping, and the state you leave behind. Run it after the commits are pushed, before the final reply.

## 1. Documentation mirrors

The commit skill already lists README freshness (root phases, `crates/*/README.md`, `godot/README.md` structure). Check those first, then these, which a commit does not always prompt:

| What changed | Also check |
|---|---|
| A trust boundary (file-supplied data, env, spawn, sockets, IPC, plugins) | `SECURITY.md` (policy) **and** `docs/content/docs/agents/security.md` (implementation constraint) in the same commit; a change to one without the other means they now disagree |
| A contract other code relies on (attach hooks, per-pane state, restore paths, companion routing) | the owning guide under `docs/content/docs/agents/` (`rust`, `gdscript`, `inspector-reasoning-omp`, `concept-capture`, `plugins`) |
| A gate, command, or trap | `docs/content/docs/agents/testing.md` (what a pass means) or `pitfalls.md` (traps) - one owner, never a second copy |
| User-visible behavior | the wiki pages under `docs/content/wiki/**` that describe it, then the bundle step below |
| A closed or narrowed roadmap row | row flipped in place with evidence/tests/measured numbers; every new defect queued as its own row |
| A count repeated in prose (autoloads, pane types, crates) | every place the number appears - `grep` the number, not just the sentence you remember |

Changelog pages are release-time work: do not write one mid-cycle. Leave the release's DOCS row queued and keep the user-facing summary in the closed row.

## 2. Wiki and bundle

After any `docs/content/wiki/**` edit run `python3 scripts/build-wiki` and commit `godot/knowledge.json` - the bundle check fails otherwise, and it is what release builds read (`skill://gpty-wiki`). Verify the docs tree with `python3 scripts/docs-check`. Neither replaces `./scripts/ci-check`; they are the docs half of it.

## 3. Skills and memory

- **Is any existing skill now false?** `gpty-roadmap-task` carries the gate table (mirrors `scripts/ci-check`), `gpty-wiki` the bundle steps, `gpty-public-surface` and `gpty-add-pane-type` their registration surfaces. Fix the owning skill in the same session; do not fork it.
- **Did the work produce a repeatable procedure?** Add a skill only for a sequence worth re-running (setup, triage, review method), and extend an existing skill before creating a near-duplicate. A single fact is not a skill.
- **Trap or convention?** Traps go to `pitfalls.md`/`testing.md`; durable project conventions go to the topic guide. Memory is for cross-cutting facts that no guide owns - keep it sparse and do not copy a repo doc into it.
- Project skills live at `.omp/skills/<name>/SKILL.md` and travel with the clone; `~/.omp/agent/managed-skills` is lower precedence and does not. Never fork a project skill into the managed directory.

## 4. Loose threads and delivery

- Anything found but not fixed becomes a roadmap row in priority position (data-loss/correctness, then security, then features, then robustness, then polish). Not a comment, not folded into an unrelated row.
- `git status` clean: no scratch scripts, seeded stores, probes or screenshots. The only exception is an evidence image a row points at, named `issue-<build>-<slug>.png` under `docs/static/images/` and listed in the chain page's `## Screenshots`.
- The pushed range has a green remote gate, and which one depends on the paths: code runs the eight-job `CI` workflow, a docs-only range (including `godot/knowledge.json` alone) runs `Docs` instead. Report the run id and conclusion, never just "pushed".
- `.omp/skills/**` starts none of the app workflows (CI ignores markdown, `Docs` lists specific paths), but it is not a silent range: `Scorecard` runs on every push to main, so report that run and do not imply CI covered a skill. The pre-push hook takes its docs-only fast path, which runs `docs-check` over the skill text (link/anchor resolution only) and nothing about its frontmatter or procedure. Read the skill diff and its `name`/`description` yourself.
- Stop after the report. Do not start the next row unless asked.
