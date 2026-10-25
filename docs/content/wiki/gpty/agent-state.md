# Agent State

Agent state is a pane-level display of what a terminal-hosted agent appears to be doing: idle, working, waiting for you, finished, or failed. It is a badge and a status field, and it never makes anything happen.

## The five states

| State | Meaning |
|---|---|
| `idle` | No agent activity known |
| `working` | A turn is in flight |
| `needs-attention` | The agent finished and wants the user |
| `completed` | The agent finished successfully |
| `failed` | The agent finished with a failure |

## Three tiers, strongest first

A terminal does not have one source of truth about an agent. It may have an extension reporting through a capability, a program declaring its own state, or nothing but text on screen. gPTY merges these with a strict precedence:

| Tier | Source | Strength | Notes |
|---|---|---|---|
| 1 | Capability-authenticated `ompEvent` submissions | Authoritative | Requires the per-PTY event capability injected at spawn; only the pane's own program has it |
| 2 | OSC `gpty_state=<value>` declarations | Declared, spoofable | Whitelisted values, single-shot, at most once per 500 ms per terminal |
| 3 | Conservative failure regexes and decay | Heuristic | Display only; a "failed" observation decays to idle after 60 s |

The merge rule is simple: a stronger tier always wins, a weaker tier is ignored, and within the same tier the newest observation wins. Only Tier 3 decays — a state from an authoritative source persists until that source declares a change, so a completed agent does not quietly turn idle because the screen was quiet.

Tier 2 is deliberately spoofable. Anything that can print can emit an escape sequence, including pasted text and a `cat`-ed log file. That is acceptable because the value only paints a badge: it is whitelisted, rate-limited, ignored while capturing or on the alternate screen, and suppressed for the post-resize window when a TUI repaints. It is never an input to a decision.

Tier 3 exists to catch the obvious signals a terminal can see — `test result: FAILED`, `could not compile`, `assertion failed` — and to get out of the way. A false positive costs a badge flash; a false negative costs nothing, because the real signal is supposed to come from Tier 1.

## Where it shows up

The terminal pane renders a badge from its state, and panes that observe the same terminal receive the same deliveries through a body hook. Programmatically, `paneStatus` reports `agent_state` and `agent_state_tier` alongside liveness and `idle_ms`, which is enough to build a dashboard or an alert without scraping the screen.

Nothing else consumes it. Agent state does not trigger actions, start captures, enable or disable concepts, change layouts, or send IPC. That is a guarantee, not an implementation detail: the tiers exist to answer "what does this look like", and the untrusted tier cannot reach any code path that acts.

## Declaring state from inside a pane

A program can tell the terminal what it is doing:

```bash
gpty state working
gpty state needs-attention
gpty state completed
```

The command declares the state of the pane it runs in, over the event socket, using the credentials the pane injected into its environment. It accepts exactly the five state names. This is not an MCP tool and it does not go through the control socket.

This path matters most on Windows: ConPTY re-renders the terminal, consuming the `gpty_state` OSC before gPTY's parser can see it, so an explicit declaration is the only way a program can set the badge there.

`gpty state` is a declaration with the pane's capability, not a truth claim the app can audit. The capability proves the caller is the program in that pane; it does not prove the claim is honest, and the state still only paints a badge.

## Why exit codes are not used

A pane's exit code describes the process gPTY spawned — usually a shell — not the agent or the command inside it. A foreground command's exit is not reliably attributable in a PTY: the shell keeps running, a wrapper may swallow the status, and a command may finish while a child is still printing. Encoding "the tool finished" from an exit status would produce a state that is confidently wrong, so the model does not try.

## Related

- [[gpty]]
- [[terminal-pane]]
- [[omp-events]]
- [[control-api]]
