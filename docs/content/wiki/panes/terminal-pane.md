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
| `Ctrl+Shift+F` | toggle the scrollback search strip at the pane's top edge (regular expressions); Enter steps to the next match, Shift+Enter to the previous one; in the History scope Up/Down walk the result rows and Enter copies the cursor's line |
| `PageUp` / `PageDown` | scroll the viewport |
| `Ctrl+V` | deliberately passed through to the child as `^V` |

Pasting treats the clipboard as untrusted input. Both modes drop control characters other than tab and newline - escape sequences included - before anything reaches the child: a clipboard holding `ESC[201~` would otherwise close a bracketed paste early and have the rest arrive as typing, and a pasted `^C` would interrupt. The bracketed mode then wraps the surviving text in `ESC[200~`/`ESC[201~`.

Wheel scrolling moves three lines by default. Output that scrolls past the viewport goes to the pane's scrollback, which is written to SQLite and restored when the pane comes back after a restart; the default depth is 10,000 lines and the global setting clamps it to 100–100,000. Two chevrons on the pane's right edge are drawn exactly while their end has content to reach: the bottom one while the view is scrolled back (it returns to live output), the top one while any in-memory scrollback sits above the view (it jumps to the oldest line the grid holds — the newest 10,000 lines, restored included; older rows stay in the saved history and are reached through the search strip's History scope). Neither is drawn on a fresh pane with no scrollback.

`paneStatus` reports the process and the grid as a document with `pid`, `running`, `exit_code`, `exit_reason`, `idle_ms`, `foreground_job`, `child_alive`, `agent_state` and `agent_state_tier`. The titlebar badge and the status document share one source: the tiered agent-state tracker, where capability-authenticated events outrank OSC declarations, which outrank heuristics. All three are display-only and never trigger an action.

## Settings that matter

Pane Settings for a terminal edits the presentation, the environment and the next spawn's launch line:

| Setting | What it changes |
|---|---|
| Name, Attachment ID | the title, and the stable id used by per-pane env, tags and companion panes |
| Launch command | a shell line run through your configured shell at this pane's next start (`-c`, or `/c` on `cmd.exe`); empty inherits the pane's program |
| Directory | this pane's own working directory for its next start; empty inherits the workspace's (`user://pane_cwd.json`) |
| Font size, Font file, Color scheme | rendering |
| Environment | `KEY=value` lines, stored per pane in `user://pane_env.json` |
| Cursor shape, blink, speed, colour, beam width, underline height | rendering |
| Scroll lines | wheel step, 1–10 |
| Default FG / BG | the fallback colours behind a scheme |

There is no Rows / Cols control: the grid is the size the pane's pixels can show. A pane starts its child on its first layout pass, at that fitted size (one size, never a 80×24 guess followed by a resize), and a later resize reflows it through the 50 ms debounce. A tile too small to hold the minimum grid starts its child at the `rows`/`cols` a saved tile carries; those values are a layout-data fallback, not a setting.

Launch command and Directory are the two spawn-plan fields here. The launch line is a line rather than a program: it runs through your configured shell at the pane's next start, so `omp update && exec omp` is one entry. It does not touch the child already running — a launch line is the plan for the next spawn, and replacing a live terminal's program would discard its scrollback. Empty means "inherit the pane's program": the `shell_command` and `shell_args` a profile or a saved tile supplies, or your configured shell when the tile names nothing. The Save Profile dialog writes the same field, and a saved tile carries the line alone (the argv is derived at spawn), which is what keeps a profile portable across shells and platforms.

Directory is the pane's own exception to the workspace's one directory: a profile activated into two repositories can point the pane that belongs to the second one at it, while every other pane in that workspace keeps the workspace setting. The resolution is the pane's own directory, then the workspace's, then gPTY's own; a stored path that no longer exists warns once and falls back a layer. Use **Use workspace directory** to clear it. Like the launch line it applies to the next start, and it is yours alone: it lives in `user://pane_cwd.json`, keyed by the workspace and the pane's attachment id, and no profile, layout, plugin or IPC call can supply it.

A program and its arguments can still come from a profile or a saved layout tile. The call that creates a pane can set the program (`gpty new-pane -t terminal -c <program>`); `--arg` values are an argv for a [[cli-view|CLI View]] pane, not for a terminal. A file-supplied launch line, program or argv is what Workspace Trust exists for: restoring a tile that would run something other than your defaults asks you to approve the exact line or program, and a tile's `shell_env` is stripped on restore because environment belongs to you.

There is also no per-pane working directory. A pane inherits the directory of its workspace, which is the workspace row's **More → Set Directory**, and the workspace wins over any stored key.

## What it does not do

It does not edit files, render Markdown, or browse a directory — those are the [[code-viewer|Code Viewer]] and [[file-tree|File Tree]] panes. It does not mediate your keystrokes beyond its own shortcuts, which is why `Ctrl+V` reaches the child. It does not keep a process alive after the pane is closed: closing stops the pane's work, and the workspace asks first when a foreground job is running (on platforms that can report the foreground process group; a Windows ConPTY shell answers "live" while it lives, because the alternative is ending work silently). It asks for a surviving child too: a program that closes its PTY and keeps running outlives the terminal task, so nothing samples a foreground job for that pane any more, and the status document's `child_alive` is what tells the close path a process is still there.

## Limits and edge cases

Scrollback is per pane and is not a log file: the 10,000-line default is the depth, the store keeps it across restarts, and search runs over what was kept. The status document is sampled by a slow child poll, so a command that starts and finishes inside that window can read as idle. Full-screen applications work, including the alternate screen, but leaving the pane does not detach them — the child is a child of the GUI.

## Related

- [[pane]]
- [[terminal-grid]]
- [[scrollback]]
- [[cli-view]]
- [[inspector]]
- [[agent-state]]
