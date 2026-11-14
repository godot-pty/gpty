# Layout

A layout is the arrangement of panes inside one workspace: which rectangle each pane occupies, which pane sits in it, and the settings saved with that tile. It is geometry plus per-tile state, not a running session.

## The grid

Panes are placed on a tiling grid of 60 abstract units in each direction (`PaneTypes.GRID`). Every tile carries four integers — `col`, `row`, `cspan`, `rspan` — giving its top-left corner and its width and height in those units. The smallest allowed tile is 6 units (`MIN_TILE`), a tenth of the grid, which is roughly 100 px on a 1000 px pane.

Units are shares, not pixels: the grid stretches to fill the pane area, so a unit is about 17 px on a 1000 px pane and more on a wide monitor. When a tile is read from disk its geometry is clamped — corners inside the grid, spans at least 1 and at most 60, and never past the far edge. Stored terminal grid sizes are clamped separately (1–500 rows, 1–2000 columns).

## How panes get geometry

The first pane in an empty workspace fills the entire grid. Spawning another pane splits the largest tile in half along its longer axis; a caller may name a side (`left`, `right`, `top`, `bottom`) to split along that axis and put the new pane on that edge. A side the grid cannot honour falls back to the longer-axis split rather than refusing the spawn; if either half would still fall below `MIN_TILE`, the spawn is refused and gPTY warns that the grid is full. Panes never overlap, and no tile is ever automatically stacked on another.

Closing a pane frees its rectangle. An exact neighbour that matches the shape absorbs it; otherwise a group of tiles along exactly one side grows into the gap. A hand-edited or pinwheel arrangement with no such neighbour keeps the gap rather than stacking panes — except a lone survivor, which becomes the whole grid again.

Minimizing a pane hides its body but keeps its tile, so the arrangement is unchanged and the space stays reserved.

## Resizing by dragging

Each divider is one grab band centred on it (`DividerHandles`, 12 px), not a strip per pane edge: a band spans exactly the stretch of the line that has a tile on both sides, so a pane that runs across a line never has a handle over its own content, and there is no dead ribbon between two neighbouring panes. Hovering a band paints the accent colour down its middle, and the pointer takes the line's resize shape for the whole drag even where the platform cursor does not change. Dragging any part of a line moves every tile touching it — on both sides and along its whole length — so the result does not depend on which side of the divider you happened to grab.

The divider moves a whole grid unit at a time, and the release commits the same unit it showed, so the divider never jumps when the button comes up. The panes themselves reflow while the drag runs, at about ten reflows a second rather than on every motion event, which is what makes the text follow the divider without a window-size signal to the shell per pixel; the released geometry gets one final reflow. A tile never shrinks below `MIN_TILE`, and a line with no tile on its far side (or no travel left at all) shows no handle and starts no drag.

A terminal fills its whole rectangle with the same colour its cells paint — the grid's background, `palette[0]`, which a colour scheme's first entry sets — so the margin a resize exposes is never a band of a different grey.

The sidebar's swap-position action exchanges two tiles' stored geometry without touching what runs inside them.

## What a layout stores

Each tile saves its geometry plus the pane's layout state: type, pane name, attachment id, tags, font size, and whatever that pane type adds — a terminal's command, shell arguments, grid dimensions and cursor look; a wiki pane's vault path, view mode, open note and whether the graph was showing; a media pane's file; and so on.

A layout deliberately does **not** store:

- Running processes, exit state, or scrollback — history lives in a separate database and survives panes.
- Unsaved editor text. A dirty wiki buffer is not part of the layout; a recovery copy outside the vault covers a crash.
- Per-pane environment. That is user-owned, keyed by attachment id, and lives in its own store (see [[settings]]).
- Window size, position, sidebar width, or focus. Those belong to the application, not the arrangement.

Restoring a layout therefore starts fresh programs in the same shapes, not the same sessions.

## Saving and restoring

Automatic persistence and named saving are two different mechanisms.

The **workspace set** is auto-saved to `user://workspaces.json` whenever you switch or close a workspace, and on exit. Each entry holds a name, an optional default directory, and its layout array plus the `grid_unit` it was written in, so a file from an older build converts to the same shares. On startup the set is restored and the previously active workspace is re-selected. A legacy `user://layout.json` is imported once when the store is empty, which is why the older file name still appears in the code. A layout with more tiles than the window has room for restores what fits and says how many did not: live panes are capped across the whole window, not per workspace, so the ceiling a restore meets is what the other workspaces leave ([[control-api]]).

A **named layout** is saved on demand:

```bash
gpty layout save "My Split"
gpty layout load "My Split"
gpty layout list
```

The command palette's `save` and `load` entries do the same for the workspace set (save writes it, load reloads it from disk), and the control API exposes `layout-save`, `layout-load`, and `layout-list`. In this build a named layout is stored as a profile: saving captures the active workspace's tiles under a name, and loading replaces the active workspace with them. See [[profile]] for where those live and how activation behaves.

Restoring is subject to Workspace Trust when a tile names a different program or passes arguments compared with your configured shell; a saved tile's environment is always stripped. See [[workspace-trust]].

## Layout, workspace, profile

| Term | What it is | Scope |
|---|---|---|
| Layout | The arrangement and per-tile settings | Inside one workspace |
| Workspace | A tab that owns one layout | One entry in the tab set |
| Profile | A reusable named tile set | Saved separately, activated into a workspace |
| Pane | One unit placed by a layout | The thing you type into |

A layout is not a workspace and not a profile: the workspace owns it, and a profile is a template you copy into a workspace.

## Related

[[gpty]] · [[workspace]] · [[profile]] · [[sidebar]] · [[pane]] · [[workspace-trust]]
