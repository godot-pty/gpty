---
name: local-model-code-review
description: "Run multi-pass local-model code reviews over a large repo, verify every finding against the code, and file only what survives."
---

# Local-model multi-pass code review

Use when the user wants free/offline review passes over a codebase and can accept a low signal-to-noise ratio that a strong model verifies.

## Model quirks (measured, Ollama 0.40)
- `gemma4:128k` (131K ctx): honours `"think": false` — content is clean JSON, ~450 tokens/answer, 3-15 s per slice. **Use as the workhorse.**
- `gpt-oss:48k`: **ignores** `think:false` and `reasoning_effort` — every token lands in `message.thinking`, `content` is empty (`done_reason=length`). Unusable through `/api/chat` unless the budget is huge; OMP's harmony dialect is the working path.
- `qwen2.5-coder:14b-instruct-q4_K_M` (32K ctx): no flag needed, valid JSON, but broad "God object" judgements; keep slices under ~20K tokens.
- Always pass `"stream": false`; omit `think` for non-reasoning models.

## Recipe
1. **Slice by module, cap ~100 KB** (≈30K tokens) so the 49K window keeps room for output. Split big files by line range. Compute `bytes/1024` per slice and print the plan.
2. **Three lenses, rotated temperatures** (0.15/0.6/0.9):
   - design: God objects, duplicated logic, leaky abstractions, hidden coupling, misnamed ownership.
   - tests: missing behaviour, happy-path-only boundaries, tautological tests, untestable seams.
   - robust: unwrap on external input, unbounded growth, locks across blocking calls, dropped Results, uncapped retries.
3. **Strict output schema**: one JSON object `{"findings":[{title,file,symbol,evidence,change,severity,confidence}]}`, max 8, "no findings is valid", "never invent a file". Parse leniently: first `{` to last `}`; retry once at temperature 0 with "at most 3 findings, JSON only" and a smaller `num_predict`.
4. **Include a test inventory in the prompt** for the tests lens (test files, counts, which mention the slice) — without it the model asserts "zero coverage" from nothing.
5. **Verify mechanically, then by hand**:
   - file resolves (name → path map), symbol appears in it, ≥1 backticked identifier from the evidence appears in the file;
   - for each survivor, read the cited code and look for the guard the model missed (caps, `size()` checks, `retain` on timeout, pre-allocation checks, existing tests referenced by API not by class name).
6. **Dedupe against the roadmap** (grep symbols/titles) before proposing rows.

## Yield to expect
On a hardened codebase, ~195 findings → 165 distinct → ~77 mechanically grounded → **1 new actionable defect**. Most high-severity claims die on existing guards. Budget verification at ~2-4 min per surviving claim.

## Failure modes seen
- Claiming "no tests" because the test drives the feature through another API (grep class name misses it).
- Claiming an allocation happens before the cap check when the source checks first.
- Claiming a division by zero where an `n == 0` guard exists several lines above.
- Proposing splits (drag machine into state + commit) that are one cohesive responsibility — reject without measurement.
