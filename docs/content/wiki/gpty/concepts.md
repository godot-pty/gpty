# Concepts

A concept is a saved rule that watches what a terminal prints and, when a pattern appears, hands the output that follows to another pane. It is configuration, not code: a concept captures and routes display content, and does nothing else.

## The mental model

Every concept has three parts:

| Part | What it is |
|---|---|
| Trigger | A regular expression tested against each visible line of terminal output |
| Conditions | Extra regular expressions that must all match the same line; they can only narrow a match |
| Action | The pane type that should receive the captured output |

The classic example is `cat`. Type `cat README.md` in a shell pane, and the `cat_command` concept matches the command line. The output that follows is buffered, and when the capture's stop condition fires the block is routed to the first code viewer pane — which is usually easier to read, scroll, and copy from than the terminal.

A concept can carry several actions, but only the first destination's target is used when matching: a concept routes to one pane kind.

## The two capture modes

`capture_mode` decides what happens after the trigger matches.

| Mode | Behaviour |
|---|---|
| `until_stop` | Buffers the output that follows the trigger and routes the block to a receiver pane. This is the default, and what a missing or unknown mode means. |
| `single_line` | Notify-only. The match is published as an event; nothing is captured, routed, or shown. The output stays in the terminal. |

`single_line` exists for orchestrators that want to know a pattern appeared without stealing the output from the person reading it. Notify-only concepts never see the matched line's text leave the terminal — the published event carries the concept name and source pane, not the content.

`until_stop` needs stop conditions: a timeout in milliseconds (the shipped rules use 300 ms for `cat`, 2,000 ms for `cargo check`) and, optionally, "stop when the user types". How the buffering actually works is the subject of [[capture|Capture]].

## Why a concept cannot execute anything

The trigger runs against terminal output, which is untrusted: any program you run can print text that looks like a command. A concept that could act would therefore be an execution primitive driven by whatever a program happened to print — and it would fire in whichever pane matched, including a root shell or an SSH session. A downloaded `concepts.json` would be arbitrary command execution with an attacker-chosen trigger.

So the feature was reduced to data. An action names a pane type and nothing else. Parsers ignore a legacy `cmd` key rather than rejecting the file, which keeps old definitions loadable without keeping the capability.

## Matching and caps

Each line is first checked against one combined regex set built from every enabled trigger. A line that matches nothing — the common case — stops there and never enters the per-concept loop. When the gate hits, concepts are tried in order, and a capturing concept outranks a notify-only one if both match: otherwise a broad notify-only rule listed first would silently consume every line.

Constraints, enforced when definitions are parsed:

| Limit | Value |
|---|---|
| Concepts | 128 |
| Trigger length | 1,024 bytes |
| Conditions | 8 per concept |
| Actions | 32 per concept |
| Stop timeout | 1–600,000 ms |
| Line length for matching | 16 KiB |

Matching is skipped for alternate-screen output (a full-screen TUI repainting itself is presentation, not shell output) and for 750 ms after a resize, when the child redraws the screen.

## The shipped set

Four concepts ship, merged with the user's file and any installed plugin's concepts:

| Name | Trigger | Enabled | Receives |
|---|---|---|---|
| `cat_command` | `cat <file>` at a prompt | yes | code viewer |
| `git_diff` | `git diff` | no | code viewer |
| `git_log` | `git log` | no | inspector |
| `cargo_check` | `cargo check`, `cargo test`, `cargo build` | no | inspector |

The last two target the Inspector, which is opt-in for captures (`accept_concept_captures`) because captured output would otherwise leave the terminal and be sent to the Inspector's backend. With the opt-in off, those rules have no receiver.

## Where definitions live

Your definitions are `user://concepts.json`. The shipped defaults are read from the app bundle and merged beneath your file; installed plugins contribute concepts between the shipped set and yours. Only enabled concepts are pushed into the engine, and disabling everything pushes an empty set — the engine really stops matching, rather than continuing with the previous list.

## Authoring

Settings has a **Concepts** tab. It shows each concept as a row with an enable toggle, the name and trigger, and buttons to edit or delete it; **Add Concept** opens the same form. The form covers the trigger, target, mode, stop timeout, stop-on-input, and conditions; its timeout field offers 50–5,000 ms, while a hand-edited definition may carry up to 600,000 ms.

**Open Visual Editor** is the primary authoring surface: rules are built as a node graph of trigger → conditions → action. The graph's own block in `concepts.json` holds canvas positions, unfinished drafts, and the order rules are tried in. It never holds content, so the `concepts` array stays the single source of truth, and a hand-edited graph cannot invent a trigger or an action. Plugin-shipped rules appear in the list with their plugin and revision as provenance.

The same control surface exists over the API:

```bash
gpty concept list
gpty concept toggle cat_command
```

`toggle` flips a concept's enabled flag by name. Both are queries against a running GUI; the CLI does not auto-spawn one for them.

## Related

- [[gpty]]
- [[capture]]
- [[concept-recipes]]
- [[settings]]
- [[inspector]]
- [[security-model]]
