# Terminal Pane

A terminal pane is a real shell process attached to a pseudo-terminal (PTY), drawn onto the pane's surface one character cell at a time. It is the pane every workspace starts with, and the one to use whenever a program expects a terminal rather than a pipe.

## What it is

The pane is only the screen and the input path. The shell, the PTY, the ANSI parser and the character grid all live in the Rust engine; `godot/scenes/terminal/terminal_pane.gd` is the body that asks the engine for changed cells and paints them in `_draw()`. That split is why the pane can spend its time on selection, search and scrolling while the child process keeps running at full speed.

The grid is what makes a terminal a terminal: a fixed rectangle of cells, each with a character and a colour, rather than a stream of lines. Programs move a cursor around that rectangle with escape sequences, and a full-screen application — a text editor, a pager, an agent TUI — can take it over entirely and restore the previous screen when it exits.

## When to use it

Use a terminal pane for anything interactive: a shell prompt, a build you want to watch, a REPL, `git`, an editor, or an agent CLI such as omp that expects a TTY. It is also the pane that produces the output concepts match and the pane that reports agent state.

If a program only prints a report and never prompts, a [[cli-view|CLI View]] pane is the lighter choice: it runs argv with no PTY, merges the output, and bounds what it keeps.

## How to open it

| Method | Action |
|---|---|
| Shortcut | `Ctrl+Shift+N` |
| Sidebar | The terminal button in the new-pane row |
| Palette | `new terminal` (`Ctrl+Shift+P` opens the palette) |
| CLI | `gpty new-pane -t terminal`, or just `gpty new-pane` |
| MCP | the `new-pane` tool with `type: "terminal"` |
| Layout/profile | every shipped profile contains at least one, and restore recreates them |
| API | `paneRun` opens a *new* terminal pane and runs a command through the configured shell |

Panes are never spawned by other panes. Every route above asks the workspace, which is the only spawner: it attaches the new tile to the grid, gives it a label (`T1`, `T2`, …) and a stable `attachment_id`, and activates it.

## What it shows and how it is driven

The body paints the grid, the cursor (block, underline or beam, with configurable blink speed and colour), the selection highlight, and the scrollback indicator. Keyboard input goes to the child; mouse input is either used for local selection or reported to the child as terminal mouse events when the program has enabled mouse reporting.

Keys the pane recognises itself:

| Key | Effect |
|---|---|
| `Ctrl+Shift+C` | copy the selection |
| `Ctrl+Shift+V` | paste (bracketed paste when the child asked for it; control bytes are stripped either way) |
| `Ctrl+Shift+F` | toggle the scrollback search bar (regular expressions) |
| `PageUp` / `PageDown` | scroll the viewport |
| `Ctrl+V` | deliberately passed through to the child as `^V` |

Pasting treats the clipboard as untrusted input. Both modes drop control characters other than tab and newline - escape sequences included - before anything reaches the child: a clipboard holding `ESC[201~` would otherwise close a bracketed paste early and have the rest arrive as typing, and a pasted `^C` would interrupt. The bracketed mode then wraps the surviving text in `ESC[200~`/`ESC[201~`.

Wheel scrolling moves three lines by default. Output that scrolls past the viewport goes to the pane's scrollback, which is written to SQLite and restored when the pane comes back after a restart; the default depth is 10,000 lines and the global setting clamps it to 100–100,000.

`paneStatus` reports the process and the grid as a document with `pid`, `running`, `exit_code`, `exit_reason`, `idle_ms`, `agent_state` and `agent_state_tier`. The titlebar badge and the status document share one source: the tiered agent-state tracker, where capability-authenticated events outrank OSC declarations, which outrank heuristics. All three are display-only and never trigger an action.

## Settings that matter

Pane Settings for a terminal edits the presentation and the environment, not the spawn plan:

| Setting | What it changes |
|---|---|
| Name, Attachment ID | the title, and the stable id used by per-pane env, tags and companion panes |
| Font size, Font file, Color scheme | rendering |
| Environment | `KEY=value` lines, stored per pane in `user://pane_env.json` |
| Cursor shape, blink, speed, colour, beam width, underline height | rendering |
| Rows / Cols | the grid, 10–100 rows and 40–200 columns in the UI |
| Scroll lines | wheel step, 1–10 |
| Default FG / BG | the fallback colours behind a scheme |

The program and its arguments are not here. `shell_command` and `shell_args` come from a profile or from a saved layout tile. The call that creates a pane can set the program (`gpty new-pane -t terminal -c <program>`); `--arg` values are an argv for a [[cli-view|CLI View]] pane, not for a terminal. A file-supplied program or argv is what Workspace Trust exists for: restoring a tile that would run something other than your defaults asks you to approve the exact program and arguments, and a tile's `shell_env` is stripped on restore because environment belongs to you.

There is also no per-pane working directory. A pane inherits the directory of its workspace, which is the workspace row's folder button, and the workspace wins over any stored key.

## What it does not do

It does not edit files, render Markdown, or browse a directory — those are the [[code-viewer|Code Viewer]] and [[file-tree|File Tree]] panes. It does not mediate your keystrokes beyond its own shortcuts, which is why `Ctrl+V` reaches the child. It does not keep a process alive after the pane is closed: closing stops the pane's work, and the workspace asks first when a foreground job is running (on platforms that can report the foreground process group; a Windows ConPTY shell answers "live" while it lives, because the alternative is ending work silently).

## Limits and edge cases

Scrollback is per pane and is not a log file: the 10,000-line default is the depth, the store keeps it across restarts, and search runs over what was kept. The status document is sampled by a slow child poll, so a command that starts and finishes inside that window can read as idle. Full-screen applications work, including the alternate screen, but leaving the pane does not detach them — the child is a child of the GUI.

## Related

- [[pane]]
- [[terminal-grid]]
- [[scrollback]]
- [[cli-view]]
- [[inspector]]
- [[agent-state]]
