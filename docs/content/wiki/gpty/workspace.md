# Workspace

A workspace is a tab that holds its own layout. Switching tabs changes which panes you see and type into; the other workspaces keep their panes alive in the background.

## What a workspace is

Every window has at least one workspace and at most eight. Each one owns a grid, a set of tiles, and a default working directory. Panes are not shared between workspaces: a terminal in one tab is a different process from a terminal in another, and closing a workspace closes the panes it contains.

The sidebar lists them in its Workspaces section, with the active one accented. Clicking a row switches to it; double-clicking the name edits it in place (Enter or clicking away commits, Escape cancels). The add button creates one, and the close button appears only when more than one exists, because the last workspace cannot be closed.

Rows show the workspace's name and, when one is set, its directory; hovering explains the directory. The profile accent is per workspace — activating a profile in one workspace does not light that row while another workspace is active.

## Creating, switching, closing

A new workspace starts blank: gPTY does not auto-spawn a terminal, so you decide what fills it. It inherits the current workspace's default directory, the way a new terminal tab usually starts where you are, and you can point it elsewhere afterwards.

Switching keeps every pane in the previous workspace running. Only the visible grid is processed, so hidden terminals do not redraw, but their shells and programs continue. The workspace set is saved to disk on each switch, so a crash loses at most the current tab's latest change.

Closing a workspace asks its panes first — a running command raises one confirmation for the whole set, and a pane with unsaved work (such as a wiki note) can cancel the close. When it proceeds, the workspace's panes are torn down and its grid freed. Closing a non-active workspace does not change which tab you are looking at.

Switching also has shortcuts: `Ctrl+PageDown` moves to the next workspace and `Ctrl+PageUp` to the previous one, clamped at the ends.

## The default directory

Each workspace can carry a default directory, chosen through the folder button on its sidebar row. The picker offers `Use default` to clear it. A cleared or never-set directory means new terminals start wherever gPTY itself starts, which is the older behavior.

The directory applies to terminals spawned **after** the change — including terminals created by activating a profile — and never moves a shell that is already running, so it cannot disturb work in progress. A directory is accepted only as an absolute path; gPTY warns and keeps the old value when the path is relative, missing, or carries control characters. Panes like the file tree and wiki pane may open where the workspace points, but the terminal is the setting's main surface.

Because a profile is a layout template rather than a workspace, the directory is stored on the workspace instance, not on the profile. Activating the same profile in two workspaces can therefore produce terminals in two different directories.

## Persistence

The whole set lives in `user://workspaces.json` under `version`, `active`, and `workspaces`. Each workspace entry stores its sanitized name (at most 32 characters, defaulting to `Workspace`), its `cwd`, and its layout array. The layout is the tile geometry described in [[layout]]; the workspace is the container around it.

On startup gPTY loads the store, clamps the active index into range, and rebuilds every workspace. If the store is missing or empty, a legacy `user://layout.json` is imported as a single workspace named `Workspace 1`; that migration exists so older installs keep their arrangement.

If a saved tile would start a different program or pass extra arguments compared with your configured shell, the restore pauses at a Workspace Trust dialog listing what the file asks to run. Cancel rebuilds the workspaces with their panes emptied but their names and directories kept. Approvals are remembered per exact spawn plan, so an arrangement you already approved does not ask again. See [[workspace-trust]].

## Workspace, layout, profile

| Term | Question it answers |
|---|---|
| Workspace | Which tab am I in, and where do its terminals start? |
| Layout | What panes are arranged how inside this tab? |
| Profile | Which reusable tile set can I copy into a tab? |
| Pane | Which single unit am I typing into? |

A workspace is not a layout: the layout is a detail inside it. Nor is it a profile: a profile can be activated into any workspace and replaces that workspace's panes, while the workspace keeps its name and directory. Saving the current arrangement under a name creates a profile, not a second workspace.

## Related

[[gpty]] · [[layout]] · [[profile]] · [[sidebar]] · [[pane]] · [[workspace-trust]]
