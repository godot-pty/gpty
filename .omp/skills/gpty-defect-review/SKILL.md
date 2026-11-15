---
name: gpty-defect-review
description: "Run gPTY's periodic defect review: measure the fix-commit classes, find the ones with no mechanical control, and turn that into a check, a guide rule or a roadmap row."
---

# Defect review

The corpus is the evidence: every `fix` commit declares one class from
`docs/content/docs/agents/defect-classes.md`. This procedure turns that into a
control, not a summary.

## When

- At a release cut, before the changelog page.
- When the same class appears twice in one session.
- After a security audit or a fidelity pass, when the findings are defects
  rather than features.

## Measure

```bash
./scripts/fix-forensics --since v<previous>      # the release's declared mix
./scripts/fix-forensics --all --infer            # labelled hypotheses, all history
./scripts/fix-forensics --check --since v<previous>   # must exit 0
./scripts/fix-forensics --hotspots 15            # files fixes return to
./scripts/fix-forensics --no-test                # fixes with no test beside them
```

## Read it

- Declared and inferred are never added together. The inferred block is a
  hypothesis: audit it before quoting a number.
- A hotspot file is a design smell. Read its last three fixes and ask whether
  one rule would have caught all three; if yes, the rule is the control.
- The no-test rate is context, not a target. A fix that needs no test (a
  wording change, a packaging pin) is still a fix.

## Decide

The ladder, best first:

1. A mechanical check that fails the build or the gate.
2. A contract or seam test that reads the real declaration on both sides.
3. One guide bullet in the page that owns the area.
4. One step in the skill that performs the work.
5. A roadmap row, when the control needs design or a measurement first.

A class with a third member and no mechanical control gets option 5 now.

## Record

The row carries the hashes, the measured numbers and the failure mode now
closed - never adjectives. A check ships with a docstring naming the defect it
was born from, an `...-ok: <why>` marker for reviewed exceptions, and a
registration in `scripts/ci-check` so editing it runs it.

## Pitfalls

- A check that fires on legitimate code is worse than none. Use the marker
  convention instead of widening the allow-list until it is silent.
- Do not tune the heuristic into false precision. The regexes rank the reading
  order; the audit produces the number.
- A class that only ever produces `external` members is dependency churn, not
  a defect trend.
