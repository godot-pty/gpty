# Sidebar

The sidebar is the 180 px panel on the left of the window. It gives one place to switch window mode, spawn panes, change workspace, activate a profile, and operate on the pane you are looking at.

## Shape and collapse

The panel has a header with the gPTY title and a collapse arrow, then four sections in this order: window mode, workspaces, profiles, and panes. Between the window-mode row and the sections sit the Add Pane grid and three actions — Search, Settings, and Feedback.

Collapsing shrinks the sidebar to a 20 px strip with a single expand button; the pane grid widens to take the space. `Ctrl+Shift+B` toggles it, and the arrow in the header or the expand button does the same. The collapsed state is not saved, so each run starts expanded.

The workspace and profile lists show at most five rows at full height and gain an inner scrollbar beyond that, so a long list cannot push the rest of the panel off-screen; the pane list takes the remaining height and scrolls. Row labels are clipped with an ellipsis rather than stretching the 180 px panel and clipping their neighbours.

## Window mode

The top dropdown switches how gPTY presents its window: `System Frame`, `Borderless`, or `Fullscreen`. This is the same setting as Window Mode in the Settings panel's System tab; changing either updates the other. Its tooltip spells out what each value draws: `System Frame` keeps the operating system's window frame and its controls and hides gPTY's own titlebar, `Borderless` is a window with no desktop frame that draws gPTY's titlebar, and `Fullscreen` fills the screen and keeps that titlebar. The fullscreen shortcut toggles between the last two (see [[keyboard-shortcuts]]).

## Add Pane and the actions

`Add Pane` is a two-row grid of eight buttons, one per pane type: Terminal, Code Viewer, File Tree, Inspector, Reasoning, CLI View, Wiki, and Media. Each tooltip names the type and, where one exists, its shortcut, read from the binding the key path actually answers.

The heading at the left of the row reads `Add Pane:` until you point at a tile or move the keyboard cursor onto one, then names that tile (`Add a Terminal Pane`) and reverts when you leave; a tile under the pointer wins over a tile that merely has focus. The question-mark **Help** button at the right of the heading opens a table of the same information: the glyph, what pressing it adds, and the chord, for every pane type.

Clicking a button spawns that pane into the active workspace using the same split rule as every other spawn: the largest tile halves along its longer axis, and the spawn is refused if the halves would fall below the 6-unit minimum. The new pane becomes active, and a terminal takes the keyboard.

Below it:

- **Search** opens the search strip on the active terminal (or the workspace's first terminal when a non-terminal is focused). Same as `Ctrl+Shift+F`.
- **Settings** opens the global settings panel described in [[settings]].
- **Feedback** opens a prefilled GitHub issue in your browser. The title reads `Feedback: ` and the body carries three prompts — what happened, what you expected, steps to reproduce — over an "About this build" block naming the gPTY version, the operating system and its version, and the window mode. Only those four facts are prefilled: never pane output, a command, selected text, a path, an environment value, or a log. Nothing is submitted by gPTY and no token or network call is involved — the issue is an ordinary GitHub page you review and file yourself. When no browser can be opened (offline, headless, no default handler) the same text is copied to the clipboard instead and a toast says so.

All three action rows center their glyph and text in the panel, the same alignment the Workspace and Profile row labels use.

## Workspaces

This section answers "which tab am I in". Its header has a `+` button that creates a workspace (up to eight) and a **trash** that closes every workspace; the trash is shown only while at least one workspace exists. Each row has three parts:

- The **name** switches to that workspace on a click and begins an inline rename on a double-click or from the row's **More** menu. Enter or clicking away commits; Escape restores the old name. Names are trimmed to 32 characters and default to `Workspace`.
- The **More** button (⋯) opens that workspace's menu. **Rename Workspace** opens that row's inline rename editor (the same one a double-click opens). **Set Directory** opens the directory picker for the workspace's default directory; its tooltip names the current path and `Use default` clears it. New terminals spawned there inherit it, including terminals created by profile activation, but running shells are never moved. **Clear Workspace** closes every pane in that workspace; a hidden workspace is cleared without switching to it, after the same running-work and unsaved-work questions a close uses.
- The **close button** (trash) is always shown, including on the last workspace. It swaps the row's actions for a check and a cross first; the check runs the close, the cross cancels. Closing the last workspace is allowed and leaves the zero-workspace state below.

The two title rows use the same in-place question: the trash hides, a check and cross appear, and only the check proceeds to the running-work and unsaved-work walk. A row's label stays visible while its question is open, so you can see which workspace or pane you are confirming.

When no workspace exists, the Workspaces header keeps only the `+` and the Panes section is hidden. The window shows the empty-workspace guide — a clickable live keycap demo of the spawn chords and every registered binding in grouped cards; the first pane you create makes a workspace named **Default**, and `+` alone also creates **Default**.

The active workspace is accented. Because the sidebar only ever shows the active workspace's panes, workspace rows are how you move between arrangements; see [[workspace]] for what a workspace owns. The header's **Panes:** trash is the section's close-all: it closes every pane in the active workspace, after the same check/cross and running-work walk (same as `Ctrl+Shift+R`).

## Profiles

Profiles are reusable tile sets. Clicking a row activates that profile into the active workspace, replacing its panes after a confirmation when the workspace is not empty. A profile row is accented while the active workspace was built from it, until the layout is reset or another profile is activated.

The header's `+` saves the current arrangement as a new profile; the dialog asks for a name and lets you edit each pane's command. A user profile can be renamed by double-clicking its row and deleted with its trash button. The two shipped layouts, Agent Workspace and Knowledge Base, are copied into `user://profiles.json` on first launch and are ordinary user rows from then on, so they have the same rename and delete controls; a deleted copy is not re-added. Saving or renaming into an existing user-profile name asks **Replace Profile?** first. A plugin profile offers no rename; its row carries a trash that asks with a check/cross and then uninstalls the plugin, removing every profile and concept it ships. A plugin row's tooltip names the plugin and revision it came from, and the section ends with a `More layouts →` row that opens the plugin registry in your browser. There is no delete-all control in the Profiles header. [[profile]] covers the sources, storage, and the trust check activation runs.

## Panes

The Panes section mirrors the active workspace's grid, one row per tile in tile order. It is a second way to reach each pane, and it stays useful when a pane is hidden by minimize.

A row has a label button (`T1`, `C1`, `F1`, and so on — the type's prefix plus a running number) followed by three icon buttons:

| Control | What it does |
|---|---|
| Label | Focuses that pane; the row is accented when it is active |
| Pane settings | Opens the type-aware settings popup for that pane |
| More pane actions | Opens the same menu the title bar's overflow button opens: minimize/restore, **Swap pane**, and **Switch pane type** (which lists the eight types with their icons and the current one marked) |
| Close (trash) | Swaps the row to a check/cross first, then closes that pane after the running-work and unsaved-work questions |

The `Panes:` heading carries a trash of its own while the list has at least one pane; it closes every pane in the active workspace through the same check/cross and running-work walk, and the whole section is hidden when there is no pane.

The three are the title bar's three, with one difference in friction: the sidebar row's trash asks check/cross first, while the title bar's trash closes immediately and still asks about running work and unsaved edits. Both surfaces call one builder for the More menu (`TerminalManager.show_pane_actions_popup`), so they cannot offer different actions; the type list lives behind **Switch pane type**, and choosing the pane's own type there does nothing rather than rebuilding it. Minimize and **Swap pane** are in that menu because neither is worth a permanent button: the tile keeps its space while a pane is hidden, and a swap needs a second pane to be meaningful.

The label is also the pane's public identity: `T3` is what the CLI and MCP tools accept when you target a pane. Changing the type destroys the old pane body, so it asks the same questions as closing one. Minimizing a terminal keeps its process running; the tile does not change, so restoring it puts it back exactly where it was.

## What the sidebar is not

It is not a settings panel and not a layout editor. Global look-and-feel lives in [[settings]], pane geometry is changed by dragging dividers or using **Swap pane**, and the arrangement itself is saved with the workspace. The sidebar shows the state; the workspace owns it.

## Related

[[gpty]] · [[workspace]] · [[profile]] · [[settings]] · [[keyboard-shortcuts]] · [[pane]]
