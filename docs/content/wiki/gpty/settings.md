# Settings

Settings is the global panel for how gPTY looks and behaves. It has eight tabs — System, Terminal, Appearance, Reasoning, Concepts, Commands, Shortcuts, and About — and writes to `user://settings.json`.

## Opening, applying, resetting

Open it from the sidebar's Settings button or the command palette entry `settings`. Changes apply while you make them: the panel debounces edits for a fraction of a second, saves the settings file, and live panes re-read the values, so font size, colors, scrollback length, and FPS limits take effect without restarting.

Each tab ends with its own **Reset tab to defaults** button. The reset is scoped to that tab — resetting Appearance does not touch your shell command, and resetting Terminal does not restore the default colors.

Per-pane settings are a separate popup reached from a sidebar pane row or a pane's titlebar. They are described below; the tabs here are global.

## System

| Setting | Default | Values |
|---|---|---|
| Max FPS | Unlimited (`0`) | 60, 120, 144, 165, 240, Native (`-1`, follows the window's current monitor), Unlimited |
| Window Mode | System Frame | System Frame, Borderless, Fullscreen |
| Window opacity | 100 % | 100, 95, 90, 85, 80, 75, 70, 60, 50, 40 % |
| Check for updates on startup | On | On / Off |

`Native` asks the display server for the window's current screen's refresh rate and caps there; on a multi-monitor setup that is the screen the window is on, not the primary one. `Unlimited` removes the cap entirely. Window Mode is the same value as the sidebar's window-mode dropdown, and the control's tooltip says what each value draws: `System Frame` keeps the operating system's window frame and its controls and hides gPTY's own titlebar, `Borderless` is a window with no desktop frame that draws gPTY's titlebar, and `Fullscreen` fills the screen and keeps that titlebar.

**Window opacity** draws the whole window at the chosen alpha. The row is always shown; where the display server cannot make the window transparent — the X11 driver on a Wayland desktop is the common case — the picker is disabled and says `unavailable on the <server> display server` beside it, with the Wayland way out in its tooltip. The app fades as one surface — the terminal, the chrome, the empty workspace and the overlays all take the same alpha — while engine dialogs, file pickers and popup menus are separate surfaces and stay opaque.

The update check is a startup query only; it installs nothing on its own.

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
| Terminal padding | 4 px | 0–24 px per side — the space between a pane's edge and its grid |
| UI scale | 100 % | 100 / 110 / 125 / 150 / 175 / 200 %. Scales the whole interface, terminals included: every panel, dialog and control grows together, so a dense display does not need a magnifier. Capped by the window — see below |
| Color scheme | None | Two slots, dark and light; each lists the shipped and imported schemes, and the first item is the reset (built-in palette / same as dark) |
| Terminal backdrop | Flat | Flat / Gradient — Gradient shifts the top stop of the scheme background 6 % toward white (dark ground) or black (light ground) and keeps the exact background at the bottom; an ambient effect paints its own ground instead |
| Show titlebar | On | Per-pane title bars |

The UI scale is the window's content scale: text and every fixed size scale together, and the layout shrinks by the same factor, so no control is clipped. Font size is separate and only touches the terminal grid — use it when the terminal text should differ from the chrome. At 125 % on a 1920x1080 window the interface behaves like a 1536x864 one.

Terminal padding is the distance from a pane's edge to its text grid, on all four sides. It is spent on the fit, not painted as a nudge: the grid loses twice the padding before the cell count is divided, so the terminal's rows and columns are exactly what the pane shows, and every open terminal reflows when the value changes. A font-size change reflows the same way.

The applied scale is capped so the layout never falls under 560x340 layout pixels — the smallest layout the chrome is asserted at, and a size at which the Settings card still opens and scrolls its content (at that width the card clamps to 544 px and the eight-tab bar keeps all eight tabs on one row — the bar is 512 px and the tabs need 497). A window that cannot hold the requested scale gets the largest whole percentage it can show, never less than 100 %: the Appearance row then reads `shown at N %`, with the reason in its tooltip, while the picker keeps the request, and growing the window restores the full scale without a restart. The cap only refuses a scale, never the window: an 800x500 window holds 125 % (a 640x400 layout) since the small-window work, where it used to be forced to 100 %. Below the floor — a window near the app's own 500x300 minimum — the chrome adapts instead of clipping: the Settings and Pane Settings cards clamp to the window and scroll their content, the sidebar's sections scroll as one column, and a pane title ellipsizes. See *Small windows adapt instead of clipping*.

The chrome ships a complete dark and a complete light colour set (`godot/scenes/ui/ui_palette.gd`), so **Appearance** decides the whole interface at once: the sidebar, pane title bars, panels, dialogs, toasts and the status bar switch together, and the window's background with them. `Follow system` reads the desktop's dark-mode preference and re-themes live when it changes; a platform or session that cannot answer is treated as dark. Nothing restarts and nothing reopens.

Floating cards share one elevation rule in both modes: the command palette, the Settings and Pane Settings cards, the concept graph, toasts and dialogs carry a soft contact shadow down-right plus a 1 px light top edge, so a card reads as above the page rather than drawn on it.

**Terminal backdrop** is the grid's ground. `Flat` paints the scheme's background exactly. `Gradient` keeps that colour at the bottom and moves the top stop 6 % toward white on a dark ground or black on a light one, so the ground falls off without touching a cell: text, the selection, inverse cells and every non-default background still paint their own exact colours. While an ambient effect is on, it owns the ground and the gradient is not drawn.

Below those, seven color pickers control the chrome: wrapper background, title-bar background, wrapper border, sidebar background, focus border, selection, and the scrollback indicator. A picker left at the palette's own value follows the mode - switching to Light carries it rather than pinning the dark surface - while a colour you picked stays yours in both modes, and each row's reset button returns it to the active set. Two of the seven are translucent by design (Focus 30 %, Selection 40 %), and a translucent swatch shows the engine's transparency checkerboard: the row's own label names the opacity (`Selection (40%)`) and its tooltip says what the checkerboard is, while a fully transparent colour - one a saved layout or profile carried in - reads `(unset)`; Pane Settings' Cursor colour, Default FG and Default BG rows use the same reading. The scheme file supplies the terminal's own palette; clearing it returns terminals to the built-in palette, which is applied live, and it is independent of the chrome's mode: a light window may well hold a dark terminal.

A pane change is animated by default. **Motion** sets how much: `Off` draws every change in one frame, `Subtle` eases with no overshoot, and `Full` allows each animation's declared overshoot, capped at 3 %. Each transition has its own animation picker - **Create**, **Close** and **Swap** - and every entry lists its own properties below the picker - duration, plus the animation's own start scale, overshoot or slide distance - so switching the animation switches the rows. The create and close pickers offer None, Fade, Fade and Scale (the default), Slide and Pop; the swap picker offers None, Move (the default) and Crossfade. A created pane with Fade and Scale fades and scales from 92 % into the rectangle the layout already reserved, so its neighbours do not move; Slide starts it displaced toward the seam it shares with its sibling (by its distance, clamped to the grid) and slides it into place; Pop scales up from 55 %. A closing pane plays its animation in reverse over the sibling that grows into its place and is freed when the transition ends (a closed terminal's process therefore lives one transition longer); a position swap eases both panes between their old and new rectangles, or, with Crossfade, dissolves both out where they were drawn, trades their rectangles at the midpoint and dissolves them back in. A pane-type switch plays the Create animation on the new pane. Nothing animates on a hidden workspace, while a divider is being dragged, or while a terminal is streaming hard enough to be in its flood back-off; a launch or profile restore draws final rectangles. The same switch governs every other animation the app plays: the agent-state badge's turning notch and attention pulse, the Getting Started keycap (whose step also types in at 36 characters per second), a toast's fade, the 140 ms focus-border sweep, the shared empty state, a created sidebar row, the Settings tab when it changes, and the effect field and reactive cue below. `Off` keeps each at its first or final frame - the badge's phase-0 silhouette, the guide's first step complete, a still cue border, grain frozen at its first frame - and a settings save applies at once, without a restart. **Reset tab to defaults** returns Motion to Subtle and every transition to its shipped animation.

**Effects** draws a GPU backdrop behind terminal text. **Terminal effect** offers `CRT scanlines` (a static comb, phosphor mask and vignette) and `Film grain` (animated at 30 Hz in a half-resolution buffer), and **Intensity** is `Off` (the default), `Subtle` (half the shader's amplitude) or `Full`. The effect is painted on the pane's ground only: text, the selection, inverse cells and cells with a non-default background stay opaque, and a pane's own colour scheme supplies the base colour, so the pattern reads on both themes. It is display-only and never touches the shell or the grid; the static effect is evaluated only when the pane changes, and an animated one stops while its pane is hidden and freezes at its first frame under **Motion**'s `Off`. Glassmorphism is the System tab's **Window opacity** (the whole window's alpha), not an effect row.

**Reactive effects** maps a concept to one short cue on the pane that fired it: **Tint** (a red wash), **Pulse** (an accent border) or **Particles** (a green spark burst). Each row picks a concept and an effect, `Off` removes the rule, and there are no rules by default (eight at most). A pane cues at most three times a second; the cue is display-only and never feeds back into the concept engine. Under **Motion**'s `Off` a cue is one still border in its cue's colour for 400 ms - no fade, no spark burst and the same three-a-second limit. The Effects and reactive rows reset with the Appearance tab.

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

## Shortcuts

Every binding the app knows, grouped as Workspace, New Panes, Panes, Keyboard Focus, and Terminal. Each row is the chord and what it does, and the chords are read from the binding registry rather than typed in, so the list cannot name a key that does nothing. The list is the in-app copy of [[keyboard-shortcuts]]; the palette's `Keyboard Shortcuts` row opens this tab directly.

## About

The app version and the IPC protocol version gPTY speaks, on one line. The protocol number is useful when a CLI and a GUI from different builds disagree about the wire format. The line under it names the renderer the engine actually uses — the driver, the device, and when Godot had to fall back to a CPU rasterizer, that state. On a software rasterizer the status bar's FPS reads `… FPS · software`, because the number then measures the CPU rather than gPTY.

Below it is the README — generated from the repository's `README.md` — rendered in the panel. Every Markdown document it links (the guides, the roadmap and changelog pages, the agent rules) also ships inside the app, so a link opens that document in place instead of a browser. The two arrow buttons beside the document's path walk back and forward through what you opened; the oldest step is always the README, so pressing Back returns to the front page. A link the build does not carry is refused with a toast and the page you are reading stays. Images show as their alt text — the panel renders text, not media — and the badge header the repository's front page carries is left out.

## Global settings versus per-pane settings

| Scope | Where | What it covers |
|---|---|---|
| Global | Settings panel, `user://settings.json` | Fonts, colors, terminal defaults, shell program, global environment, FPS, window mode, window opacity, terminal padding |
| Per pane | Pane Settings popup; the Inspector's aim in `user://pane_inspector.json` | Name, attachment id, font size, environment override, type-specific view options, and the Inspector's prompt and switches |
| Workspace | More → Set Directory on the workspace row, `user://workspaces.json` | Default directory inherited by new terminals; changing it asks when the workspace holds a pane that names its own program |
| File-supplied | Layout or profile tile | Pane type, geometry, and a spawn plan (program and arguments) |
| Trust | Workspace Trust dialog, `user://trusted.json` | Approval memory for file-supplied spawn plans |

The Pane Settings popup is type-aware. For a terminal it edits the pane's name, public attachment id, font size, environment lines, launch line, own working directory, cursor shape, blink and blink speed, cursor color, beam width, underline height, scroll lines, default foreground and background colors, font file, and its own colour scheme (empty follows Settings; stored in `user://pane_schemes.json`, so a layout or profile cannot name it). The background is the terminal's own: it is written as the grid's default background (`Palette::background`), so the cells are painted on it and a resize never reveals a band of a different colour; a colour scheme's background takes it over while a scheme is set. It does **not** edit the shell program, its arguments, or tags — the program and arguments come from the creation call, a layout tile or a profile (and are exactly what Workspace Trust gates), and the launch line is how a portable profile starts something. Clearing the environment box removes that pane's override, so it inherits the global environment again.

Per-pane environment, the pane's own directory, its colour scheme and the Inspector's aim are the settings only you can supply. Environment is stored in `user://pane_env.json`, the directory in `user://pane_cwd.json` (keyed by the workspace and the pane's attachment id), the scheme in `user://pane_schemes.json` (keyed by the attachment id alone) and the aim (system prompt, auto-send, capture acceptance) in `user://pane_inspector.json` (keyed by the attachment id alone), and only the pane settings UI writes them. A saved layout or profile that carries environment has it stripped on restore with a notice — the file is never allowed to become spawn-time authority — and the Inspector's three keys are refused from files outright, so a restored pane takes its aim from your record, never from the layout; the directory is refused the same way and the workspace half of its key is generated locally, so no file can name one. Renaming a pane's attachment id moves all four entries to the new key; closing an Inspector removes its aim record, and closing a workspace removes its directories, while a restart or a profile re-activation keeps them.

Two related files are not part of settings: `user://trusted.json` holds Workspace Trust approvals, and `user://workspaces.json` and `user://profiles.json` hold the arrangements. See [[workspace-trust]], [[workspace]], and [[profile]].

## Related

[[gpty]] · [[sidebar]] · [[keyboard-shortcuts]] · [[profile]] · [[concepts]] · [[workspace-trust]]
