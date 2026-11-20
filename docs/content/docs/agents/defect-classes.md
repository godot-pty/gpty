---
title: "Defect classes"
weight: 15
---

A class is a mechanism that produced more than one defect, not a component and
not a symptom. The class decides the control, and the control decides whether
the next instance is caught by a gate or by somebody remembering a sentence.

## The classes

`scripts/fix-forensics --classes-md` prints this table, the report counts
against the same ids, and `githooks/commit-msg` accepts only these values in a
`fix` commit's `Cause:` trailer.

| Class | Definition | A known instance |
|---|---|---|
| `one-fact-two-copies` | One fact (a cap, a vocabulary, a table, a unit) declared in two places that can drift. | `54ad857` |
| `missed-call-site` | A rule applied on some paths and not their siblings (a gate, a focus hand-off, a settings apply, a validation). | `5ffcdb6` |
| `silent-failure` | A failure or an absence that reaches neither the user nor a gate. | `6c8fbc6` |
| `unbounded` | A queue, buffer, result set or allocation with no cap. | `510e4b9` |
| `stale-state` | A cache, counter or flag not invalidated when its subject changed. | `2713d0f` |
| `race` | Code that assumes an ordering or an instant the platform does not guarantee. | `c8aa720` |
| `lifecycle` | Something created but never released, finalized or reaped. | `776717c` |
| `input-ownership` | Focus, keyboard, pointer or paint order left to a default the surface does not want. | `c7699bc` |
| `untrusted-input` | File-, env- or socket-supplied data reaching a dangerous operation unvalidated. | `1f3fca0` |
| `gate-lies` | A test, harness or CI step that passes without asserting what it claims. | `de34431` |
| `doc-drift` | Prose or a comment that contradicts the code. | `af0cad8` |
| `platform-parity` | Behaviour or packaging that holds on one platform and not another. | `9388205` |
| `wrong-constant` | A protocol, geometry or format constant or arithmetic that is wrong. | `f3443a3` |
| `external` | A dependency advisory, upstream API change or retired runner - not our defect. | `a3d6749` |

## What catches each class today

Six classes have a mechanical control. Seven have only prose, and one has a
review tool that is not a gate. That distribution is the point of this page: a
class in the right-hand column is caught by whoever remembers the earlier fix.

| Class | Mechanical control | Still prose |
|---|---|---|
| `one-fact-two-copies` | `scripts/check-ffi-surface`; the seam tests in `crates/gpty-cli/src/commands/mcp.rs` and `crates/gpty-cli/src/commands/wire.rs`; the markdown-cap test in `crates/gpty-gdext/src/markdown.rs`; `scripts/check-capabilities`; `the_grid_caps_are_declared_once` in `crates/gpty-gdext/src/lib.rs` | |
| `unbounded` | the escape-string bound test in `crates/gpty-core/tests/escape_string_bound.rs`; the `MAX_REQUEST_LEN` frame cap in `crates/gpty-ipc/src/server.rs`; `a_child_that_stops_reading_refuses_input_instead_of_growing_the_queue` in `crates/gpty-core/src/engine.rs` | |
| `gate-lies` | `scripts/ci-check`'s fail-closed SKIP, `scripts/gut-check`'s output gate, and `scripts/check-test-guards` for an index on a call's result | |
| `doc-drift` | `scripts/docs-check` | |
| `platform-parity` | the `windows-smoke` and `rust-windows` jobs in `.github/workflows/ci.yml`; the BSD cross-check in `scripts/ci-check` | |
| `input-ownership` | `scripts/ui-capture --audit-focus`; `KeyboardFocus.declare_mouse_only` in `godot/scenes/ui/keyboard_focus.gd` | |
| `untrusted-input` | | review tool only: `scripts/audit-probes.py` |
| `missed-call-site` | | [pitfalls.md](pitfalls.md#missed-call-site) |
| `silent-failure` | | [pitfalls.md](pitfalls.md#silent-failure), `docs/content/docs/agents/testing.md` |
| `stale-state` | | [pitfalls.md](pitfalls.md#stale-state) |
| `race` | | [pitfalls.md](pitfalls.md#race), `docs/content/docs/agents/testing.md` |
| `lifecycle` | | [pitfalls.md](pitfalls.md#lifecycle) |
| `wrong-constant` | | [pitfalls.md](pitfalls.md#wrong-constant) |
| `external` | | not a code defect: `cargo audit` or a red build is the signal |

## Review loop

- At each release cut, `./scripts/fix-forensics --check --since <previous tag>`
  must exit 0, and the class mix goes into the release's chain-page section as
  one line beside the closed rows.
- A class with a third member and no mechanical control gets a roadmap row for
  one: `PROJECT` for a repository-wide check, `CORE` or `BUILD` otherwise.
- A class whose share rises across two releases means the rule that owns it is
  not landing. Rewrite that bullet or skill step, **or** add the check - never
  add a fourth prose bullet.
- An inferred count is a hypothesis. It becomes a number only after the audit
  described in `scripts/fix-forensics`'s docstring, and the report labels it.
- A new check has the house shape: a docstring naming the defect it was born
  from, an `...-ok: <why>` marker for reviewed exceptions, and a registration
  in `scripts/ci-check` so editing it runs it.

## The corpus

Measured 2026-11-15:

```bash
git log --all --format='%s' | grep -cE '^fix'   # 402
git log --all --oneline | wc -l                 # 1440
./scripts/fix-forensics --all                   # 401 of 1255 on main (32.0%)
```

The difference is branches: `git log --all` sees the whole repository, while
the report walks the current branch's history. Use `--all` for context and the
release range for a gate. `git log --grep='^fix'` over-counts (409) because `^`
anchors every line of a message and seven bodies begin a line with "fix"; the
script filters the subject instead.

At the same measurement, 261 of 401 fixes (65%) touched no test path, and the
files fixes return to were `godot/scenes/terminal/workspace.gd` (78),
`godot/scenes/terminal/terminal_pane.gd` (43), `crates/gpty-gdext/src/lib.rs`
(32) and `crates/gpty-core/src/engine.rs` (21). A hotspot is a design smell, not
a target: read its last three fixes and ask whether one rule would have caught
all three.
