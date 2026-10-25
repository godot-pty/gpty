# Inspector Pane

An Inspector pane is a private, read-only question-and-answer session: you ask, a model answers, and the exchange stays in that pane. It is not the agent running in your terminal, and it does not follow that conversation.

## What it is

The body is `InspectorPane` (`godot/scenes/panes/inspector_pane.gd`); the registered type key is `inspector` and its label prefix is `I`. It owns exactly one in-memory session through the `gpty-ai` crate, which speaks to a backend and hands envelopes back to GDScript for display.

The point is the fence around it. The session is opened tool-free, so an answer cannot run a command, edit a file, or reach the workspace through a tool. It is also private: it is a different process with its own prompt history from the omp session in a terminal pane, even when both use the same model. The default `omp` backend is launched as `omp --mode rpc --no-session --no-tools --no-extensions --no-skills --no-rules`, which is the flag set that makes "no tools, no workspace rules, no stored session" true rather than aspirational.

## When to use it

Use it to ask about something you are looking at without derailing the terminal agent: paste an error, ask what a flag does, get a short explanation. Because it is read-only and tool-free, it is also the safe place to ask about untrusted text — the answer can describe a suspicious file but cannot act on it.

Use the [[reasoning|Reasoning Pane]] if you want to *watch* what the terminal agent is thinking. Use the terminal if you want an agent that can actually do work.

## How to open it

| Method | Action |
|---|---|
| Shortcut | `Ctrl+Shift+O` |
| Sidebar | the inspector button |
| Palette | `new inspector` |
| CLI | `gpty new-pane -t inspector` |
| MCP | the `new-pane` tool with `type: "inspector"` |
| Profile | the shipped **Agent Workspace** includes one |

Saved layouts that predate the split of the old observer pane are migrated: an `observer` tile with the answer stream becomes an inspector tile. A pane opened through the CLI or API starts with the default backend; everything else is pane settings.

## What it shows and how it is driven

The pane is a single column: a status line, an optional thinking area, the answer, and a prompt field. Type a question and press Enter.

While a turn runs, the status reads `Inspecting via <backend>…`. Reasoning text, when the backend emits it, streams into a separate area above the answer so the two do not interleave; the answer itself renders as Markdown through the shared sanitized view. Cancelling a turn stops it; closing the pane ends the session.

Backends:

| Backend | What runs |
|---|---|
| `omp` | one long-lived, tool-free omp RPC process per session — the default |
| `cli` | a subprocess NDJSON bridge: your adapter command is started per prompt, argv only, never through a shell |
| `mock` | a deterministic local pass-through, used by tests and offline work |

The CLI bridge contract is one JSON request line in for a prompt and JSON event lines out (`thinking`, `delta`, `done`, `error`, `status`). Adapters translate a tool's documented hooks; nothing scrapes a TUI and nothing counts tokens.

A capture routed from a terminal concept can reach the pane only when you enable **Accept terminal concept captures**. That gate is off by default and is the whole security story of the feature: a capture is terminal output, and delivering it means that text leaves the pane and goes to a model. With the gate on, captures queue in the pane; **Auto-run** (on by default) decides whether a capture starts a turn immediately, and **Run on last capture** replays the most recent one by hand.

## Settings that matter

| Setting | What it changes |
|---|---|
| Name, Attachment ID | title and stable id |
| Font size | 8–32 px |
| Backend | `omp`, `cli`, `mock` |
| Model | optional model passed to the backend |
| Command | the `cli` backend's adapter argv (whitespace-split, no shell) |
| Auto-run | whether a capture starts a turn immediately |
| Accept terminal concept captures | the opt-in gate for routed output |
| System prompt | replaces the default inspector prompt |

Changing the backend, model, system prompt or CLI command closes the session, so the next prompt opens one under the new configuration.

## What it does not do

It does not attach to the OMP conversation hosted in a terminal, and it does not read terminal output on its own — a terminal session can be busy for an hour and this pane will not show a word of it. It does not use tools, skills, extensions or workspace rules, and it does not write anything to disk. Its session is in-memory: closing the pane ends it, and there is no transcript to reopen.

## Limits and edge cases

One session per pane, so a second Inspector is a second conversation with its own history. The `omp` backend needs `omp` on `PATH`; a stale extension build reports that the bridge is missing and asks for a rebuild rather than failing silently. The thinking area is not a log — it is the current turn's reasoning. Captures are gated per pane, so enabling the opt-in on one Inspector does not enable it on another. Because captures leave the pane, treat that toggle as a data-sharing decision, not a display preference.

## Related

- [[pane]]
- [[concepts]]
- [[capture]]
- [[agent-state]]
- [[history]]
- [[reasoning]]
