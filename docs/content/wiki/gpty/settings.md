# Settings

Settings is the global panel for how gPTY looks and behaves. It has six tabs — System, Terminal, Appearance, Reasoning, Concepts, and About — and writes to `user://settings.json`.

## Opening, applying, resetting

Open it from the sidebar's Settings button or the command palette entry `settings`. Changes apply while you make them: the panel debounces edits for a fraction of a second, saves the settings file, and live panes re-read the values, so font size, colors, scrollback length, and FPS limits take effect without restarting.

Each tab ends with its own **Reset tab to defaults** button. The reset is scoped to that tab — resetting Appearance does not touch your shell command, and resetting Terminal does not restore the default colors.

Per-pane settings are a separate popup reached from a sidebar pane row or a pane's titlebar. They are described below; the tabs here are global.

## System

| Setting | Default | Values |
|---|---|---|
| Max FPS | Unlimited (`0`) | 60, 120, 144, 165, 240, Native (`-1`, follows the monitor), Unlimited |
| Window Mode | OS | OS, Windowed, Windowless |
| Check for updates on startup | On | On / Off |

`Native` asks the display server for its refresh rate and caps there; `Unlimited` removes the cap entirely. Window Mode is the same value as the sidebar's window-mode dropdown: `OS` keeps the operating system's window frame and hides gPTY's own titlebar, `Windowed` is a borderless window that draws gPTY's titlebar, and `Windowless` is fullscreen with that titlebar. The update check is a startup query only; it installs nothing on its own.

## Terminal

| Setting | Default | Range |
|---|---|---|
| Cursor shape | Block | Block, Underline, Beam |
| Cursor blink | On | On / Off |
| Blink speed | 0.5 s | 0.1–2.0 s, step 0.1 |
| Beam width | 2 px | 1–8 px |
| Underline height | 3 px | 1–8 px |
| Default size | 24 rows × 80 cols | rows 10–100, cols 40–200 |
| Scroll lines | 3 | 1–10 per wheel step |
| History lines | 10,000 | 100–100,000, step 100 |
| Shell | Platform default | Any command line |
| Environment | Empty | `KEY=value`, one per line |

These are the defaults for **new** terminals: a pane that already exists keeps the grid dimensions it was spawned with, though cursor and color changes are applied live. The default size is the initial terminal grid, not the pane's pixel size.

History lines caps how much scrollback each pane writes to the history database, which is also the text `Ctrl+Shift+F` searches. The tab shows an **On disk** readout for the history store; it is a snapshot taken when the panel opens, because the true size depends on how long the retained lines were, not just how many.

The shell field is the program a new terminal runs. On Linux and macOS it defaults to `/bin/bash`; on Windows to `%COMSPEC%`, falling back to `cmd.exe`. The environment box is the global environment for terminals, one `KEY=value` per line; it is separate from per-pane environment.

## Appearance

| Setting | Default | Notes |
|---|---|---|
| Font | `DejaVuSansMono.ttf` | Any `.ttf` |
| Font size | 14 px | 8–32 px |
| Color scheme | None | Optional `.txt`, `.json`, or `.csv` scheme file |
| Show titlebar | On | Per-pane title bars |

Below those, seven color pickers control the chrome: wrapper background, title-bar background, wrapper border, sidebar background, focus border, selection, and the scrollback indicator. The scheme file supplies the terminal's own palette; clearing it returns terminals to the built-in palette, which is applied live.

## Reasoning

| Setting | Default | Range |
|---|---|---|
| Max turns | 16 | 1–64 |
| Max turn bytes | 65,536 | 4,096–1,048,576, step 4,096 |

These bound the Reasoning pane's retained session: how many turns it keeps and how much text one turn may carry before it is cut. Lowering them trims what the pane keeps in memory.

## Concepts

This tab lists the concept rules that are active for the terminal engine, with a button to open the visual graph editor and a button to add a rule. Each row can be enabled or disabled and deleted. Concepts are covered in [[concepts]]; nothing here executes commands — rules capture and route display content.

## About

Version, the IPC protocol version gPTY speaks, and the repository address. The protocol number is useful when a CLI and a GUI from different builds disagree about the wire format.

## Global settings versus per-pane settings

| Scope | Where | What it covers |
|---|---|---|
| Global | Settings panel, `user://settings.json` | Fonts, colors, terminal defaults, shell program, global environment, FPS, window mode |
| Per pane | Pane Settings popup, saved with the tile | Name, attachment id, font size, environment override, and type-specific view options |
| Workspace | Sidebar folder button, `user://workspaces.json` | Default directory inherited by new terminals |
| File-supplied | Layout or profile tile | Pane type, geometry, and a spawn plan (program and arguments) |
| Trust | Workspace Trust dialog, `user://trusted.json` | Approval memory for file-supplied spawn plans |

The Pane Settings popup is type-aware. For a terminal it edits the pane's name, public attachment id, font size, environment lines, cursor shape, blink and blink speed, cursor color, beam width, underline height, grid rows and columns, scroll lines, default foreground and background colors, font file, and color scheme. It does **not** edit the shell program, its arguments, tags, or a working directory — those come from the creation call, a layout tile, or a profile, and a file-supplied program or argument list is exactly what Workspace Trust gates. Clearing the environment box removes that pane's override, so it inherits the global environment again.

Per-pane environment is the one setting only you can supply. It is stored in `user://pane_env.json`, keyed by the pane's attachment id, and only the pane settings UI writes it. A saved layout or profile that carries environment has it stripped on restore with a notice; the file is never allowed to become spawn-time authority. Renaming a pane's attachment id moves its environment entry to the new key.

Two related files are not part of settings: `user://trusted.json` holds Workspace Trust approvals, and `user://workspaces.json` and `user://profiles.json` hold the arrangements. See [[workspace-trust]], [[workspace]], and [[profile]].

## Related

[[gpty]] · [[sidebar]] · [[keyboard-shortcuts]] · [[profile]] · [[concepts]] · [[workspace-trust]]
