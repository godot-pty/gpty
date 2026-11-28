---
title: "Roadmap workflow"
weight: 12
---

The roadmap is a prioritized queue. `ROADMAP.md` is the root index; each release chain is a page under `docs/content/docs/roadmap/` (`v0.1.md` … `v1.0.md`, `future.md`); each row's evidence is a section on `docs/content/docs/roadmap/details/<area>.md`. The stable ID is the join key: the capability catalogue, commit trailers and cross-references name a row by `AREA-N`, never by its title.

`scripts/roadmap` is the reader and writer. Start a task with `./scripts/roadmap next`; read `./scripts/roadmap show <ID>` instead of the chain page - the page is the queue, the detail section is the record. The other commands are `next-id`, `add`, `move`, `record`, `close`, `rearea`, `stats`, `release-check` and `audit`.

## Anatomy

Index row, on a chain page:

```markdown
| ⬜ | [GUI-188](details/gui.md#gui-188) | **The app reports its own cost: frame time, CPU, memory and power** |
```

Detail section, on `details/gui.md`:

```markdown
## GUI-188

**The app reports its own cost: frame time, CPU, memory and power** - the failure
observed, the fix, the measured numbers and the tests by name.

Commits: 1a2b3c4, 5d6e7f8
```

- **Status:** `⬜` open, `✅` completed, `🚫` dropped or superseded, `❌` won't fix. A dropped row keeps its detail and says why; a won't-fix row records why the work was declined and carries no `Commits:` line. Neither is picked and neither is closed as done.
- **IDs:** an uppercase area prefix plus a number (`GUI-188`). The prefix is the area, which is why there is no Area column. An ID is allocated once (`./scripts/roadmap next-id GUI`) and is never renumbered or reused. A row that moves between releases or chains keeps its ID, and its detail section does not move: detail pages are per area, the index is per release. A wrong area is a new ID through `./scripts/roadmap rearea <ID> <AREA>`, open rows only.
- **Priority:** position on the chain page is the priority. IDs are identity, not order; never sort the queue by ID.
- **Title:** a pointer, not the record. Keep it a phrase; the sentence, evidence and commit list belong to the detail.

## Queue rules

- **The queue is the priority:** within a release, row order *is* the priority, and the first unchecked row (⬜) in the earliest unfinished release is the answer to "what's next" (`./scripts/roadmap next`). `next --limit N` lists more, `--chain PAGE` and `--area AREA` narrow the same query, and `--json` prints a list for a tool to read.
- **Open counts are data, not prose:** `ROADMAP.md`'s release-chain list carries each page's open count (`- planned, 114 open`). `./scripts/roadmap stats --write` writes it, `add`, `move` and `close` refresh it, and `./scripts/roadmap audit` fails a stale line.
- **Release chain order:** open the chain pages in version order; `future.md` is never picked from.
- **Read the record, not the page:** `./scripts/roadmap show <ID>` prints one row's section and its commits, and `next --json`/`stats --json` print data for a tool. Pasting a whole chain or detail page spends context on rows the task does not touch.
- **No separate grouping:** no headings by origin or carry-over. Finished rows stay in place, and the changelog carries the user-facing release notes.

## Priority ordering rules

When adding or re-prioritizing rows, follow this strict precedence:

1. **Data-loss and correctness:** bugs causing data corruption, accidental deletion, or broken core behavior.
2. **Security with reachable path:** exploitable or exposed security defects.
3. **Release headline features:** the primary differentiating features scoped for the release.
4. **Robustness and automated tests:** flake fixes, test coverage, race elimination.
5. **Low-reachability hardening:** defense-in-depth and static verifications.
6. **Polish and aesthetics:** visual consistency, theme alignment, copy improvements.
7. **Release-time tasks:** packaging, tagging, and deployment verification.

Ties break toward the smaller item.

## Handoff

A plan handed to another agent is an execution spec: signatures, paths, edge cases, exact commands and the acceptance check - never code or prose bodies. The reader has the repository, and a pasted body is re-read on every later turn and stale the moment the code moves. Quote only a load-bearing literal - a message, a wire key, a search token, a section that must be exact - and name paths and symbols for the rest.

## Screenshots

Screenshots live on their own page per chain, `docs/content/docs/roadmap/screenshots/<page>.md`, under `## Screenshots`. The chain page is the queue and carries no captures; it links the release page in one line, and a capture that covers rows from several areas stays there instead of being duplicated into each area file. A row's detail links the caption and the page anchor:

```markdown
Screenshot: *The light chrome over four terminal panes* ([captures](../screenshots/v0.8.md#screenshots)).
```

Never embed an image in an index row, a detail section or a chain page. Release screenshots are `v<version>_<n>.png`; roadmap evidence is `issue-v<build>-<slug>.png`, both under `docs/static/images/`.

## Commit provenance

- A commit that advances a row carries a `Roadmap: <ID>` trailer (e.g. `Roadmap: GUI-188`).
- `./scripts/roadmap close <ID>` reads those trailers, falls back to the row's line history for pre-ledger work, and writes the oldest-first `Commits:` list. Never hand-type a hash.
- `Commits: unrecorded` is written only under `--force`, when no commit can be attributed. It is a gap to fix, not a value to reuse.
- `./scripts/roadmap release-check vX.Y.Z` fails a release that still has an open row in its section, or a closed row without a `Commits:` line; `--open` lists the open rows (id and title) instead of failing on them.

## Adding a row

1. Write the detail body to a file. Its first paragraph is `**Title** - evidence`, and the evidence is what makes the row actionable: the failure observation (build, date, command), the code location, the fix direction, the tests to add, the measured numbers.
2. Add it: `./scripts/roadmap add <AREA> --body-file FILE`. It allocates the next ID, writes the `## <ID>` section and places the index row at the end of the working section; `--after ROW` and `--before ROW` put it at its priority position, `--chain PAGE` names another release chain, and `--dry-run` prints the row and writes nothing. The body is wrapped at 100 columns.
3. Rewrite a row's evidence later with `./scripts/roadmap record <ID> --body-file FILE`, or add a paragraph with `--append`. A retitle is a two-file edit: `record` refuses a body whose title differs from the index row's.
4. `./scripts/roadmap move <ID> <release>` moves an open row between releases or chains; the ID and the detail section do not change.
5. A defect or follow-up discovered while working another row gets its own row in priority position - never a silent fix, a comment, or a fold into an unrelated commit.
6. `./scripts/roadmap audit` proves the ledger's evidence: every `Commits:` hash is reachable, no detail or screenshot line is over 768 bytes, every ID cited in prose is a row, a dropped or won't-fix row states why, and the release-chain list's open counts match. `ci-check` and the `Docs` workflow run it.

## Closing a row

1. Write the record to a file whose first line is the row's `**Title** - ...`; `./scripts/roadmap close <ID> --record FILE` validates and writes it and closes in one call. The title must match the index row and the body cannot carry a `Commits:` line; a refusal leaves the row open. `record` remains for rewriting an open row without closing it.
2. If close cannot find a commit, add the `Roadmap: <ID>` trailer to the fix commit and retry; `--force` is for a row whose work genuinely has no commit.
3. If the row closed a bug, the fix commit carries a `Cause: <class>` trailer matching [Defect classes](defect-classes.md).
4. A screenshot reference links the release's `screenshots/<page>.md` as above.
5. Gates: `python3 scripts/docs-check`, `./scripts/build-docs`; a catalogue edit also runs `./scripts/check-capabilities`.
6. **Ship it:** name the PR's class in its body (`docs` for roadmap, screenshot and guide content; `code`/`gate` for a runner or workflow edit) and land gate-runner (`scripts/ci-check`, `scripts/gut-check`, `scripts/check-ffi-surface`, `githooks/**`) or workflow changes as their own PR, never inside the content PR - the gate PR pays the full matrix once, and the content PR stays docs-class.

## Adding a release chain

1. Create `docs/content/docs/roadmap/<slug>.md` with front matter (`title`, `weight` incremented from the previous chain).
2. Add a brief paragraph summarizing what the release chain achieves.
3. Add `## vX.Y.Z - Name` sections with three-column index tables.
4. Link the new chain page from `ROADMAP.md` as `docs/content/docs/roadmap/<slug>.md`.

Detail pages are per area, not per chain, so a new chain needs no detail file.

## Restructuring chains

When releases are renumbered or split, preserve the old pages first (`git show HEAD:docs/content/docs/roadmap/<page>.md`), then move index rows by **ID** instead of retyping them. Detail sections do not move unless the area changes.

Verify with a global ID-set diff: extract the `| status | [AREA-N]` IDs from the old and new trees and `comm -23` them. The 2026-11 remap lost one row until that diff caught it. Then sweep `v0.<n>.<m>` outside the roadmap pages - guide text (`testing.md`, `security.md`), blog links and script comments all repeat release numbers - and finish with `scripts/docs-check`.
