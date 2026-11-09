# Sidebar

The sidebar is the 180 px panel on the left of the window. It gives one place to switch window mode, spawn panes, change workspace, activate a profile, and operate on the pane you are looking at.

## Shape and collapse

The panel has a header with the gPTY title and a collapse arrow, then four sections in this order: window mode, workspaces, profiles, and panes. Between the window-mode row and the sections sit the Add Pane grid and three actions — Search, Settings, and Close All.

Collapsing shrinks the sidebar to a 20 px strip with a single expand button; the pane grid widens to take the space. `Ctrl+Shift+B` toggles it, and the arrow in the header or the expand button does the same. The collapsed state is not saved, so each run starts expanded.

The workspace and profile lists show at most five rows at full height and gain an inner scrollbar beyond that, so a long list cannot push the rest of the panel off-screen; the pane list takes the remaining height and scrolls. Row labels are clipped with an ellipsis rather than stretching the 180 px panel and clipping their neighbours.

## Window mode

The top dropdown switches how gPTY presents its window: `System Frame`, `Borderless`, or `Fullscreen`. This is the same setting as Window Mode in the Settings panel's System tab; changing either updates the other. Its tooltip spells out what each value draws: `System Frame` keeps the operating system's window frame and its controls and hides gPTY's own titlebar, `Borderless` is a window with no desktop frame that draws gPTY's titlebar, and `Fullscreen` fills the screen and keeps that titlebar. The fullscreen shortcut toggles between the last two (see [[keyboard-shortcuts]]).

## Add Pane and the actions

`Add Pane` is a two-row grid of eight buttons, one per pane type: Terminal, Code Viewer, File Tree, Inspector, Reasoning, CLI View, Wiki, and Media. Each tooltip names the type and, where one exists, its shortcut, read from the binding the key path actually answers.

The heading at the left of the row reads `Add Pane:` until you point at a tile or move the keyboard cursor onto one, then names that tile (`Add a Terminal Pane`) and reverts when you leave; a tile under the pointer wins over a tile that merely has focus. The question-mark **Help** button at the right of the heading opens a table of the same information: the glyph, what pressing it adds, and the chord, for every pane type.

Clicking a button spawns that pane into the active workspace using the same split rule as every other spawn: the largest tile halves along its longer axis, and the spawn is refused if the halves would fall below the 6-unit minimum. The new pane becomes active, and a terminal takes the keyboard.

Below it:

- **Search** opens the scrollback search bar on the active terminal (or the workspace's first terminal when a non-terminal is focused). Same as `Ctrl+Shift+F`.
- **Settings** opens the global settings panel described in [[settings]].
- **Close All** closes every pane in the active workspace. It asks before stopping running commands or discarding unsaved work; a Cancel leaves everything in place. Same as `Ctrl+Shift+R`.

## Workspaces

This section answers "which tab am I in". Its header has a `+` button that creates a workspace (up to eight), and each row has three parts:

- The **name** switches to that workspace on a click and begins an inline rename on a double-click. Enter or clicking away commits; Escape restores the old name. Names are trimmed to 32 characters and default to `Workspace`.
- The **folder button** opens a directory picker for that workspace's default directory. A set directory colours the button and appears in the tooltip; `Use default` clears it. New terminals spawned there inherit it, including terminals created by profile activation, but running shells are never moved. There is no per-pane directory setting.
- The **close button** appears only when more than one workspace exists. Closing asks the workspace's panes first and cannot close the last tab.

The active workspace is accented. Because the sidebar only ever shows the active workspace's panes, workspace rows are how you move between arrangements; see [[workspace]] for what a workspace owns.

## Profiles

Profiles are reusable tile sets. Clicking a row activates that profile into the active workspace, replacing its panes after a confirmation when the workspace is not empty. A profile row is accented while the active workspace was built from it, until the layout is reset or another profile is activated.

The header's `+` saves the current arrangement as a new profile; the dialog asks for a name and lets you edit each pane's command. A user profile can be renamed by double-clicking its row and deleted with its trash button. Built-in and plugin-provided profiles have no rename or delete: the built-in ships with the application and plugin profiles follow their plugin. A plugin row's tooltip names the plugin and revision it came from, and the section ends with a `More layouts →` row that opens the plugin registry in your browser. [[profile]] covers the sources, storage, and the trust check activation runs.

## Panes

The Panes section mirrors the active workspace's grid, one row per tile in tile order. It is a second way to reach each pane, and it stays useful when a pane is hidden by minimize.

A row has a label button (`T1`, `C1`, `F1`, and so on — the type's prefix plus a running number) followed by three icon buttons:

| Control | What it does |
|---|---|
| Label | Focuses that pane; the row is accented when it is active |
| Pane settings | Opens the type-aware settings popup for that pane |
| More pane actions | Opens the same menu the title bar's overflow button opens: minimize/restore, swap position, and the eight pane types with the current one marked |
| Close | Closes that pane, after the running-work and unsaved-work questions |

The three are the title bar's three. Both surfaces call one builder (`TerminalManager.show_pane_actions_popup`), so they cannot offer different actions or disagree about which type a pane is, and choosing the pane's own type from the menu does nothing rather than rebuilding it. Minimize and swap position are in that menu because neither is worth a permanent button: the tile keeps its space while a pane is hidden, and a swap needs a second pane to be meaningful.

The label is also the pane's public identity: `T3` is what the CLI and MCP tools accept when you target a pane. Changing the type destroys the old pane body, so it asks the same questions as closing one. Minimizing a terminal keeps its process running; the tile does not change, so restoring it puts it back exactly where it was.

## What the sidebar is not

It is not a settings panel and not a layout editor. Global look-and-feel lives in [[settings]], pane geometry is changed by dragging dividers or using swap position, and the arrangement itself is saved with the workspace. The sidebar shows the state; the workspace owns it.

## Related

[[gpty]] · [[workspace]] · [[profile]] · [[settings]] · [[keyboard-shortcuts]] · [[pane]]
