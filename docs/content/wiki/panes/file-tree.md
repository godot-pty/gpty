# File Tree Pane

A file tree pane browses a directory and opens what you activate into the right in-app pane: text into the [[code-viewer|Code Viewer]], media into the [[media-pane|Media Pane]], everything else through the system's default handler after a confirmation.

## What it is

The body is `FileTreePane` (`godot/scenes/panes/file_tree.gd`), a thin wrapper around one Godot `Tree`. The registered type key is `file_tree` and its label prefix is `F`. It is a browser, not a file manager: it lists a single root and its subdirectories, and it hands paths to other panes.

Its main job is to keep you inside gPTY. Activating a source file does not launch an editor; activating a video does not launch a desktop player. The tree decides by two closed tables — `ViewableFiles` for text and `MediaFiles` for media — so the same extension always goes to the same place.

## When to use it

Use it when you want to look around the workspace directory, open a specific file in a viewer, or pull a recording into the media pane. Use the [[terminal-pane|Terminal Pane]] for `ls`, `git status` and anything that changes files; this pane cannot.

## How to open it

| Method | Action |
|---|---|
| Shortcut | `Ctrl+Shift+T` |
| Sidebar | the file tree button |
| Palette | `new file tree` |
| CLI | `gpty new-pane -t file_tree` |
| MCP | the `new-pane` tool with `type: "file_tree"` |
| Layout/profile | a saved tile with `type: "file_tree"` restores its root and open mode |

A fresh pane starts at `/`. The CLI and the `new-pane` tool have no root parameter — the root is pane state, set in Pane Settings or carried by a saved layout tile. The workspace's directory setting does not retarget an existing tree.

## What it shows and how it is driven

The tree shows the root's direct entries and grows on demand: activating a directory lists its children the first time and then expands or collapses it. Nothing below the root is read until you ask for it, so pointing a tree at a large directory costs one listing.

Entries whose names begin with `.` are skipped at every level, so `.git`, `.env` and editor state directories never appear. Only one directory's worth of names is held per expanded node; there is no search box and no filter.

Activating a file goes through one of three routes:

| File kind | Route |
|---|---|
| extension in `ViewableFiles` | a `code_viewer` pane request with `file_path` |
| extension in `MediaFiles` | a `media` pane request with `file_path` |
| anything else | a confirmation dialog, then the system handler with a `file://` URI |

The open mode is per tree, not global. **Viewer pane** is the default and enables the first two routes; **System application** keeps the confirm-then-open path even for files the viewer could show. A file the tables do not name always stays on the system path, because the in-app route is an allowlist rather than content sniffing — a downloaded `script.desktop` is never "viewed" as text, and it is never opened without you seeing its exact path first.

Directories and files are both validated at activation: a path that is no longer a regular file produces a warning toast instead of a handler call, and a non-absolute path is refused outright. Panes do not spawn panes; the tree emits a request and the workspace creates the viewer or media pane (or focuses the one already showing that path).

## Settings that matter

| Setting | What it changes |
|---|---|
| Name | the pane's title |
| Font size | 8–32 px |
| Root path | absolute directory to list; changing it clears and re-lists |
| Open files | `Viewer pane` or `System application` |

The root is validated at use — an empty, relative or missing path simply lists nothing. A saved layout records `root_path` and `open_in`; an unknown `open_in` value from a file falls back to the default rather than leaving the pane with neither route authoritative.

## What it does not do

It does not rename, delete, move, copy or create files. It does not show hidden entries, so there is no toggle to reveal them. It does not recurse eagerly or index the tree for search. It does not open a file into an existing viewer pointed at another file — a second view is a deliberate layout choice, made by opening another viewer pane.

## Limits and edge cases

Only absolute paths are ever opened, and only regular files reach a handler; this is why a FIFO or device node that appears in a listing produces a refusal rather than hanging the GUI thread. The system route constructs the `file://` URI itself and shows the exact path in a confirmation, which is the guard against a filename that looks like another scheme. Because listing is lazy, a directory that changes after it was expanded is not refreshed — children stay as first read. Re-applying the root path in Pane Settings rebuilds the tree from disk.

## Related

- [[pane]]
- [[code-viewer]]
- [[media-pane]]
- [[terminal-pane]]
- [[workspace]]
