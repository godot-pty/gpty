---
name: gpty-roadmap-task
description: "Work one gpty roadmap row end to end: pick and re-verify the row, read the area's guides, reproduce, implement, run the per-area gates once, close the row with evidence, commit. Use when told to proceed with the next roadmap task or to close a row."
---

# gpty roadmap task

19 of the 43 archived gpty sessions contain a "next roadmap item" prompt (30 prompts in total). This is that loop: one row, end to end. AGENTS.md stays normative for *which* row is next and how row text is shaped; testing.md for the internals of each gate. This page is the order of operations plus the mistakes that have actually cost time.

## 1. Pick, then re-verify the row

- First ⬜ on the earliest unfinished chain page; within a release, row order is the priority.
- **Rows go stale.** They are written on one build and implemented days later: reproduce the claim on the current build before writing code, and re-locate any `file:line` (numbers drift). The v0.8.1 probe pass found rows already fixed, half-fixed, and describing code that had moved.
- Already fixed? Close it with the evidence. Narrowed? Rewrite the row to what remains. Never add a "corrections" row.

## 2. Read the guides the area touches

AGENTS.md's table: `rust.md`, `gdscript.md`, `security.md`, `pitfalls.md`, `concept-capture.md`, `plugins.md`. `security.md` is mandatory for IPC, PTY, filesystem, plugins, networking or secrets — read before editing, not after.

## 3. Bug rows: reproduce first

A fix without a failing-before observation is a guess. Reproduce on a fresh build, keep what you saw for the commit body, then fix. If a permanent regression test is impractical, say so and smoke the exact scenario instead.

## 4. Implement

- Smallest change that satisfies the row's contract. Migrate every caller, delete the obsolete path — no shims, aliases or re-exports left behind.
- If the row names a security property, close the *door*, not the symptom: the test opens the attack, it does not merely assert a flag is set.
- Scratch scripts and staged scenes are deleted before the commit; they are not committed unless a row says to promote them.

## 5. Gates — once, when the change is complete

| Touched | Gate |
|---|---|
| `crates/**` | `cargo fmt --all`, `cargo clippy --workspace -- -D warnings`, `cargo test -p <crate>`, then `cargo test --workspace` (ci-check runs it serial **and** parallel — the suite must pass both ways) |
| `godot/**` | new `class_name` → `godot --headless --path godot --import` first (GUT resolves global classes only from the importer's cache), then `./scripts/gut-check` |
| `#[func]` exports | `./scripts/check-ffi-surface` — a renamed export fails only at runtime, in whichever pane calls it, often only in a log line |
| IPC method / MCP tool | `cargo test -p gpty-cli` — `mcp.rs` reads the real registrations, the GDScript dispatch arms and every CLI call literal |
| any doc/roadmap edit | `python3 scripts/docs-check` |
| app-visible behavior | `python3 scripts/smoke_pane_api.py`, or `skill://gpty-live-gui-smoke`; UI claims → `skill://gpty-ui-review` |
| anything | `./scripts/ci-check` before committing (full: fmt, workflow lint, docs, clippy, ffi surface, cross-target checks, tests twice, gdext build, import, GUT, live smoke, `cargo audit --deny warnings`) |

A missing toolchain SKIPs locally but FAILS under `CI`/`GITHUB_ACTIONS`, so a local PASS can be weaker than CI. Never `--no-verify`. Do not run the full suite mid-flight, and do not re-run a gate that already passed.

## 6. Close the row

- Flip ⬜ to ✅ **in place**. The text becomes the record: what shipped, measured numbers (not adjectives), the tests by name, the failure mode now closed. A reader must be able to tell whether it is done without opening the commit.
- Corrections fold into that row.
- Screenshots: the row ends "Screenshot (under Screenshots below): *Caption*."; the file and the numbered-box key live in the page's `## Screenshots`; never an image inside a cell.
- A defect found on the way gets **its own row** in priority position, with the evidence that makes it actionable and the fix direction — not a silent fix, not a comment, not folded into this row unless it is genuinely part of this row's contract.
- The changelog is written at release time (`docs/content/docs/changelog/vX.Y.Z.md`); a release's DOCS row carries that work. Do not write it mid-cycle — do record the user-facing summary the row will need.

## 7. Commit, then stop

`skill://commit`; conventional scope; a behavior change and its test land in the same commit; an intentional behavior change gets the reason in the body. Before the reply: every call site migrated, docs updated or a row queued for them, the changed path exercised for real (tests alone are not proof), scratch files gone, `git status` clean of strays.

## Maintenance

- The gate table mirrors `scripts/ci-check`; when a step is renamed or added, the script wins — update the table rather than trusting it.
- The skills are committed at `.omp/skills/<name>/SKILL.md`; OMP's native project provider discovers them at startup, so a clone carries them. Keep that copy authoritative: `~/.omp/agent/managed-skills` is lower precedence, and an edit made there reaches nobody else.
