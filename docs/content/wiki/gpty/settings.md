# Settings

Settings is the global panel for how gPTY looks and behaves. It has seven tabs — System, Terminal, Appearance, Reasoning, Concepts, Commands, and About — and writes to `user://settings.json`.

## Opening, applying, resetting

Open it from the sidebar's Settings button or the command palette entry `settings`. Changes apply while you make them: the panel debounces edits for a fraction of a second, saves the settings file, and live panes re-read the values, so font size, colors, scrollback length, and FPS limits take effect without restarting.

Each tab ends with its own **Reset tab to defaults** button. The reset is scoped to that tab — resetting Appearance does not touch your shell command, and resetting Terminal does not restore the default colors.

Per-pane settings are a separate popup reached from a sidebar pane row or a pane's titlebar. They are described below; the tabs here are global.

## System

| Setting | Default | Values |
|---|---|---|
| Max FPS | Unlimited (`0`) | 60, 120, 144, 165, 240, Native (`-1`, follows the monitor), Unlimited |
| Window Mode | System Frame | System Frame, Borderless, Fullscreen |
| Check for updates on startup | On | On / Off |

`Native` asks the display server for its refresh rate and caps there; `Unlimited` removes the cap entirely. Window Mode is the same value as the sidebar's window-mode dropdown, and the control's tooltip says what each value draws: `System Frame` keeps the operating system's window frame and its controls and hides gPTY's own titlebar, `Borderless` is a window with no desktop frame that draws gPTY's titlebar, and `Fullscreen` fills the screen and keeps that titlebar. The update check is a startup query only; it installs nothing on its own.

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
| Appearance | Dark | Dark / Light / Follow system - Follow system uses the desktop's own dark-mode preference |
| Font | `DejaVuSansMono.ttf` | Any `.ttf` |
| Font size | 14 px | 8–32 px — the terminal's text, independent of the UI scale |
| UI scale | 100 % | 100 / 110 / 125 / 150 / 175 / 200 %. Scales the whole interface, terminals included: every panel, dialog and control grows together, so a dense display does not need a magnifier. Capped by the window — see below |
| Color scheme | None | Optional `.txt`, `.json`, or `.csv` scheme file |
| Show titlebar | On | Per-pane title bars |

The UI scale is the window's content scale: text and every fixed size scale together, and the layout shrinks by the same factor, so no control is clipped. Font size is separate and only touches the terminal grid — use it when the terminal text should differ from the chrome. At 125 % on a 1920x1080 window the interface behaves like a 1536x864 one.

The applied scale is capped so the layout never falls under 560x340 layout pixels — the smallest layout the chrome is asserted at, and a size at which the Settings card still shows all seven of its tabs. A window that cannot hold the requested scale gets the largest whole percentage it can show, never less than 100 %: the Appearance row then reads `shown at N %`, with the reason in its tooltip, while the picker keeps the request, and growing the window restores the full scale without a restart. The cap only refuses a scale, never the window: an 800x500 window holds 125 % (a 640x400 layout) since the small-window work, where it used to be forced to 100 %. Below the floor — a window near the app's own 500x300 minimum — the chrome adapts instead of clipping: the Settings and Pane Settings cards clamp to the window and scroll their content, the sidebar's sections scroll as one column, and a pane title ellipsizes. See *Small windows adapt instead of clipping*.

The chrome ships a complete dark and a complete light colour set (`godot/scenes/ui/ui_palette.gd`), so **Appearance** decides the whole interface at once: the sidebar, pane title bars, panels, dialogs, toasts and the status bar switch together, and the window's background with them. `Follow system` reads the desktop's dark-mode preference and re-themes live when it changes; a platform or session that cannot answer is treated as dark. Nothing restarts and nothing reopens.

Below those, seven color pickers control the chrome: wrapper background, title-bar background, wrapper border, sidebar background, focus border, selection, and the scrollback indicator. A picker left at the palette's own value follows the mode - switching to Light carries it rather than pinning the dark surface - while a colour you picked stays yours in both modes, and each row's reset button returns it to the active set. Two of the seven are translucent by design (Focus 30 %, Selection 40 %), and a translucent swatch shows the engine's transparency checkerboard: the row's own label names the opacity (`Selection (40%)`) and its tooltip says what the checkerboard is, while a fully transparent colour - one a saved layout or profile carried in - reads `(unset)`; Pane Settings' Cursor colour, Default FG and Default BG rows use the same reading. The scheme file supplies the terminal's own palette; clearing it returns terminals to the built-in palette, which is applied live, and it is independent of the chrome's mode: a light window may well hold a dark terminal.

## Reasoning

| Setting | Default | Range |
|---|---|---|
| Max turns | 16 | 1–64 |
| Max turn bytes | 65,536 | 4,096–1,048,576, step 4,096 |

These bound the Reasoning pane's retained session: how many turns it keeps and how much text one turn may carry before it is cut. Lowering them trims what the pane keeps in memory.

## Concepts

This tab lists the concept rules that are active for the terminal engine, with a button to open the visual graph editor and a button to add a rule. Each row can be enabled or disabled and deleted. Concepts are covered in [[concepts]]; nothing here executes commands — rules capture and route display content.

## Commands

Your own saved commands: a name, one line of shell text, and whether choosing it should also press Enter. They are listed in the command palette's own **Saved commands** section (`Ctrl+Shift+P`), and stored in `user://commands.json` — at most 200 entries, a 64-character name and a 1024-character command, with control characters stripped so an entry is always one line. `Run` is off for a new command, so the first time you use one it is typed at the prompt, unexecuted, for you to read before running it. `Add…`, `Edit…`, `Delete` and `Up`/`Down` manage the list; the order is the palette's order.

Choosing a saved command types it into the **active terminal pane** and nothing else. When the active pane is not a terminal (a code viewer, a note, a wiki page) the palette lists the commands greyed out with the reason as their tooltip, and refuses to send rather than picking another pane. Nothing expands: the text goes to the shell exactly as written, so `$HOME` and `$(…)` are the shell's business, not gPTY's. Saved commands are GUI-local — there is no IPC method, CLI verb or MCP tool for them, a plugin cannot supply them, and they never run at spawn (a pane's startup command is the layout/profile `launch` key, covered in [[layout]]).

## About

Version, the IPC protocol version gPTY speaks, and the repository address. The protocol number is useful when a CLI and a GUI from different builds disagree about the wire format.

Below those, **Keyboard Shortcuts** lists every binding the app knows, grouped as Workspace, New Panes, Panes, Keyboard Focus, and Terminal. Each row is the chord and what it does, and the chords are read from the binding registry rather than typed in, so the list cannot name a key that does nothing. The list is the in-app copy of [[keyboard-shortcuts]]; the palette's `Keyboard Shortcuts` row opens this tab directly.

## Global settings versus per-pane settings

| Scope | Where | What it covers |
|---|---|---|
| Global | Settings panel, `user://settings.json` | Fonts, colors, terminal defaults, shell program, global environment, FPS, window mode |
| Per pane | Pane Settings popup; the Inspector's aim in `user://pane_inspector.json` | Name, attachment id, font size, environment override, type-specific view options, and the Inspector's prompt and switches |
| Workspace | More → Set Directory on the workspace row, `user://workspaces.json` | Default directory inherited by new terminals; changing it asks when the workspace holds a pane that names its own program |
| File-supplied | Layout or profile tile | Pane type, geometry, and a spawn plan (program and arguments) |
| Trust | Workspace Trust dialog, `user://trusted.json` | Approval memory for file-supplied spawn plans |

The Pane Settings popup is type-aware. For a terminal it edits the pane's name, public attachment id, font size, environment lines, cursor shape, blink and blink speed, cursor color, beam width, underline height, grid rows and columns, scroll lines, default foreground and background colors, font file, and color scheme. It does **not** edit the shell program, its arguments, tags, or a working directory — the program and arguments come from the creation call, a layout tile or a profile (and are exactly what Workspace Trust gates), while the directory belongs to the workspace (the workspace row's More → Set Directory). Clearing the environment box removes that pane's override, so it inherits the global environment again.

Per-pane environment and the Inspector's aim are the settings only you can supply. Environment is stored in `user://pane_env.json` and the aim (system prompt, auto-send, capture acceptance) in `user://pane_inspector.json`, both keyed by the pane's attachment id, and only the pane settings UI writes them. A saved layout or profile that carries environment has it stripped on restore with a notice — the file is never allowed to become spawn-time authority — and the Inspector's three keys are refused from files outright, so a restored pane takes its aim from your record, never from the layout. Renaming a pane's attachment id moves both entries to the new key; closing an Inspector removes its aim record, while a restart or a profile re-activation keeps it.

Two related files are not part of settings: `user://trusted.json` holds Workspace Trust approvals, and `user://workspaces.json` and `user://profiles.json` hold the arrangements. See [[workspace-trust]], [[workspace]], and [[profile]].

## Related

[[gpty]] · [[sidebar]] · [[keyboard-shortcuts]] · [[profile]] · [[concepts]] · [[workspace-trust]]
