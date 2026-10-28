# Reasoning Pane

A reasoning pane is a passive window onto an agent's lifecycle: it shows the reasoning an OMP session reports, turn by turn, without running the agent or reading the terminal's screen.

## What it is

The body is `ReasoningPane` (`godot/scenes/panes/reasoning_pane.gd`); the registered type key is `reasoning` and its label prefix is `R`. It listens to semantic events from one terminal in its own workspace, identified by that terminal's stable `attachment_id` (the default source is `omp-terminal`), and projects them into a scroll of foldable turns. Delivery is workspace-scoped: the dispatcher resolves the emitting PTY by its session id and hands the event only to receivers in that terminal's workspace, so activating the same profile in two workspaces keeps each Reasoning pane on its own terminal.

The important word is *reported*. The pane never starts an agent, never sends it a prompt, and never scrapes the TUI. It only displays events the agent publishes through gPTY's event socket. When nothing publishes, the pane is a status line explaining what to link.

## When to use it

Use it next to a terminal running omp to watch what the agent is doing between tool calls — the reasoning stream, the turn boundaries, whether a session has settled. Use the [[inspector|Inspector Pane]] when you want to ask your own questions privately. Use the terminal itself when you want to interact with the agent.

Both panes are in the shipped **Agent Workspace** profile alongside a terminal, which is the arrangement they were designed for: one terminal as the work surface, one Inspector for side questions, one Reasoning for the running commentary.

## How to open it

| Method | Action |
|---|---|
| Sidebar | the reasoning button |
| Palette | `new reasoning` |
| CLI | `gpty new-pane -t reasoning` |
| MCP | the `new-pane` tool with `type: "reasoning"` |
| Profile | the shipped **Agent Workspace** |

The pane has no keyboard shortcut of its own. It has no chat field: everything it shows arrives from the event stream, so `new reasoning` followed by linking the extension is the whole setup.

## Setting it up

The pane needs two things a fresh install does not have by default: the bundled OMP extension and the event socket it forwards to. The pane's idle status spells out the steps:

```bash
omp plugin link <gpty>/extensions/gpty-omp-events
```

Then restart omp in the terminal it should observe. Inside that terminal, `echo $GPTY_EVENT_PROTOCOL` should print `1` — the variable is set per PTY when the shell spawns, along with the event socket path and a per-terminal capability that gates who may publish.

The event listener is a second socket beside the control socket: `gpty-events.sock` on Unix and `\\.\pipe\gpty-events` on Windows. The implementation is platform-neutral, and the extension and listener are exercised on Windows by the project's smoke job, so the pane is not Unix-only.

## What it shows and how it is driven

A status line sits above a scrolling list of turns. Each turn is a fold you can collapse, titled `Turn N · <state>`, with the reasoning rendered as Markdown through the shared sanitized view.

The event vocabulary it consumes is small and semantic:

| Event | Effect on the pane |
|---|---|
| `session.bound` | binds the pane to an OMP session id |
| `agent.started` | starts a new turn and sets the status to `Reasoning…` |
| `thinking.delta` | appends reasoning text to the live turn |
| `agent.settled` | closes the turn; status becomes `Done` or `No reasoning emitted` |
| `session.shutdown` | freezes the live turn and marks the session ended |

The view follows the bottom while you are at the bottom, and stops following when you scroll up to read an earlier turn; scrolling back down re-arms it. This is a display state, not a mode you toggle.

A turn record is the pane's own source of truth: it holds the turn index, the status, and the accumulated text up to the configured cap. Records live in RAM for the current OMP session; the pane does not write a transcript.

## Settings that matter

| Setting | What it changes |
|---|---|
| Source attachment ID | which terminal's events this pane shows; it must match that terminal's Attachment ID, not its display name |
| Settings → Reasoning → max turns | how many turns are kept; default 16, clamped 1–64 per pane |
| Settings → Reasoning → bytes per turn | how much reasoning one turn retains; default 65,536 bytes, clamped 4,096–1,048,576 |

The two global caps are read when a pane is created, so a change applies to panes opened afterward. Changing the source attachment id clears the pane's turns and rebinds: the events of a different terminal are a different conversation. Renaming the *terminal* in Pane Settings is not that — the link follows the new id and the pane keeps its turns, and only companions in the renamed terminal's own workspace move: a pane in another workspace keeps the id you typed.

## What it does not do

It does not run an agent, send prompts, or accept input. It does not parse terminal output — if the extension is missing, the pane stays empty and says so rather than guessing from the screen. It does not receive routed concept captures; its body declines content. It does not persist turns, so closing the pane or restarting gPTY starts a fresh view of the next session.

## Limits and edge cases

The pane displays one source terminal at a time. Events from another terminal are ignored. A new OMP session rebinds the pane, and the session's `session.shutdown` marks the view as ended rather than silently freezing. The turn and byte caps bound memory, and the oldest turns are dropped first. If the view looks slow rather than empty, `GPTY_REASONING_DEBUG=1` prints a once-per-second line with the input rate, render rate and the event server's drop counters — enough to tell a slow model from a stalled GUI.

## Related

- [[pane]]
- [[omp-events]]
- [[agent-state]]
- [[inspector]]
- [[plugins]]
