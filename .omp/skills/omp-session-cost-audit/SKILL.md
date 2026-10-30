---
name: omp-session-cost-audit
description: "Measure and compare omp/GPTY session API cost from session JSONL (main, __advisor, subagents), verify cost-knob changes"
---

# Audit omp session API cost from session records

Use when asked why a session (or a month) cost what it did, to compare sessions before/after a change, or to verify a cost knob (`advisor.reviewInterval`, statusLine, rules) took effect.

## Where the data is

- Main transcript: `~/.omp/agent/sessions/<project>/<session-id>.jsonl`. Every assistant message carries `usage` (input, output, cacheRead, cacheWrite, cost.*) and `contextSnapshot`.
- Artifacts dir: **sibling** of the session file — same name with `.jsonl` stripped: `~/.omp/agent/sessions/<project>/<session-id>/`. Holds `__advisor.jsonl` (advisor turns; named advisors use `__advisor.<slug>.jsonl`) and `<AgentName>.jsonl` per subagent. Treating the parent dir as the artifacts dir silently reports *other* sessions' numbers — the classic bug.
- Advisors are the usual cost centre: `reviewMode: turn` (default) reviews every tool-call round, so advisor requests ≈ primary requests unless `advisor.reviewInterval` (or a `WATCHDOG.yml` roster entry) spaces them out.
- Tariff: `~/.omp/agent/models.db` → `model_cache` holds rates and the peak schedule (`offPeakMultiplier`; DeepSeek peak = weekdays 01:00–04:00 and 06:00–10:00 UTC). Detect peak per request by `usage.cost.input / usage.input > 0.22e-6` rather than by clock.
- Settings registry: `omp config list` prints every registered key with its current value and type — the way to prove an edit was recognized. `omp config get <key>` only works for registered keys (a bare `advisor` is "Unknown setting").
- Segments: `omp gallery --surface=segment --segment cost --plain` renders a single status-line segment without a TUI; the segment vocabulary includes `cost`, `token_total`, `context_pct`, `session_name`, `cache_read`, `cache_hit`.

## Script (copy, adapt the glob for other projects)

```bash
python3 - <<'PY'
import json, os, glob
root = os.path.expanduser("~/.omp/agent/sessions")
cands = [f for f in glob.glob(root + "/*/*.jsonl") if not os.path.basename(f).startswith("__")]
main = max(cands, key=os.path.getmtime)                      # newest; or pass an explicit path
art = os.path.join(os.path.dirname(main), os.path.basename(main)[:-6])   # SIBLING dir
def scan(p):
    r = dict(req=0, cost=0.0, inp=0, cr=0, out=0, calls=0, peak=0, priced=0)
    for line in open(p, errors="replace"):
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except Exception: continue
        if o.get("type") != "message" or o["message"].get("role") != "assistant": continue
        m = o["message"]; u = m.get("usage") or {}; c = u.get("cost") or {}
        r["req"] += 1; r["cost"] += c.get("total", 0)
        r["inp"] += u.get("input", 0); r["cr"] += u.get("cacheRead", 0); r["out"] += u.get("output", 0)
        r["calls"] += sum(1 for x in (m.get("content") or []) if x.get("type") == "toolCall")
        if u.get("input"):
            r["priced"] += 1
            if c.get("input", 0)/u["input"] > 0.22e-6: r["peak"] += 1
    return r
m = scan(main); a = scan(os.path.join(art, "__advisor.jsonl")) if os.path.exists(os.path.join(art, "__advisor.jsonl")) else None
subs = [scan(f) for f in glob.glob(art + "/*.jsonl") if not os.path.basename(f).startswith("__")]
print(os.path.basename(main))
print(f"  main reqs={m['req']} calls/req={m['calls']/max(m['req'],1):.2f} meanPrompt={(m['inp']+m['cr'])/max(m['req'],1):,.0f} "
      f"out={m['out']:,} peak={m['peak']/max(m['priced'],1)*100:.0f}% ${m['cost']:.3f}")
if a: print(f"  advisor reqs={a['req']} ratio={a['req']/max(m['req'],1):.2f} ${a['cost']:.3f}")
if subs: print(f"  subs files={len(subs)} reqs={sum(s['req'] for s in subs)} ${sum(s['cost'] for s in subs):.3f}")
print(f"  TOTAL ${m['cost'] + (a['cost'] if a else 0) + sum(s['cost'] for s in subs):.3f}")
PY
```

Read-only. Run it before and after a knob change; a verified knob change shows up as advisor `ratio` (goal ≤0.15 with `reviewInterval: 10`) and `calls/req` (goal ≥2 with batching rules).

## Reading the numbers

- `calls/req` near 1 means one tool call per model round-trip — the strongest lever on total spend, because every extra round-trip re-sends the whole transcript. Batched requests with 2–4 calls pay the prompt once.
- `peak` share: off-peak requests cost half. A 62% peak share is a scheduling fact, not a bug.
- `meanPrompt` × requests is the context cost. Context files (AGENTS.md) are cached; oversized *tool results* (raw subagent dumps, `proc://` output, re-reads of context files) are what move fresh input.
- Advisors bill as separate usage in their own file — never compare a session's main-model cost to the balance movement without adding `__advisor.jsonl`.

## Verifying config edits

1. `python3 -c "import yaml,os;print(yaml.safe_load(open(os.path.expanduser('~/.omp/agent/config.yml'))))"` — parses.
2. `omp config list | grep -E 'advisor|statusLine'` — the registry echoes the value; an unregistered key would be absent.
3. Rules files (`~/.omp/agent/RULES.md`, user-level, sticky on every request): prove pickup behaviorally — `cd /tmp && omp -p --thinking off --cwd /tmp "No tools. Quote the first bullet of your cost-discipline rules verbatim."` and check the quoted text. Rules are read at session start and on `/clear`/`/new`.
4. A TUI footer needs an interactive restart; `omp gallery --segment cost` only proves the renderer, and `script -qc 'timeout 14 omp --cwd /tmp' /dev/null` captures the composed footer when a real terminal is unavailable.
